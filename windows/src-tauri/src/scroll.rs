//! Scroll-Screenshot (`ScrollCaptureController` in ScrollCapture.swift): Bereich wählen → während
//! des Scrollens alle 0,15 s aufnehmen → „Fertig“ setzt zusammen.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use knips_core::geometry::IRect;
use knips_core::stitch::ScrollStitcher;
use knips_platform::capture::RegionCapturer;
use knips_platform::overlay::{FrameColor, FrameWindow};
use knips_platform::Monitor;
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::wm;

const PANEL: &str = "scroll-controls";
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
    active: bool,
    stitcher: Option<ScrollStitcher>,
    frame: Option<FrameWindow>,
    monitor: Option<Monitor>,
    stop: Option<Arc<AtomicBool>>,
}

#[derive(Default)]
pub struct Scroll {
    inner: Arc<Mutex<Inner>>,
}

impl Scroll {
    pub fn is_active(&self) -> bool {
        self.inner.lock().active
    }

    pub fn state(&self) -> ScrollState {
        let inner = self.inner.lock();
        let scale = inner.monitor.as_ref().map(|m| m.scale).unwrap_or(1.0);
        let factor = knips().settings.get().output_factor(scale);
        let (sections, height) = inner.stitcher.as_ref().map(|s| (s.sections(), s.height)).unwrap_or((0, 0));
        // Höhe so, wie sie in der gespeicherten Datei herauskommt (1× oder volle Auflösung).
        ScrollState { active: inner.active, sections, output_height: (height as f64 * factor) as u32 }
    }

    fn publish(&self) {
        knips().emit("scroll-state", self.state());
    }

    /// `rect`: monitor-lokal, physische Pixel.
    pub fn begin(&self, monitor: Monitor, rect: IRect) {
        let stop = Arc::new(AtomicBool::new(false));
        let global = wm::global(&monitor, rect);
        {
            let mut inner = self.inner.lock();
            if inner.active {
                return;
            }
            inner.active = true;
            inner.stitcher = None;
            inner.monitor = Some(monitor.clone());
            inner.stop = Some(stop.clone());
            inner.frame = FrameWindow::show(global, FrameColor::Scroll).ok();
        }
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
                    // Vergleichen und Anhängen (bei 4K-Bereichen ~0,1 s pro Bild) ohne die Sperre lange zu halten.
                    let mut stitcher = shared.lock().stitcher.take();
                    match stitcher.as_mut() {
                        None => stitcher = Some(ScrollStitcher::new(image)),
                        Some(s) => {
                            s.add(image);
                        }
                    }
                    let mut inner = shared.lock();
                    if inner.active {
                        inner.stitcher = stitcher;
                    }
                    drop(inner);
                    knips().scroll.publish();
                }
                std::thread::sleep(Duration::from_millis(150));
            }
        });
    }

    pub fn finish(&self, save: bool) {
        let (stitcher, monitor) = {
            let mut inner = self.inner.lock();
            if let Some(stop) = inner.stop.take() {
                stop.store(true, Ordering::SeqCst);
            }
            inner.active = false;
            inner.frame = None;
            (inner.stitcher.take(), inner.monitor.take())
        };
        if let Some(w) = wm::get(&knips().app, PANEL) {
            let _ = w.hide();
        }
        self.publish();
        let (Some(stitcher), Some(monitor), true) = (stitcher, monitor, save) else { return };
        std::thread::spawn(move || {
            let image = stitcher.assemble();
            let k = knips();
            k.shutter();
            k.coordinator.finish(image, monitor.scale, &monitor);
        });
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
