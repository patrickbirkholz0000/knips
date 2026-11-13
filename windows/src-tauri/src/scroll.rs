//! Scroll-Screenshot (`ScrollCaptureController` in ScrollCapture.swift): Bereich wählen → während
//! des Scrollens alle 0,15 s aufnehmen → „Fertig“ setzt zusammen. Bei `stitch::MAX_HEIGHT` Pixeln
//! endet die Aufnahme von selbst (mit Hinweis).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use knips_core::geometry::IRect;
use knips_core::stitch::{Handoff, Returned, ScrollStitcher};
use knips_platform::capture::RegionCapturer;
use knips_platform::overlay::{FrameColor, FrameWindow};
use knips_platform::Monitor;
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::wm;

pub const PANEL: &str = "scroll-controls";
const PANEL_SIZE: (f64, f64) = (380.0, 48.0);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ScrollState {
    pub active: bool,
    pub sections: usize,
    pub output_height: u32,
}

#[derive(Default)]
struct Inner {
    /// Stitcher und Monitor der Sitzung. Der Aufnahme-Thread nimmt den Stitcher für jedes Bild heraus —
    /// `Handoff` sorgt dafür, dass „Fertig“ in genau diesem Moment trotzdem speichert.
    session: Handoff<ScrollStitcher, Monitor>,
    /// Stand für die Leiste — auch während der Stitcher unterwegs ist.
    sections: usize,
    height: u32,
    scale: f64,
    frame: Option<FrameWindow>,
    stop: Option<Arc<AtomicBool>>,
}

#[derive(Default)]
pub struct Scroll {
    inner: Arc<Mutex<Inner>>,
}

impl Scroll {
    pub fn is_active(&self) -> bool {
        self.inner.lock().session.is_active()
    }

    pub fn state(&self) -> ScrollState {
        let inner = self.inner.lock();
        let factor = knips().settings.get().output_factor(if inner.scale > 0.0 { inner.scale } else { 1.0 });
        // Höhe so, wie sie in der gespeicherten Datei herauskommt (1× oder volle Auflösung).
        ScrollState { active: inner.session.is_active(), sections: inner.sections, output_height: (inner.height as f64 * factor) as u32 }
    }

    fn publish(&self) {
        knips().emit("scroll-state", self.state());
    }

    /// `rect`: monitor-lokal, physische Pixel.
    pub fn begin(&self, monitor: Monitor, rect: IRect) {
        let stop = Arc::new(AtomicBool::new(false));
        let global = wm::global(&monitor, rect);
        let session = {
            let mut inner = self.inner.lock();
            let Some(session) = inner.session.begin(monitor.clone()) else { return };
            inner.sections = 0;
            inner.height = 0;
            inner.scale = monitor.scale;
            inner.stop = Some(stop.clone());
            inner.frame = FrameWindow::show(global, FrameColor::Scroll).ok();
            session
        };
        // Karten und Menü weg, eigene Fenster aus den Ausschnitten (bis `finish`).
        wm::set_capture_session(wm::Session::Scroll, true);
        self.show_controls(&monitor, global);
        self.publish();
        let shared = self.inner.clone();
        std::thread::spawn(move || {
            let mut capturer = match RegionCapturer::new(&monitor, rect) {
                Ok(c) => c,
                Err(err) => {
                    knips().scroll.finish(false);
                    knips().alert("Scroll-Screenshot fehlgeschlagen", &format!("{err:#}"));
                    return;
                }
            };
            while !stop.load(Ordering::SeqCst) {
                if let Ok(image) = capturer.grab() {
                    // Vergleichen und Anhängen (bei 4K-Bereichen ~0,1 s pro Bild) ohne die Sperre lange zu halten:
                    // Der Stitcher ist solange bei diesem Thread.
                    let Some(taken) = shared.lock().session.take(session) else { return };
                    let stitcher = match taken {
                        None => ScrollStitcher::new(image),
                        Some(mut s) => {
                            s.add(image);
                            s
                        }
                    };
                    let (full, sections, height) = (stitcher.is_full(), stitcher.sections(), stitcher.height);
                    let mut inner = shared.lock();
                    match inner.session.give_back(session, stitcher) {
                        Returned::Kept => {
                            inner.sections = sections;
                            inner.height = height;
                        }
                        // „Fertig“ kam, während dieses Bild angehängt wurde. Der Stitcher lag nicht dort, wo `finish`
                        // ihn sucht — bis 1.0.2 ging der ganze Scroll-Screenshot damit still verloren.
                        Returned::Save(stitcher, monitor) => {
                            drop(inner);
                            save(stitcher, monitor);
                            return;
                        }
                        Returned::Dropped => return,
                    }
                    drop(inner);
                    knips().scroll.publish();
                    // Höchstlänge erreicht: von selbst fertig (mehr kann der Editor nicht darstellen).
                    if full {
                        let k = knips();
                        k.scroll.finish(true);
                        let max = knips_core::stitch::MAX_HEIGHT;
                        k.hud.show(format!("Scroll-Screenshot fertig · Höchstlänge {} {:03} px erreicht", max / 1000, max % 1000), "check");
                        return;
                    }
                }
                std::thread::sleep(Duration::from_millis(150));
            }
        });
    }

    pub fn finish(&self, save_result: bool) {
        let done = {
            let mut inner = self.inner.lock();
            if let Some(stop) = inner.stop.take() {
                stop.store(true, Ordering::SeqCst);
            }
            inner.frame = None;
            // `None` trotz Speichern: nichts aufgenommen — oder der Aufnahme-Thread hängt gerade ein Bild an und
            // speichert selbst, sobald er fertig ist.
            inner.session.finish(save_result)
        };
        if let Some(w) = wm::get(&knips().app, PANEL) {
            let _ = w.hide();
        }
        wm::set_capture_session(wm::Session::Scroll, false);
        self.publish();
        if let Some((stitcher, monitor)) = done {
            save(stitcher, monitor);
        }
    }

    fn show_controls(&self, monitor: &Monitor, area: IRect) {
        let Ok(window) = wm::ensure(&knips().app, &wm::Spec::floating(PANEL, "scroll-controls", PANEL_SIZE)) else { return };
        let s = monitor.scale;
        let (w, h) = ((PANEL_SIZE.0 * s) as i32, (PANEL_SIZE.1 * s) as i32);
        let gap = (12.0 * s) as i32;
        let work = monitor.work;
        let mut x = area.x + (area.width - w) / 2;
        let mut y = area.bottom() + gap;
        if y + h > work.bottom() - (4.0 * s) as i32 {
            y = (area.y - h - gap).max(work.y + (4.0 * s) as i32);
        }
        x = x.clamp(work.x + (8.0 * s) as i32, work.right() - w - (8.0 * s) as i32);
        wm::place(&window, monitor, PANEL_SIZE, (x, y));
        let _ = window.show();
    }
}

/// Zusammensetzen und als Aufnahme ablegen (eigener Thread: ein langes Bild braucht einen Moment).
fn save(stitcher: ScrollStitcher, monitor: Monitor) {
    crate::telemetry::count("capture_scroll");
    std::thread::spawn(move || {
        let image = stitcher.into_image();
        let k = knips();
        k.shutter();
        k.coordinator.finish(image, monitor.scale, &monitor);
    });
}
