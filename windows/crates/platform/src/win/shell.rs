//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use std::path::Path;

use anyhow::Result;

/// Datei/Ordner mit der Standard-App öffnen.
pub fn open_path(path: &Path) -> Result<()> {
    std::process::Command::new("open").arg(path).spawn()?;
    Ok(())
}

/// Im Explorer zeigen und markieren.
pub fn reveal(path: &Path) -> Result<()> {
    std::process::Command::new("open").arg("-R").arg(path).spawn()?;
    Ok(())
}

/// In den Papierkorb.
pub fn trash(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub fn open_url(url: &str) -> Result<()> {
    std::process::Command::new("open").arg(url).spawn()?;
    Ok(())
}

/// Fenster nach vorn holen (auch wenn Knips gerade nicht im Vordergrund ist).
pub fn activate(hwnd: isize) {
    let _ = hwnd;
}

/// Aktuelles Vordergrundfenster (um den Fokus nach dem Overlay zurückzugeben).
pub fn foreground() -> isize {
    0
}

pub fn beep() {}
