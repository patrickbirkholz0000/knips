//! Attrappe für macOS/Linux: gleiche Schnittstelle wie `win/`, damit die App zum Entwickeln der
//! Oberfläche startet. Aufnahmen liefern ein Beispielbild, Video gibt es nicht.
//! **Diese Datei ist die Referenz für die Signaturen** — `win/` muss exakt dieselben anbieten.

pub mod monitors {
    use crate::types::{IRect, Monitor};

    pub fn list() -> Vec<Monitor> {
        vec![Monitor {
            id: 1,
            name: "MOCK1".into(),
            rect: IRect::new(0, 0, 2880, 1800),
            work: IRect::new(0, 0, 2880, 1720),
            scale: 2.0,
            primary: true,
        }]
    }

    /// Monitor unter einem globalen Punkt (sonst der primäre).
    pub fn at_point(x: i32, y: i32) -> Monitor {
        list().into_iter().find(|m| m.rect.contains(x, y)).unwrap_or_else(primary)
    }

    pub fn at_cursor() -> Monitor {
        let (x, y) = cursor_pos();
        at_point(x, y)
    }

    pub fn primary() -> Monitor {
        list().remove(0)
    }

    pub fn cursor_pos() -> (i32, i32) {
        (1440, 900)
    }
}

pub mod capture {
    use anyhow::Result;
    use knips_core::RgbaImage;

    use crate::types::{Frozen, IRect, Monitor, WindowInfo};

    /// Standbild aller angegebenen Monitore; eigene Fenster (mit `exclude_from_capture`) fehlen darin.
    pub fn freeze(monitors: &[Monitor]) -> Result<Vec<Frozen>> {
        Ok(monitors
            .iter()
            .map(|m| Frozen {
                monitor: m.clone(),
                image: crate::sample::sample_image(m.rect.width as u32, m.rect.height as u32, m.scale),
            })
            .collect())
    }

    /// Sichtbare Fenster anderer Programme, von vorn nach hinten.
    pub fn windows() -> Vec<WindowInfo> {
        vec![WindowInfo {
            hwnd: 42,
            rect: IRect::new(840, 600, 1400, 840),
            title: "Fenster".into(),
            owner: "test.exe".into(),
        }]
    }

    /// Einzelnes Fenster freigestellt (auch verdeckte Teile), physische Pixel.
    pub fn window_image(w: &WindowInfo) -> Result<RgbaImage> {
        Ok(crate::sample::sample_image(w.rect.width as u32, w.rect.height as u32, 2.0))
    }

    /// Wiederholte Aufnahme eines festen Bereichs (Scroll-Screenshot): eine Sitzung, viele Bilder.
    pub struct RegionCapturer {
        rect: IRect,
    }

    impl RegionCapturer {
        /// `rect`: monitor-lokal, physische Pixel.
        pub fn new(monitor: &Monitor, rect: IRect) -> Result<Self> {
            let _ = monitor;
            Ok(Self { rect })
        }
        /// Aktuelles Bild des Bereichs (eigene Fenster ausgeschlossen, ohne Mauszeiger).
        pub fn grab(&mut self) -> Result<RgbaImage> {
            Ok(crate::sample::sample_image(self.rect.width as u32, self.rect.height as u32, 2.0))
        }
    }

    /// Fenster aus allen Aufnahmen ausschließen (`WDA_EXCLUDEFROMCAPTURE`) bzw. wieder zulassen. Vor
    /// Windows 10 2004 ohne Wirkung (siehe `exclusion_supported`).
    pub fn exclude_from_capture(hwnd: isize, exclude: bool) {
        let _ = (hwnd, exclude);
    }

    /// Kann Windows eigene Fenster aus Aufnahmen herausnehmen? (ab Windows 10 2004)
    pub fn exclusion_supported() -> bool {
        true
    }

    /// Sichtbare unter `handles` ausblenden (für ein Standbild, wenn `exclusion_supported` nicht gilt)
    /// und warten, bis der Bildschirm ohne sie gezeichnet ist. Liefert die ausgeblendeten Fenster.
    pub fn hide_for_capture(handles: &[isize]) -> Vec<isize> {
        let _ = handles;
        Vec::new()
    }

    /// Mit `hide_for_capture` ausgeblendete Fenster wieder zeigen, ohne sie zu aktivieren.
    pub fn show_after_capture(handles: &[isize]) {
        let _ = handles;
    }

