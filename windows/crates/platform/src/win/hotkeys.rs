//! TODO(Windows): Startfassung = Kopie der Attrappe. Durch die echte Implementierung ersetzen,
//! Signaturen exakt beibehalten (Referenz: `mock/mod.rs`).

use anyhow::Result;
use knips_core::settings::KeyCombo;

pub enum RecordResult {
    Combo(KeyCombo),
    /// Rücktaste/Entf ohne Strg/Alt/Win: Kürzel entfernen.
    Remove,
    /// Esc.
    Cancel,
}

/// Startet den Kürzel-Thread. `on_fire(id)` kommt aus diesem Thread.
pub fn start(on_fire: Box<dyn Fn(u32) + Send + Sync>) {
    let _ = on_fire;
}

/// Ersetzt alle Kürzel. `RegisterHotKey`, wo möglich; Win-Kombinationen, belegte Kürzel und
/// Druck (solange Windows sie dem Bildschirmausschnitt gibt) über den Tastatur-Hook, der die
/// Taste dann verschluckt. Liefert die IDs, die gar nicht funktionieren.
pub fn apply(bindings: &[(u32, KeyCombo)]) -> Vec<u32> {
    let _ = bindings;
    vec![]
}

/// Nächste Tastenkombination aufnehmen (Einstellungen). Solange ruhen alle Kürzel; die Tasten
/// werden verschluckt (auch Druck und Win-Kombinationen). Ungültige Kombination → Signalton,
/// weiter warten.
pub fn record(on_result: Box<dyn FnOnce(RecordResult) + Send>) {
    std::thread::spawn(move || on_result(RecordResult::Cancel));
}

pub fn cancel_record() {}

/// „Druck-Taste zum Öffnen der Bildschirmausschnitterstellung verwenden“ (Windows 11).
pub fn snipping_key_enabled() -> bool {
    false
}

/// Schreibt `HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled`.
pub fn set_snipping_key(enabled: bool) -> Result<()> {
    let _ = enabled;
    Ok(())
}
