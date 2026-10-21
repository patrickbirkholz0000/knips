//! Ablauf der Aufnahmen (`CaptureCoordinator.swift`): Standbild → Auswahl-Overlay → Aufnahme
//! anlegen → Zwischenablage, Karte, Editor.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::Result;
use knips_core::geometry::IRect;
use knips_core::imageops;
use knips_core::settings::HotkeyAction;
use knips_core::RgbaImage;
use knips_platform::overlay::{self, Purpose, Selection};
use knips_platform::{capture, clipboard, monitors, Frozen, Monitor};
use parking_lot::Mutex;

use crate::app::knips;
use crate::crash::OnDrop;
use crate::promise::output_promise;
use crate::telemetry::count;
use crate::wm;

#[derive(Default)]
pub struct Coordinator {
    /// Zuletzt aufgenommener Bereich (Monitor + Rechteck, monitor-lokal) für „Letzten Bereich wiederholen“.
    last_area: Mutex<Option<(isize, IRect)>>,
    /// Ein Overlay wird gerade vorbereitet (Standbild läuft).
    preparing: AtomicBool,
}

impl Coordinator {
    /// Aus Kürzel, Menü oder URL. Kehrt sofort zurück; die Arbeit läuft in einem eigenen Thread.
    pub fn perform(&self, action: HotkeyAction) {
        std::thread::spawn(move || {
            let c = &knips().coordinator;
            match action {
                HotkeyAction::CaptureArea => c.capture_interactive(false),
                HotkeyAction::CaptureWindow => c.capture_interactive(true),
                HotkeyAction::CaptureFullscreen => c.capture_fullscreen(),
                HotkeyAction::CaptureLastArea => c.capture_last_area(),
                HotkeyAction::CaptureText => c.capture_text(),
                HotkeyAction::CaptureScrolling => c.capture_scrolling(),
                HotkeyAction::ToggleRecording => c.toggle_recording(),
                HotkeyAction::PinClipboard => c.pin_clipboard(),
            }
        });
    }

    /// Standbild aller Bildschirme, dann Overlay. `on_result` bekommt Auswahl und Standbilder.
    fn present_overlay(
        &self,
        purpose: Purpose,
        window_mode: bool,
        on_result: impl FnOnce(Selection, Vec<Frozen>) + Send + 'static,
    ) {
        if overlay::is_active() || knips().recording.is_busy() || self.preparing.swap(true, Ordering::SeqCst) {
            return;
        }
        // Zurücksetzen auch nach einem Absturz beim Standbild — sonst bliebe jede weitere Auswahl aus.
        let _preparing = OnDrop(|| self.preparing.store(false, Ordering::SeqCst));
        crate::menu::close(&knips().app);
        let result = (|| -> Result<()> {
            // Eigene Fenster gehören nicht ins Standbild (siehe `wm::conceal_for_still`). Ab Windows 10 2004 sind sie
            // nur für Aufnahmen verborgen und gleich wieder frei; davor bleiben sie unsichtbar, bis die Auswahl vorbei ist.
            let conceal = wm::conceal_for_still();
            let frozen = capture::freeze(&monitors::list());
            let conceal = if conceal.on_screen() {
                drop(conceal);
                None
            } else {
                Some(conceal)
            };
            let frozen = frozen?;
            #[cfg(feature = "dev")]
            crate::selftest_capture::after_freeze(&frozen);
            let windows = capture::windows();
            let kept = frozen.clone();
            overlay::present(
                frozen,
                windows,
                purpose,
                window_mode,
                Box::new(move |selection| {
                    drop(conceal);
                    on_result(selection, kept)
                }),
            )
        })();
        if let Err(err) = result {
            report(&err);
        }
    }

    // ------------------------------------------------------------ Screenshot

    pub fn capture_interactive(&self, window_mode: bool) {
        self.present_overlay(Purpose::Screenshot, window_mode, |selection, frozen| {
            knips().coordinator.handle_screenshot(selection, &frozen);
        });
    }

    pub fn capture_fullscreen(&self) {
        if overlay::is_active() {
            return;
        }
        let monitor = monitors::at_cursor();
        let conceal = wm::conceal_for_still();
        let frozen = capture::freeze(std::slice::from_ref(&monitor));
        drop(conceal);
        match frozen {
            Ok(mut frozen) if !frozen.is_empty() => {
                knips().shutter();
                let f = frozen.remove(0);
                count("capture_fullscreen");
                self.finish(f.image, f.monitor.scale, &f.monitor);
            }
            Ok(_) => {}
            Err(err) => report(&err),
        }
    }