    /// Eigenes Fenster fotografieren (Selbsttests). Darf nicht ausgeschlossen sein.
    pub fn own_window_image(hwnd: isize) -> Result<RgbaImage> {
        let _ = hwnd;
        anyhow::bail!("nur unter Windows")
    }
}

pub mod overlay {
    use anyhow::Result;
    use knips_core::RgbaImage;

    use crate::types::{Frozen, IRect, Monitor, WindowInfo};

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Purpose {
        Screenshot,
        Recording,
        Text,
        Scroll,
    }

    #[derive(Clone, Debug)]
    pub enum Selection {
        /// Rechteck monitor-lokal, physische Pixel.
        Area { monitor: Monitor, rect: IRect },
        Window { window: WindowInfo, monitor: Monitor },
        FullScreen { monitor: Monitor },
        Cancelled,
    }

    /// Auswahl-Overlay über allen Monitoren mit Standbild. Kehrt sofort zurück; `on_done` kommt
    /// genau einmal aus dem Overlay-Thread. Ziehen = Bereich (Umschalt = Quadrat), Leertaste =
    /// Fenstermodus, Eingabe = ganzer Bildschirm, Esc/Rechtsklick = Abbruch.
    pub fn present(
        frozen: Vec<Frozen>,
        windows: Vec<WindowInfo>,
        purpose: Purpose,
        window_mode: bool,
        on_done: Box<dyn FnOnce(Selection) + Send>,
    ) -> Result<()> {
        let _ = (windows, purpose, window_mode);
        let monitor = frozen.first().map(|f| f.monitor.clone()).ok_or_else(|| anyhow::anyhow!("kein Bildschirm"))?;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(150));
            on_done(Selection::Area { monitor, rect: IRect::new(400, 300, 1200, 700) });
        });
        Ok(())
    }

    pub fn is_active() -> bool {
        false
    }

    /// Bricht eine laufende Auswahl ab (`on_done(Cancelled)`).
    pub fn cancel() {}

    /// Overlay eines Monitors in ein Bild rendern (Selbsttest `selection`). `mouse` monitor-lokal.
    pub fn render_offscreen(
        frozen: &Frozen,
        windows: &[WindowInfo],
        purpose: Purpose,
        window_mode: bool,
        mouse: (i32, i32),
        selection: Option<IRect>,
    ) -> Result<RgbaImage> {
        let _ = (windows, purpose, window_mode, mouse, selection);
        Ok(frozen.image.clone())
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum FrameColor {
        /// Rot — Bildschirmaufnahme.
        Recording,
        /// Akzentblau — Scroll-Screenshot.
        Scroll,
    }

    /// Gestrichelter Rahmen (2 px, Strich 6/Lücke 4) 3 px außerhalb des Bereichs. Klicks gehen
    /// hindurch, nicht in Aufnahmen. Schließt beim Drop.
    pub struct FrameWindow {
        _private: (),
    }

    impl FrameWindow {
        /// `rect`: aufgenommener Bereich, global, physische Pixel.
        pub fn show(rect: IRect, color: FrameColor) -> Result<FrameWindow> {
            let _ = (rect, color);
            Ok(FrameWindow { _private: () })
        }
    }
}

pub mod ocr {
    use anyhow::Result;
    use knips_core::model::TextLine;
    use knips_core::RgbaImage;

    /// Texterkennung (lokal). Verkleinert intern auf ≤ 2048 px und rechnet zurück; Zeilen in
    /// Lesereihenfolge, `TextLine.text` = Wörter mit Leerzeichen.
    pub fn recognize(img: &RgbaImage) -> Result<Vec<TextLine>> {
        let _ = img;
        Ok(vec![])
    }

    pub fn available() -> bool {
        false
    }
}

pub mod clipboard {
    use std::path::PathBuf;
    use std::sync::Arc;

    use anyhow::Result;
    use knips_core::model::ImageFormat;
    use knips_core::RgbaImage;

    /// Bild, das erst beim Einfügen geliefert wird (Rendern/Kodieren läuft im Hintergrund).
    /// Die Methoden dürfen blockieren, bis die Arbeit fertig ist.
    pub trait ImageProvider: Send + Sync {
        fn format(&self) -> ImageFormat;
        /// Kodierte Daten im Format `format()`.
        fn encoded(&self) -> Option<Vec<u8>>;
        fn image(&self) -> Option<Arc<RgbaImage>>;
    }

