//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

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
