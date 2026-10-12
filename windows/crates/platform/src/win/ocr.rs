//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use anyhow::Result;
use knips_core::model::TextLine;
use knips_core::RgbaImage;

/// Texterkennung (lokal). Verkleinert intern auf ≤ 2048 px und rechnet zurück; Zeilen in
/// Lesereihenfolge, `TextLine.text` = Wörter mit Leerzeichen.
pub fn recognize(img: &RgbaImage) -> Result<Vec<TextLine>> {
    let _ = img;
    Ok(vec![])
}

pub fn available() -> bool {
    false
}