    /// Sofort zurück; PNG, DIBV5 (und JFIF bei JPEG) werden erst bei Anfrage erzeugt
    /// (verzögertes Rendern, `WM_RENDERFORMAT`). Bleibt auch nach Programmende gültig
    /// (`WM_RENDERALLFORMATS`).
    pub fn set_image(provider: Arc<dyn ImageProvider>) -> Result<()> {
        let _ = provider;
        Ok(())
    }

    pub fn set_text(text: &str) -> Result<()> {
        log::info!("Zwischenablage (Attrappe): {} Zeichen", text.len());
        Ok(())
    }

    /// Dateien zum Einfügen (CF_HDROP, „Kopieren“).
    pub fn set_files(paths: &[PathBuf]) -> Result<()> {
        let _ = paths;
        Ok(())
    }

    /// Bild aus der Zwischenablage: PNG, sonst DIB(V5), sonst erste Bilddatei aus CF_HDROP.
    pub fn get_image() -> Option<RgbaImage> {
        None
    }

    /// Selbsttests: Zwischenablage nie anfassen.
    pub fn set_disabled(disabled: bool) {
        let _ = disabled;
    }
}

pub mod hotkeys {
    use anyhow::Result;
    use knips_core::settings::KeyCombo;

    pub enum RecordResult {
        Combo(KeyCombo),
        /// Rücktaste/Entf ohne Strg/Alt/Win: Kürzel entfernen.
        Remove,
        /// Esc.
        Cancel,
    }

    /// Startet den Kürzel-Thread. `on_fire(id)` kommt aus diesem Thread.
    pub fn start(on_fire: Box<dyn Fn(u32) + Send + Sync>) {
        let _ = on_fire;
    }

    /// Ersetzt alle Kürzel. `RegisterHotKey`, wo möglich; Win-Kombinationen, belegte Kürzel und
    /// Druck (solange Windows sie dem Bildschirmausschnitt gibt) über den Tastatur-Hook, der die
    /// Taste dann verschluckt. Liefert die IDs, die gar nicht funktionieren.
    pub fn apply(bindings: &[(u32, KeyCombo)]) -> Vec<u32> {
        let _ = bindings;
        vec![]
    }

    /// Nächste Tastenkombination aufnehmen (Einstellungen). Solange ruhen alle Kürzel; die Tasten
    /// werden verschluckt (auch Druck und Win-Kombinationen). Ungültige Kombination → Signalton,
    /// weiter warten.
    pub fn record(on_result: Box<dyn FnOnce(RecordResult) + Send>) {
        std::thread::spawn(move || on_result(RecordResult::Cancel));
    }

    pub fn cancel_record() {}

    /// Tastenkombination simulieren wie von der Tastatur (Selbsttest `hotkeys`).
    pub fn simulate(combo: KeyCombo) {
        let _ = combo;
    }

    /// „Druck-Taste zum Öffnen der Bildschirmausschnitterstellung verwenden“ (Windows 11).
    pub fn snipping_key_enabled() -> bool {
        false
    }

    /// Schreibt `HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled`.
    pub fn set_snipping_key(enabled: bool) -> Result<()> {
        let _ = enabled;
        Ok(())
    }
}

pub mod shell {
    use std::path::Path;

    use anyhow::Result;

    /// Datei/Ordner mit der Standard-App öffnen.
    pub fn open_path(path: &Path) -> Result<()> {
        std::process::Command::new("open").arg(path).spawn()?;
        Ok(())
    }

    /// Im Explorer zeigen und markieren.
    pub fn reveal(path: &Path) -> Result<()> {
        std::process::Command::new("open").arg("-R").arg(path).spawn()?;
        Ok(())
    }

    /// In den Papierkorb.
    pub fn trash(path: &Path) -> Result<()> {
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }

    pub fn open_url(url: &str) -> Result<()> {
        std::process::Command::new("open").arg(url).spawn()?;
        Ok(())
    }

    /// Fenster nach vorn holen (auch wenn Knips gerade nicht im Vordergrund ist).
    pub fn activate(hwnd: isize) {
        let _ = hwnd;
    }

    /// Aktuelles Vordergrundfenster (um den Fokus nach dem Overlay zurückzugeben).
    pub fn foreground() -> isize {
        0
    }