    fn handle_screenshot(&self, selection: Selection, frozen: &[Frozen]) {
        if matches!(selection, Selection::Cancelled) {
            return;
        }
        // Auslöser sofort beim Loslassen — die Arbeit danach läuft im Hintergrund weiter.
        knips().shutter();
        count(match &selection {
            Selection::Window { .. } => "capture_window",
            Selection::FullScreen { .. } => "capture_fullscreen",
            _ => "capture_area",
        });
        let still = |m: &Monitor| frozen.iter().find(|f| f.monitor.id == m.id);
        match selection {
            Selection::Cancelled => {}
            Selection::FullScreen { monitor } => {
                if let Some(f) = still(&monitor) {
                    self.finish(f.image.clone(), f.monitor.scale, &monitor);
                }
            }
            Selection::Area { monitor, rect } => {
                if let Some(image) = still(&monitor).and_then(|f| imageops::crop(&f.image, rect)) {
                    *self.last_area.lock() = Some((monitor.id, rect));
                    self.finish(image, monitor.scale, &monitor);
                }
            }
            Selection::Window { window, monitor } => {
                match capture::window_image(&window) {
                    Ok(image) => self.finish(image, monitor.scale, &monitor),
                    Err(err) => {
                        // Fallback: Ausschnitt aus dem Standbild.
                        log::warn!("Fensteraufnahme fehlgeschlagen ({err:#}), nehme Ausschnitt");
                        let local = window_local(&window.rect, &monitor);
                        if let Some(image) = still(&monitor).zip(local).and_then(|(f, r)| imageops::crop(&f.image, r)) {
                            self.finish(image, monitor.scale, &monitor);
                        }
                    }
                }
            }
        }
    }

    /// Nur Test-Sandbox: letzten Bereich setzen, ohne Maus.
    #[cfg(feature = "dev")]
    pub fn debug_set_last_area(&self, rect: IRect) {
        *self.last_area.lock() = Some((monitors::primary().id, rect));
    }

    /// Gleicher Ausschnitt wie beim letzten Mal — ohne Overlay.
    pub fn capture_last_area(&self) {
        if overlay::is_active() {
            return;
        }
        let last = *self.last_area.lock();
        let found = last.and_then(|(id, rect)| monitors::list().into_iter().find(|m| m.id == id).map(|m| (m, rect)));
        let Some((monitor, rect)) = found else {
            knips().hud.show("Noch kein Bereich aufgenommen", "dashed");
            self.capture_interactive(false);
            return;
        };
        let conceal = wm::conceal_for_still();
        let frozen = capture::freeze(std::slice::from_ref(&monitor));
        drop(conceal);
        match frozen {
            Ok(frozen) => {
                if let Some(image) = frozen.first().and_then(|f| imageops::crop(&f.image, rect)) {
                    knips().shutter();
                    count("capture_last_area");
                    self.finish(image, monitor.scale, &monitor);
                }
            }
            Err(err) => report(&err),
        }
    }

    /// Bereich wählen, dann scrollen — Knips setzt die Abschnitte zu einem langen Bild zusammen.
    pub fn capture_scrolling(&self) {
        if knips().scroll.is_active() {
            knips().scroll.finish(true);
            return;
        }
        self.present_overlay(Purpose::Scroll, false, |selection, _| {
            if let Some((monitor, rect)) = area_of(selection) {
                knips().scroll.begin(monitor, rect);
            }
        });
    }

    /// Bereich ziehen → erkannter Text in die Zwischenablage, keine Datei.
    pub fn capture_text(&self) {
        self.present_overlay(Purpose::Text, false, |selection, frozen| {
            let image = match &selection {
                Selection::Cancelled => None,
                Selection::Area { monitor, rect } => frozen.iter().find(|f| f.monitor.id == monitor.id).and_then(|f| imageops::crop(&f.image, *rect)),
                Selection::FullScreen { monitor } => frozen.iter().find(|f| f.monitor.id == monitor.id).map(|f| f.image.clone()),
                Selection::Window { window, monitor } => window_local(&window.rect, monitor)
                    .and_then(|r| frozen.iter().find(|f| f.monitor.id == monitor.id).and_then(|f| imageops::crop(&f.image, r))),
            };
            if let Some(image) = image {
                count("capture_text");
                copy_text_of(&image);
            }
        });
    }

