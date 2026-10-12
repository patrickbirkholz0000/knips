//! Anzeige- und Dateinamenformate (`Format` in Utilities.swift).

use chrono::{DateTime, Local, TimeZone};

/// Zeitstempel im Dateinamenformat `yyyy-MM-dd 'um' HH.mm.ss` für einen beliebigen Zeitpunkt.
pub fn file_date<Tz: TimeZone>(date: &DateTime<Tz>) -> String
where
    Tz::Offset: std::fmt::Display,
{
    date.format("%Y-%m-%d um %H.%M.%S").to_string()
}

/// Dateiname-Zeitstempel in Ortszeit: `2026-10-12 um 14.03.27`.
pub fn file_date_now() -> String {
    file_date(&Local::now())
}

/// `m:ss` (abgerundet). Nicht endliche oder negative Werte → `0:00`.
pub fn duration(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "0:00".into();
    }
    let total = seconds.floor() as u64;
    format!("{}:{:02}", total / 60, total % 60)
}

/// `m:ss.t` (Zehntel, abgerundet). Nicht endliche oder negative Werte → `0:00.0`.
pub fn precise_duration(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "0:00.0".into();
    }
    let tenths = (seconds * 10.0).floor() as u64;
    format!("{}:{:02}.{}", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    #[test]
    fn durations() {
        assert_eq!(duration(0.0), "0:00");
        assert_eq!(duration(59.99), "0:59");
        assert_eq!(duration(61.0), "1:01");
        assert_eq!(duration(3725.4), "62:05");
        assert_eq!(duration(-1.0), "0:00");
        assert_eq!(duration(f64::NAN), "0:00");
        assert_eq!(duration(f64::INFINITY), "0:00");
        assert_eq!(precise_duration(0.0), "0:00.0");
        assert_eq!(precise_duration(65.37), "1:05.3");
        assert_eq!(precise_duration(9.99), "0:09.9");
        assert_eq!(precise_duration(-0.1), "0:00.0");
        assert_eq!(precise_duration(f64::NAN), "0:00.0");
    }

    #[test]
    fn file_date_format() {
        let d = NaiveDate::from_ymd_opt(2026, 10, 12).unwrap().and_hms_opt(14, 3, 27).unwrap();
        let local = Local.from_local_datetime(&d).unwrap();
        assert_eq!(file_date(&local), "2026-10-12 um 14.03.27");
        let now = file_date_now();
        assert_eq!(now.len(), "2026-10-12 um 14.03.27".len());
        assert!(now.contains(" um "));
    }
}