    pub fn beep() {}
}

pub mod sound {
    /// Auslöser-Geräusch (asynchron).
    pub fn play_shutter() {}
}

pub mod sample {
    use knips_core::RgbaImage;

    /// Erfundener Stripe-Schlüssel im Testbild (zusammengesetzt, siehe `win/sample.rs`).
    pub const STRIPE_KEY: &str = concat!("sk_", "live_KnipsBeispiel42");

    /// Testbild wie `SelfTest.sampleImage`: helles App-Fenster mit Seitenleiste und Kundendaten
    /// (Name, E-Mail, Telefon, IBAN, Stripe-Key, Bestellnummer, Hinweis, Knopf) — mit echter
    /// Schrift, damit Texterkennung und Auto-Zensur etwas finden. `scale`: Pixel pro Punkt.
    pub fn sample_image(width: u32, height: u32, scale: f64) -> RgbaImage {
        let _ = scale;
        RgbaImage::from_fn(width.max(1), height.max(1), |x, y| {
            let sidebar = x < width / 5;
            let top = y < height / 14;
            if top {
                image::Rgba([210, 214, 222, 255])
            } else if sidebar {
                image::Rgba([46, 50, 62, 255])
            } else if y % 64 < 18 && x > width / 4 && x < width * 3 / 4 {
                image::Rgba([40, 40, 48, 255])
            } else {
                image::Rgba([235, 237, 242, 255])
            }
        })
    }
}

pub mod media {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicBool;

    use anyhow::{bail, Result};
    use knips_core::model::VideoDocument;
    use knips_core::RgbaImage;

    use crate::types::{IRect, Monitor};