    /// Legt die Aufnahme an. Kodieren und Schreiben laufen im Hintergrund; die Zwischenablage
    /// liefert die Bilddaten erst, wenn eine App sie anfragt.
    pub fn finish(&self, image: RgbaImage, scale: f64, monitor: &Monitor) {
        let k = knips();
        let settings = k.settings.get();
        let factor = settings.output_factor(scale);
        let source = Arc::new(image);
        let for_output = source.clone();
        let output = output_promise(factor, settings.image_format, move || Some(for_output.as_ref().clone()));
        let image = Arc::try_unwrap(source).unwrap_or_else(|a| a.as_ref().clone());
        match k.store.add_image(image, scale, Some(output.clone()), None) {
            Ok(item) => {
                if settings.copy_to_clipboard {
                    // Noch unzensiert: nicht in den Zwischenablageverlauf (Win+V) und nicht in die Cloud.
                    let _ = clipboard::set_image_private(Arc::new(output));
                }
                if settings.show_quick_access {
                    k.cards.show(item.clone(), monitor.clone());
                }
                if settings.open_editor_after_capture {
                    crate::commands::open_item(&k.app, item.id, None);
                }
            }
            Err(err) => report(&err),
        }
    }

    // ------------------------------------------------------------ Bildschirmaufnahme

    pub fn toggle_recording(&self) {
        let recording = &knips().recording;
        if recording.is_busy() {
            // Läuft: speichern. Countdown: abbrechen.
            recording.stop(true);
            return;
        }
        // Windows N/KN ohne Media Feature Pack: kein Video — Hinweis statt Auswahl.
        if !knips_platform::media::available() {
            crate::recording::media_missing_hint();
            return;
        }
        self.present_overlay(Purpose::Recording, false, |selection, _| {
            if let Some((monitor, rect)) = area_of(selection) {
                knips().recording.begin(monitor, rect);
            }
        });
    }

    // ------------------------------------------------------------ Sonstiges

    pub fn pin_clipboard(&self) {
        match clipboard::get_image() {
            Some(image) => {
                let scale = monitors::at_cursor().scale;
                match knips().pins.pin(Arc::new(image), scale) {
                    Ok(()) => count("pin"),
                    Err(err) => report(&err),
                }
            }
            None => knips().hud.show("Kein Bild in der Zwischenablage", "error"),
        }
    }

    pub fn open_image_file(&self) {
        use tauri_plugin_dialog::DialogExt;
        let k = knips();
        let picked = k
            .app
            .dialog()
            .file()
            .set_title("Bild zum Bearbeiten öffnen")
            .add_filter("Bilder", &["png", "jpg", "jpeg", "bmp", "gif"])
            .blocking_pick_file();
        let Some(path) = picked.and_then(|p| p.into_path().ok()) else { return };
        match k.store.import_image(&path) {
            Ok(item) => crate::commands::open_item(&k.app, item.id, None),
            Err(err) => report(&err),
        }
    }
}

/// Text eines Bildes erkennen und kopieren (mit Einblendung wie auf dem Mac).
pub fn copy_text_of(image: &RgbaImage) {
    let k = knips();
    let lines = knips_platform::ocr::recognize(image).unwrap_or_else(|err| {
        log::error!("Texterkennung fehlgeschlagen: {err:#}");
        vec![]
    });
    let text = knips_core::textlayout::plain_text(&lines, &[]);
    if text.is_empty() {
        k.hud.show("Kein Text gefunden", "search");
    } else {
        let _ = clipboard::set_text(&text);
        let n = text.lines().count();
        k.hud.show(format!("Text kopiert · {n} Zeile{}", if n == 1 { "" } else { "n" }), "text");
    }
}

/// Fenster-Rechteck (global) → monitor-lokal, auf den Monitor begrenzt.
fn window_local(rect: &IRect, monitor: &Monitor) -> Option<IRect> {
    rect.offset(-monitor.rect.x, -monitor.rect.y).intersection(&IRect::new(0, 0, monitor.rect.width, monitor.rect.height))
}

/// Auswahl → (Monitor, monitor-lokaler Bereich) für Aufnahme und Scroll-Screenshot.
fn area_of(selection: Selection) -> Option<(Monitor, IRect)> {
    match selection {
        Selection::Cancelled => None,
        Selection::Area { monitor, rect } => Some((monitor, rect)),
        Selection::FullScreen { monitor } => {
            let r = IRect::new(0, 0, monitor.rect.width, monitor.rect.height);
            Some((monitor, r))
        }
        Selection::Window { window, monitor } => window_local(&window.rect, &monitor).map(|r| (monitor, r)),
    }
}

fn report(err: &anyhow::Error) {
    knips().alert("Aufnahme fehlgeschlagen", &format!("{err:#}"));
}
