//! Bild rendern und kodieren im Hintergrund (`ImagePromise` in Utilities.swift). Ein 4K-PNG braucht
//! ~80–180 ms — das darf weder das Overlay noch die Karte aufhalten. `data`/`image` warten, falls
//! die Arbeit noch läuft.

use std::sync::Arc;

use knips_core::imageops;
use knips_core::model::ImageFormat;
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
    inner: Arc<(Mutex<State>, Condvar)>,
}

impl ImagePromise {
    /// Rendert (z. B. verkleinert) und kodiert anschließend — im Hintergrund.
    pub fn new(format: ImageFormat, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> Self {
        let promise = Self { format, inner: Arc::new((Mutex::new(State::default()), Condvar::new())) };
        let inner = promise.inner.clone();
        std::thread::Builder::new()
            .name("knips-encode".into())
            .spawn(move || {
                let image = render().map(Arc::new);
                let data = image.as_ref().and_then(|img| match imageops::encode(img, format) {
                    Ok(d) => Some(Arc::new(d)),
                    Err(err) => {
                        log::error!("Kodieren fehlgeschlagen: {err:#}");
                        None
                    }
                });
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
        Self { format, inner: Arc::new((Mutex::new(state), Condvar::new())) }
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

/// Ausgabe (Datei + Zwischenablage): ggf. verkleinert, im gewählten Format — im Hintergrund.
pub fn output_promise(factor: f64, format: ImageFormat, render: impl FnOnce() -> Option<RgbaImage> + Send + 'static) -> ImagePromise {
    ImagePromise::new(format, move || render().map(|img| if factor < 0.999 { imageops::scaled(&img, factor) } else { img }))
}
