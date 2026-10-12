use knips_core::RgbaImage;
use serde::Serialize;

pub use knips_core::geometry::IRect;

/// Ein Bildschirm. Alle Rechtecke in physischen Pixeln (virtueller Bildschirm).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Monitor {
    /// HMONITOR als Zahl (stabil, solange die Anordnung gleich bleibt).
    pub id: isize,
    /// Gerätename, z. B. `\\.\DISPLAY1`.
    pub name: String,
    pub rect: IRect,
    /// Arbeitsbereich ohne Taskleiste.
    pub work: IRect,
    /// DPI / 96 (1,0 · 1,25 · 1,5 · 2,0 …).
    pub scale: f64,
    pub primary: bool,
}

impl Monitor {
    /// Rechteck in logischen Punkten (für Layout der Web-Fenster).
    pub fn work_points(&self) -> (f64, f64) {
        (self.work.width as f64 / self.scale, self.work.height as f64 / self.scale)
    }
}

/// Fremdes Fenster für den Fenstermodus. `rect` = sichtbarer Rahmen ohne Schatten
/// (`DWMWA_EXTENDED_FRAME_BOUNDS`), global, physische Pixel.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub hwnd: isize,
    pub rect: IRect,
    pub title: String,
    /// Programmname (z. B. `chrome.exe`).
    pub owner: String,
}

/// Eingefrorener Bildschirm: Standbild eines Monitors in voller Auflösung, eigene Fenster ausgeschlossen.
#[derive(Clone, Debug)]
pub struct Frozen {
    pub monitor: Monitor,
    pub image: RgbaImage,
}

impl Frozen {
    /// Pixel pro logischem Punkt des Standbilds.
    pub fn scale(&self) -> f64 {
        self.monitor.scale
    }
}