    #[derive(Clone, Debug, PartialEq, serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct VideoInfo {
        pub duration: f64,
        pub width: u32,
        pub height: u32,
        pub fps: f64,
        pub hevc: bool,
        pub has_audio: bool,
    }

    /// Fehlermeldung, wenn Media Foundation fehlt (Windows N/KN ohne Media Feature Pack).
    pub const MISSING_HINT: &str = "Für Videos braucht Windows das „Media Feature Pack“. Diese Windows-Ausgabe (N/KN) enthält es nicht. \
Installieren unter Einstellungen → Apps → Optionale Features → Feature hinzufügen → „Media Feature Pack“, danach neu starten. \
Screenshots funktionieren auch ohne.";

    /// Media Foundation vorhanden? Ohne sind Aufnahme, Video-Editor und Video-/GIF-Export gesperrt.
    /// In der Attrappe mit `KNIPS_TEST_NO_MEDIA` abschaltbar.
    pub fn available() -> bool {
        std::env::var_os("KNIPS_TEST_NO_MEDIA").is_none()
    }

    pub fn probe(path: &Path) -> Result<VideoInfo> {
        let _ = path;
        bail!("Video nur unter Windows")
    }

    pub fn hevc_encoder_available() -> bool {
        false
    }

    /// HEVC nutzbar: Encoder vorhanden **und** das Ergebnis lässt sich wieder lesen.
    pub fn hevc_available() -> bool {
        false
    }

    /// Bilder aus einem Video lesen, optional verkleinert (längste Kante ≤ `max_size`).
    pub struct FrameReader {
        _private: (),
    }

    impl FrameReader {
        pub fn open(path: &Path, max_size: Option<u32>) -> Result<Self> {
            let _ = (path, max_size);
            bail!("Video nur unter Windows")
        }
        /// Bild, das zum Zeitpunkt `t` (Sekunden) zu sehen ist — genau, nicht das nächste Schlüsselbild.
        pub fn frame_at(&mut self, t: f64) -> Result<Option<RgbaImage>> {
            let _ = t;
            Ok(None)
        }
    }

    pub fn thumbnail(path: &Path, max_pixel: u32) -> Result<RgbaImage> {
        let _ = (path, max_pixel);
        bail!("Video nur unter Windows")
    }

    pub struct RecordOptions {
        pub monitor: Monitor,
        /// Aufgenommener Bereich, monitor-lokal, physische Pixel.
        pub rect: IRect,
        /// Ausgabegröße (gerade Zahlen).
        pub width: u32,
        pub height: u32,
        pub fps: u32,
        pub show_cursor: bool,
        pub show_clicks: bool,
        pub microphone: bool,
        pub hevc: bool,
        pub path: PathBuf,
    }

    /// Bildschirmaufnahme (Windows.Graphics.Capture → Media Foundation, H.264/HEVC-MP4, AAC-Mikro).
    pub struct Recorder {
        _private: (),
    }

    impl Recorder {
        /// `on_error` kommt, wenn die Aufnahme von selbst abbricht (Monitor weg, Encoder-Fehler).
        pub fn start(opts: RecordOptions, on_error: Box<dyn Fn(String) + Send + Sync>) -> Result<Recorder> {
            let _ = (opts, on_error);
            bail!("Bildschirmaufnahme nur unter Windows")
        }
        /// Beendet und schreibt die Datei fertig; liefert die Dauer in Sekunden.
        pub fn stop(self) -> Result<f64> {
            bail!("Bildschirmaufnahme nur unter Windows")
        }
        /// Verwirft die Aufnahme und löscht die Datei.
        pub fn cancel(self) {}
        /// Hinweise ohne Abbruch, z. B. „Mikrofon verweigert — Video ohne Ton“ (beim Start oder später).
        pub fn warnings(&self) -> Vec<String> {
            vec![]
        }
    }

    /// Zensiertes, gekürztes MP4 (H.264; HEVC-Quellen bleiben HEVC). Ton wird mitgenommen.
    pub fn export_mp4(
        src: &Path,
        dst: &Path,
        doc: &VideoDocument,
        scale: f64,
        progress: &mut dyn FnMut(f64),
        cancel: &AtomicBool,
    ) -> Result<()> {
        let _ = (src, dst, doc, scale, progress, cancel);
        bail!("Video nur unter Windows")
    }

    /// GIF mit `fps` Bildern pro Sekunde, Breite ≤ `width`. Liefert die Bildgröße.
    pub fn export_gif(
        src: &Path,
        dst: &Path,
        doc: &VideoDocument,
        scale: f64,
        fps: u32,
        width: u32,
        progress: &mut dyn FnMut(f64),
        cancel: &AtomicBool,
    ) -> Result<(u32, u32)> {
        let _ = (src, dst, doc, scale, fps, width, progress, cancel);
        bail!("Video nur unter Windows")
    }

    /// Testvideo aus erzeugten Bildern schreiben (Selbsttests `track`, `video`).
    pub fn write_test_video(
        path: &Path,
        width: u32,
        height: u32,
        fps: u32,
        count: usize,
        hevc: bool,
        frame: &mut dyn FnMut(usize) -> RgbaImage,
    ) -> Result<()> {
        let _ = (path, width, height, fps, count, hevc, frame);
        bail!("Video nur unter Windows")
    }

    /// Testvideo mit variabler Bildrate (wie eine Bildschirmaufnahme): Bild `i` ab `times[i]` Sekunden,
    /// das letzte bis `duration` (Selbsttest `video`).
    pub fn write_test_video_vfr(
        path: &Path,
        width: u32,
        height: u32,
        times: &[f64],
        duration: f64,
        frame: &mut dyn FnMut(usize) -> RgbaImage,
    ) -> Result<()> {
        let _ = (path, width, height, times, duration, frame);
        bail!("Video nur unter Windows")
    }
}

pub mod testinput {
    //! Simulierte Maus und Tastatur für Selbsttests (wie von der Hardware).

    pub fn move_to(x: i32, y: i32) {
        let _ = (x, y);
    }
    /// Linke Maustaste von `from` nach `to` ziehen (globale physische Pixel), in Schritten.
    pub fn drag(from: (i32, i32), to: (i32, i32), shift: bool) {
        let _ = (from, to, shift);
    }
    pub fn click(x: i32, y: i32) {
        let _ = (x, y);
    }
    /// Taste (Virtual-Key) mit Modifier-Bits drücken und loslassen.
    pub fn key(vk: u32, mods: u32) {
        let _ = (vk, mods);
    }
}

pub mod system {
    //! Angaben für die Nutzungsstatistik.

    /// Windows-Version wie „10.0.26100“ (Haupt.Neben.Build).
    pub fn os_version() -> String {
        "0.0.0".into()
    }

    /// Anzeigesprache des Benutzers, z. B. „de-DE“.
    pub fn ui_language() -> String {
        ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
            .unwrap_or_else(|| "de-DE".into())
    }
}
