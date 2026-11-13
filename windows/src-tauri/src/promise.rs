//! Bild rendern und kodieren im Hintergrund (`ImagePromise` in Utilities.swift). Ein 4K-PNG braucht
//! ~80–180 ms — das darf weder das Overlay noch die Karte aufhalten. `data`/`image` warten, falls
//! die Arbeit noch läuft.

use std::sync::Arc;

use knips_core::imageops;
use knips_core::model::ImageFormat;
use knips_core::settings::Settings;
use knips_core::RgbaImage;
use knips_platform::clipboard::ImageProvider;
use parking_lot::{Condvar, Mutex};

#[derive(Default)]
struct State {
    done: bool,
    image: Option<Arc<RgbaImage>>,
    data: Option<Arc<Vec<u8>>>,
}

#[derive(Clone)]
pub struct ImagePromise {
    pub format: ImageFormat,
    /// Ausgabe „Automatisch“: Auflösung und Farbtiefe stehen erst nach dem Kodieren fest (volle Auflösung mit 256
    /// Farben oder die Ausgabe ohne Farbreduktion). Solche Daten taugen nicht als Original, und die Maße des
    /// Eintrags zieht der Store nach (`Store::settle_output`).
    pub adaptive: bool,
    inner: Arc<(Mutex<State>, Condvar)>,
}

impl ImagePromise {
    /// Rendert (z. B. verkleinert) und kodiert anschließend — im Hintergrund.
    pub fn new(format: ImageFormat, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> Self {
        Self::spawn(format, false, render)
    }

    /// Wie `new`, PNG aber dichter gepackt (`imageops::encode_compact`) — für die Datei im Ablageordner.
    pub fn compact(format: ImageFormat, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> Self {
        Self::spawn(format, true, render)
    }

    fn spawn(format: ImageFormat, compact: bool, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> Self {
        Self::work(format, false, move || {
            let image = render()?;
            let encode = if compact { imageops::encode_compact } else { imageops::encode };
            let data = encode(&image, format).map_err(|err| log::error!("Kodieren fehlgeschlagen: {err:#}")).ok();
            Some((image, data))
        })
    }

    /// Rendern und Kodieren in einem Schritt, der selbst über Auflösung und Daten entscheidet („Automatisch“).
    pub fn adaptive(format: ImageFormat, work: impl FnOnce() -> Option<(RgbaImage, Option<Vec<u8>>)> + Send + 'static) -> Self {
        Self::work(format, true, work)
    }

    fn work(format: ImageFormat, adaptive: bool, work: impl FnOnce() -> Option<(RgbaImage, Option<Vec<u8>>)> + Send + 'static) -> Self {
        let promise = Self { format, adaptive, inner: Arc::new((Mutex::new(State::default()), Condvar::new())) };
        let inner = promise.inner.clone();
        std::thread::Builder::new()
            .name("knips-encode".into())
            .spawn(move || {
                let (image, data) = match work() {
                    Some((image, data)) => (Some(Arc::new(image)), data.map(Arc::new)),
                    None => (None, None),
                };
                let (lock, cv) = &*inner;
                let mut s = lock.lock();
                s.image = image;
                s.data = data;
                s.done = true;
                cv.notify_all();
            })
            .expect("Kodier-Thread");
        promise
    }

    /// Fertiges Bild, unverändert kodieren.
    pub fn of(image: RgbaImage, format: ImageFormat) -> Self {
        Self::new(format, move || Some(image))
    }

    /// Bereits kodierte Daten (z. B. aus einer Datei) — keine erneute Kodierung.
    pub fn encoded(image: RgbaImage, data: Vec<u8>, format: ImageFormat) -> Self {
        let state = State { done: true, image: Some(Arc::new(image)), data: Some(Arc::new(data)) };
        Self { format, adaptive: false, inner: Arc::new((Mutex::new(state), Condvar::new())) }
    }

    fn wait(&self) -> parking_lot::MutexGuard<'_, State> {
        let (lock, cv) = &*self.inner;
        let mut s = lock.lock();
        while !s.done {
            cv.wait(&mut s);
        }
        s
    }

    pub fn image(&self) -> Option<Arc<RgbaImage>> {
        self.wait().image.clone()
    }

    pub fn data(&self) -> Option<Arc<Vec<u8>>> {
        self.wait().data.clone()
    }
}

impl ImageProvider for ImagePromise {
    fn format(&self) -> ImageFormat {
        self.format
    }
    fn encoded(&self) -> Option<Vec<u8>> {
        self.data().map(|d| d.as_ref().clone())
    }
    fn image(&self) -> Option<Arc<RgbaImage>> {
        ImagePromise::image(self)
    }
}

/// Ausgabe (Datei + Zwischenablage) eines Bildes mit `scale` Pixeln pro Punkt: Größe nach `settings.export_size`,
/// im Format `format` — im Hintergrund.
pub fn output_promise(settings: &Settings, scale: f64, format: ImageFormat, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> ImagePromise {
    let shrink = |img: RgbaImage, factor: f64| if factor < 0.999 { imageops::scaled(&img, factor) } else { img };
    if settings.reduces_colors(scale, format) {
        // „Automatisch“: volle Auflösung mit höchstens 256 Farben. Reichen sie nicht, ohne dass man es sähe (Fotos,
        // Videobilder), oder ist das Bild zu groß: verlustfrei wie bisher — bei 200 % in Bildschirmgröße, bei
        // krummer Skalierung in voller Auflösung (`Settings::fallback_factor`).
        let fallback = Settings::fallback_factor(scale);
        return ImagePromise::adaptive(format, move || {
            let full = render()?;
            if let Some(data) = imageops::encode_palette(&full) {
                return Some((full, Some(data)));
            }
            let image = shrink(full, fallback);
            let data = imageops::encode_compact(&image, ImageFormat::Png).map_err(|err| log::error!("Kodieren fehlgeschlagen: {err:#}")).ok();
            Some((image, data))
        });
    }
    let factor = settings.output_factor(scale, format);
    ImagePromise::compact(format, move || render().map(|img| shrink(img, factor)))
}
