//! Kurze Einblendung unten mittig („Kopiert“, „Gespeichert“) — `HUD` in Utilities.swift.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use knips_platform::monitors;
use serde::Serialize;

use crate::app::knips;
use crate::wm;

pub const LABEL: &str = "hud";
const SIZE: (f64, f64) = (520.0, 56.0);

pub fn spec() -> wm::Spec {
    wm::Spec::floating(LABEL, "hud", SIZE)
}

#[derive(Serialize, Clone)]
pub struct HudMessage {
    pub text: String,
    pub icon: &'static str,
}

#[derive(Default)]
pub struct Hud {
    generation: AtomicU64,
}

impl Hud {
    /// `icon`: check | text | search | error | trash | dashed | pin | copy
    pub fn show(&self, text: impl Into<String>, icon: &'static str) {
        let k = knips();
        let Ok(window) = wm::ensure(&k.app, &spec()) else { return };
        let m = monitors::at_cursor();
        let w = (SIZE.0 * m.scale) as i32;
        let h = (SIZE.1 * m.scale) as i32;
        // Mac: 64 pt über dem unteren Rand des sichtbaren Bereichs.
        let origin = (m.work.x + (m.work.width - w) / 2, m.work.bottom() - (64.0 * m.scale) as i32 - h);
        wm::place(&window, &m, SIZE, origin);
        let _ = window.set_ignore_cursor_events(true);
        k.emit("hud-show", HudMessage { text: text.into(), icon });
        let _ = window.show();
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        std::thread::spawn(move || {
            // 1,4 s stehen + 0,25 s Ausblenden (die Seite blendet selbst aus).
            std::thread::sleep(Duration::from_millis(1700));
            let k = knips();
            if k.hud.generation.load(Ordering::SeqCst) == generation {
                if let Some(w) = wm::get(&k.app, LABEL) {
                    let _ = w.hide();
                }
            }
        });
    }
}
