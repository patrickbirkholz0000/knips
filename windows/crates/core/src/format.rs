//! Anzeige- und Dateinamenformate (`Format` in Utilities.swift).

/// Dateiname-Zeitstempel in Ortszeit: `2026-10-12 um 14.03.27`.
pub fn file_date_now() -> String {
    todo!("knips-core: format::file_date_now")
}

/// `m:ss` (abgerundet). Nicht endliche oder negative Werte → `0:00`.
pub fn duration(seconds: f64) -> String {
    let _ = seconds;
    todo!("knips-core: format::duration")
}

/// `m:ss.t` (Zehntel, abgerundet). Nicht endliche oder negative Werte → `0:00.0`.
pub fn precise_duration(seconds: f64) -> String {
    let _ = seconds;
    todo!("knips-core: format::precise_duration")
}
