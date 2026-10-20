//! Windows-Implementierung. Signaturen exakt wie in `mock/mod.rs`.

mod util;
mod d3d;
pub mod monitors;
pub mod capture;
pub mod overlay;
pub mod ocr;
pub mod clipboard;
pub mod hotkeys;
pub mod shell;
pub mod sound;
#[cfg(feature = "dev")]
pub mod sample;
pub mod media;
#[cfg(feature = "dev")]
pub mod testinput;
pub mod system;
