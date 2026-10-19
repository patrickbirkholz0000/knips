//! Plattformschicht. Unter Windows `win/` (echte Implementierung), sonst `mock/` (Attrappe, damit
//! die App auf dem Mac startet und die Oberfläche entwickelt werden kann).
//!
//! **Vertrag:** Beide Implementierungen haben exakt dieselben öffentlichen Module, Typen und
//! Funktionen. Die Attrappe in `mock/` ist die Referenz für die Signaturen.
//!
//! Koordinaten: physische Pixel. Global = virtueller Bildschirm (wie `GetCursorPos`),
//! „lokal“ = relativ zur linken oberen Ecke eines Monitors. Der Prozess ist
//! Per-Monitor-V2-DPI-aware (Tauri setzt das im Manifest).

pub mod types;

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win as imp;

#[cfg(not(windows))]
mod mock;
#[cfg(not(windows))]
use mock as imp;

pub use imp::{capture, clipboard, hotkeys, media, monitors, ocr, overlay, sample, shell, sound, system, testinput};
pub use types::*;

/// `true` unter Windows, `false` in der Attrappe.
pub const IS_REAL: bool = cfg!(windows);
