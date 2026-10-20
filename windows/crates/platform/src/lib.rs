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

pub use imp::{capture, clipboard, hotkeys, media, monitors, ocr, overlay, shell, sound, system};
/// Testbild und simulierte Eingaben: unter Windows nur mit Feature `dev` (Selbsttests).
#[cfg(any(feature = "dev", not(windows)))]
pub use imp::{sample, testinput};
pub use types::*;

/// `true` unter Windows, `false` in der Attrappe.
pub const IS_REAL: bool = cfg!(windows);

/// Reine Video-Rechnungen (Bildrate, Zeit, Pixel) ohne Windows-Aufrufe: auch auf dem Mac testen
/// (`cargo test -p knips-platform`).
#[cfg(all(test, not(windows)))]
#[path = "win/media/pure.rs"]
mod media_pure;

/// Geometrie und Farben des Auswahl-Overlays (ohne Windows-Aufrufe), ebenso auf dem Mac testbar.
#[cfg(all(test, not(windows)))]
#[path = "win/overlay/layout.rs"]
mod overlay_layout;
#[cfg(all(test, not(windows)))]
#[path = "win/overlay/brand.rs"]
mod overlay_brand;
