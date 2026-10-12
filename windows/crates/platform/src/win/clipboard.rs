//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

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
