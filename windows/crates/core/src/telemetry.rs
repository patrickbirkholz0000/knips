//! Anonyme Nutzungsstatistik (Vertrag v1, gleich auf Mac und Windows): nur Zähler aus einer festen
//! Liste, dazu Version, Betriebssystem, Architektur und Sprache. Nie Bilder, Texte, Dateinamen,
//! Fenstertitel, Bildschirmgrößen oder Zeiten. Nur nach Zustimmung; ohne Zustimmung wird nicht gezählt.
//!
//! Hier steht alles, was ohne Netz und ohne Windows geht (Zustand, Nutzlast, Zeitplan, wann
//! überhaupt gesendet werden darf). Senden und Einhängen: `src-tauri/src/telemetry.rs`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Ziel der Pings; `KNIPS_TELEMETRY_URL` ersetzt es (Tests gegen einen lokalen Server).
pub const ENDPOINT: &str = "https://knips.velno.ai/v1/ping";
/// Was gesendet wird — verlinkt in Einstellungen → Datenschutz.
pub const INFO_URL: &str = "https://github.com/patrickbirkholz0000/knips#datenschutz";
/// Höchstens ein Ping pro 24 Stunden.
pub const SEND_INTERVAL_SECS: i64 = 24 * 3600;
/// Prüfen ~30 s nach dem Start, danach alle 6 Stunden.
pub const FIRST_CHECK_SECS: u64 = 30;
pub const CHECK_INTERVAL_SECS: u64 = 6 * 3600;
pub const TIMEOUT_SECS: u64 = 10;
/// Obergrenze je Zähler (wie auf dem Server); bleibt auch, wenn Senden scheitert.
pub const MAX_COUNT: u32 = 10_000;
/// Der Server lehnt größere Körper ab.
pub const MAX_BODY: usize = 4096;

/// Alle Ereignisse, die gezählt werden dürfen. Alles andere wird verworfen.
pub const EVENTS: [&str; 24] = [
    "app_launch",
    "capture_area",
    "capture_window",
    "capture_fullscreen",
    "capture_last_area",
    "capture_scroll",
    "capture_text",
    "recording_start",
    "recording_saved",
    "editor_open",
    "video_editor_open",
    "censor_manual",
    "censor_auto",
    "censor_smart",
    "export_png",
    "export_jpeg",
    "export_mp4",
    "export_gif",
    "copy_image",
    "copy_text",
    "pin",
    "drag_out",
    "history_open",
    "settings_open",
];

pub fn is_allowed(event: &str) -> bool {
    EVENTS.contains(&event)
}

/// Zustand in `settings.json` (Felder mit Vorsilbe `telemetry`).
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct TelemetryState {
    /// `None`: noch nicht beantwortet (beim nächsten Start wieder fragen).
    pub telemetry_consent: Option<bool>,
    /// Zufällige UUID v4, entsteht bei der Zustimmung, verschwindet beim Widerruf.
    pub telemetry_install_id: Option<String>,
    /// Zähler seit dem letzten erfolgreichen Senden.
    pub telemetry_counts: BTreeMap<String, u32>,
    /// Unix-Sekunden des letzten erfolgreichen Sendens.
    pub telemetry_last_sent: Option<i64>,
}

impl TelemetryState {
    pub fn counting(&self) -> bool {
        self.telemetry_consent == Some(true) && self.telemetry_install_id.is_some()
    }

    /// Zählt ein erlaubtes Ereignis (nur mit Zustimmung). Liefert, ob sich etwas geändert hat.
    pub fn record(&mut self, event: &str) -> bool {
        if !self.counting() || !is_allowed(event) {
            return false;
        }
        let n = self.telemetry_counts.entry(event.to_string()).or_insert(0);
        if *n >= MAX_COUNT {
            return false;
        }
        *n += 1;
        true
    }

    /// Zustimmung: neue Kennung, ab jetzt zählen.
    pub fn opt_in(&mut self, install_id: String) {
        if self.counting() {
            return;
        }
        self.telemetry_consent = Some(true);
        self.telemetry_install_id = Some(install_id);
        self.telemetry_counts.clear();
    }

    /// Ablehnung oder Widerruf: Kennung und offene Zähler sofort löschen.
    pub fn opt_out(&mut self) {
        self.telemetry_consent = Some(false);
        self.telemetry_install_id = None;
        self.telemetry_counts.clear();
        self.telemetry_last_sent = None;
    }

    /// Erfolgreich gesendet: genau die gesendeten Zähler abziehen (was währenddessen dazukam, bleibt).
    pub fn mark_sent(&mut self, sent: &BTreeMap<String, u32>, now: i64) {
        for (name, n) in sent {
            if let Some(cur) = self.telemetry_counts.get_mut(name) {
                *cur = cur.saturating_sub(*n);
            }
        }
        self.telemetry_counts.retain(|_, n| *n > 0);
        self.telemetry_last_sent = Some(now);
    }

    /// Nach dem Laden: unbekannte Namen weg, Obergrenze, Kennung nur mit Zustimmung.
    pub fn sanitize(&mut self) {
        self.telemetry_counts.retain(|k, n| is_allowed(k) && *n > 0);
        for n in self.telemetry_counts.values_mut() {
            *n = (*n).min(MAX_COUNT);
        }
        if self.telemetry_consent != Some(true) {
            self.telemetry_install_id = None;
            self.telemetry_counts.clear();
        } else if self.telemetry_install_id.as_deref().map(|id| !is_uuid_v4(id)).unwrap_or(true) {
            // Zustimmung ohne gültige Kennung: wie „noch nicht gefragt“.
            self.telemetry_consent = None;
            self.telemetry_install_id = None;
            self.telemetry_counts.clear();
        }
    }
}

/// Fällig, wenn noch nie oder vor mindestens 24 h gesendet wurde (Uhr zurückgestellt → auch fällig).
pub fn due(now: i64, last_sent: Option<i64>) -> bool {
    match last_sent {
        None => true,
        Some(t) => now - t >= SEND_INTERVAL_SECS || now < t,
    }
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    Release,
    Dev,
}

impl Channel {
    pub fn as_str(self) -> &'static str {
        match self {
            Channel::Release => "release",
            Channel::Dev => "dev",
        }
    }
}

/// Darf diese Sitzung überhaupt senden (und um Zustimmung fragen)?
/// - Selbsttests und Test-Sandbox (`--selftest`, `KNIPS_TEST_DIR`): nie.
/// - CI (`CI`, `GITHUB_ACTIONS`): nie.
/// - Entwickler-Build (Feature `dev`): nur mit `KNIPS_TELEMETRY=1`, dann Kanal „dev“.
pub fn gate(sandbox: bool, dev_build: bool, env: impl Fn(&str) -> Option<String>) -> Option<Channel> {
    let set = |name: &str| env(name).map(|v| !v.trim().is_empty()).unwrap_or(false);
    if sandbox || set("KNIPS_TEST_DIR") || set("CI") || set("GITHUB_ACTIONS") {
        return None;
    }
    if dev_build {
        return (env("KNIPS_TELEMETRY").as_deref().map(str::trim) == Some("1")).then_some(Channel::Dev);
    }
    Some(Channel::Release)
}

/// Was neben den Zählern gesendet wird.
#[derive(Clone, Debug, PartialEq)]
pub struct ClientInfo {
    pub platform: &'static str,
    pub channel: Channel,
    pub app_version: String,
    pub build: String,
    pub os_version: String,
    pub arch: &'static str,
    pub lang: String,
}

#[derive(Serialize)]
struct Ping<'a> {
    v: u32,
    app: &'static str,
    platform: &'a str,
    channel: &'a str,
    app_version: &'a str,
    build: &'a str,
    os_version: &'a str,
    arch: &'a str,
    lang: &'a str,
    install_id: &'a str,
    events: BTreeMap<&'a str, u32>,
}

/// JSON-Körper des Pings: nur erlaubte Ereignisse, je höchstens `MAX_COUNT`, keine Nullen.
pub fn payload(info: &ClientInfo, install_id: &str, counts: &BTreeMap<String, u32>) -> Vec<u8> {
    let events: BTreeMap<&str, u32> = counts
        .iter()
        .filter(|(k, n)| is_allowed(k) && **n > 0)
        .map(|(k, n)| (k.as_str(), (*n).min(MAX_COUNT)))
        .collect();
    let ping = Ping {
        v: 1,
        app: "knips",
        platform: info.platform,
        channel: info.channel.as_str(),
        app_version: &info.app_version,
        build: &info.build,
        os_version: &info.os_version,
        arch: info.arch,
        lang: &info.lang,
        install_id,
        events,
    };
    serde_json::to_vec(&ping).unwrap_or_default()
}

/// `std::env::consts::ARCH` → Name im Vertrag.
pub fn arch_name(arch: &str) -> &'static str {
    match arch {
        "aarch64" | "arm64" => "arm64",
        _ => "x86_64",
    }
}

/// „de-DE“, „de_DE.UTF-8“, „en“ → „de“/„en“; sonst leer.
pub fn lang_code(locale: &str) -> String {
    let code: String = locale.trim().chars().take_while(|c| c.is_ascii_alphabetic()).collect::<String>().to_ascii_lowercase();
    if code.len() == 2 {
        code
    } else {
        String::new()
    }
}

/// Kennung: UUID v4 in Kleinbuchstaben mit Bindestrichen.
pub fn is_uuid_v4(s: &str) -> bool {
    uuid::Uuid::parse_str(s).map(|u| u.get_version_num() == 4 && s.len() == 36 && s == u.to_string()).unwrap_or(false)
}

pub fn new_install_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info() -> ClientInfo {
        ClientInfo {
            platform: "windows",
            channel: Channel::Release,
            app_version: "0.1.0".into(),
            build: "0".into(),
            os_version: "10.0.26100".into(),
            arch: "x86_64",
            lang: "de".into(),
        }
    }

    fn opted_in() -> TelemetryState {
        let mut s = TelemetryState::default();
        s.opt_in(new_install_id());
        s
    }

    #[test]
    fn allowlist_has_24_unique_events() {
        let set: std::collections::BTreeSet<_> = EVENTS.iter().collect();
        assert_eq!(set.len(), 24);
        assert!(is_allowed("capture_area") && is_allowed("settings_open"));
        assert!(!is_allowed("Capture_Area") && !is_allowed("file_name") && !is_allowed(""));
    }

    #[test]
    fn no_counting_without_consent() {
        let mut s = TelemetryState::default();
        assert!(!s.record("capture_area"));
        s.opt_out();
        assert!(!s.record("capture_area"));
        assert!(s.telemetry_counts.is_empty() && s.telemetry_install_id.is_none());
    }

    #[test]
    fn counts_only_allowed_events_and_caps() {
        let mut s = opted_in();
        assert!(s.record("capture_area"));
        assert!(s.record("capture_area"));
        assert!(!s.record("window_title"));
        for _ in 0..(MAX_COUNT + 50) {
            s.record("export_png");
        }
        assert_eq!(s.telemetry_counts["capture_area"], 2);
        assert_eq!(s.telemetry_counts["export_png"], MAX_COUNT);
        assert!(!s.telemetry_counts.contains_key("window_title"));
    }

    #[test]
    fn opt_in_creates_uuid_and_opt_out_deletes_everything() {
        let mut s = opted_in();
        let id = s.telemetry_install_id.clone().unwrap();
        assert!(is_uuid_v4(&id), "{id}");
        s.record("pin");
        s.telemetry_last_sent = Some(5);
        // Zweites Zustimmen ändert die Kennung nicht.
        s.opt_in(new_install_id());
        assert_eq!(s.telemetry_install_id.as_deref(), Some(id.as_str()));
        s.opt_out();
        assert_eq!(s.telemetry_consent, Some(false));
        assert!(s.telemetry_install_id.is_none() && s.telemetry_counts.is_empty() && s.telemetry_last_sent.is_none());
        // Erneut zustimmen → neue Kennung.
        s.opt_in(new_install_id());
        assert_ne!(s.telemetry_install_id.as_deref(), Some(id.as_str()));
    }

    #[test]
    fn mark_sent_keeps_counts_added_meanwhile() {
        let mut s = opted_in();
        s.record("capture_area");
        s.record("capture_area");
        let snapshot = s.telemetry_counts.clone();
        s.record("capture_area");
        s.record("pin");
        s.mark_sent(&snapshot, 1000);
        assert_eq!(s.telemetry_counts.get("capture_area"), Some(&1));
        assert_eq!(s.telemetry_counts.get("pin"), Some(&1));
        assert_eq!(s.telemetry_last_sent, Some(1000));
    }

    #[test]
    fn schedule_once_per_day() {
        assert!(due(1_000_000, None));
        assert!(!due(1_000_000, Some(1_000_000 - 3600)));
        assert!(!due(1_000_000, Some(1_000_000 - SEND_INTERVAL_SECS + 1)));
        assert!(due(1_000_000, Some(1_000_000 - SEND_INTERVAL_SECS)));
        assert!(due(1_000_000, Some(1_000_000 + 10)), "Uhr zurückgestellt");
    }

    #[test]
    fn gate_rules() {
        let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
        assert_eq!(gate(false, false, env(&[])), Some(Channel::Release));
        assert_eq!(gate(true, false, env(&[])), None, "Sandbox");
        assert_eq!(gate(false, false, env(&[("KNIPS_TEST_DIR", "C:\\t")])), None);
        assert_eq!(gate(false, false, env(&[("CI", "true")])), None);
        assert_eq!(gate(false, false, env(&[("GITHUB_ACTIONS", "true")])), None);
        assert_eq!(gate(false, false, env(&[("CI", "")])), Some(Channel::Release));
        assert_eq!(gate(false, true, env(&[])), None, "Entwickler-Build ohne KNIPS_TELEMETRY");
        assert_eq!(gate(false, true, env(&[("KNIPS_TELEMETRY", "0")])), None);
        assert_eq!(gate(false, true, env(&[("KNIPS_TELEMETRY", "1")])), Some(Channel::Dev));
        assert_eq!(gate(false, true, env(&[("KNIPS_TELEMETRY", "1"), ("CI", "1")])), None);
        assert_eq!(gate(true, true, env(&[("KNIPS_TELEMETRY", "1")])), None);
    }

    #[test]
    fn payload_matches_contract() {
        let mut counts = BTreeMap::new();
        counts.insert("capture_area".to_string(), 3);
        counts.insert("editor_open".to_string(), 2);
        counts.insert("secret_event".to_string(), 7);
        counts.insert("pin".to_string(), 0);
        counts.insert("export_gif".to_string(), MAX_COUNT + 5);
        let id = "8f0c2a4e-1b7d-4c3a-9e5f-0a1b2c3d4e5f";
        let body = payload(&info(), id, &counts);
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        let mut want = vec!["v", "app", "platform", "channel", "app_version", "build", "os_version", "arch", "lang", "install_id", "events"];
        want.sort();
        let mut got = keys.clone();
        got.sort();
        assert_eq!(got, want);
        assert_eq!(v["v"], 1);
        assert_eq!(v["app"], "knips");
        assert_eq!(v["platform"], "windows");
        assert_eq!(v["channel"], "release");
        assert_eq!(v["os_version"], "10.0.26100");
        assert_eq!(v["arch"], "x86_64");
        assert_eq!(v["lang"], "de");
        assert_eq!(v["install_id"], id);
        assert_eq!(v["events"], serde_json::json!({ "capture_area": 3, "editor_open": 2, "export_gif": MAX_COUNT }));
    }

    #[test]
    fn payload_with_all_events_fits() {
        let counts: BTreeMap<String, u32> = EVENTS.iter().map(|e| (e.to_string(), MAX_COUNT)).collect();
        let mut i = info();
        i.channel = Channel::Dev;
        let body = payload(&i, &new_install_id(), &counts);
        assert!(body.len() <= MAX_BODY, "{} Bytes", body.len());
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["channel"], "dev");
        assert_eq!(v["events"].as_object().unwrap().len(), 24);
    }

    #[test]
    fn helpers() {
        assert_eq!(arch_name("x86_64"), "x86_64");
        assert_eq!(arch_name("aarch64"), "arm64");
        assert_eq!(lang_code("de-DE"), "de");
        assert_eq!(lang_code("en_US.UTF-8"), "en");
        assert_eq!(lang_code("FR"), "fr");
        assert_eq!(lang_code("C"), "");
        assert_eq!(lang_code(""), "");
        assert!(is_uuid_v4(&new_install_id()));
        assert!(!is_uuid_v4("8F0C2A4E-1B7D-4C3A-9E5F-0A1B2C3D4E5F"));
        assert!(!is_uuid_v4("nicht-uuid"));
    }

    #[test]
    fn state_roundtrip_and_sanitize() {
        let mut s = opted_in();
        s.record("capture_text");
        let json = serde_json::to_value(&s).unwrap();
        for key in json.as_object().unwrap().keys() {
            assert!(key.starts_with("telemetry"), "{key}");
        }
        let mut back: TelemetryState = serde_json::from_value(json).unwrap();
        back.sanitize();
        assert_eq!(back, s);
        // Fremde Zähler und Zähler ohne Zustimmung fliegen raus.
        let mut bad: TelemetryState =
            serde_json::from_str(r#"{"telemetryConsent":false,"telemetryInstallId":"x","telemetryCounts":{"pin":3}}"#).unwrap();
        bad.sanitize();
        assert!(bad.telemetry_install_id.is_none() && bad.telemetry_counts.is_empty());
        let mut broken: TelemetryState = serde_json::from_str(r#"{"telemetryConsent":true,"telemetryInstallId":"kaputt"}"#).unwrap();
        broken.sanitize();
        assert_eq!(broken.telemetry_consent, None);
        let mut odd: TelemetryState = serde_json::from_value(serde_json::json!({
            "telemetryConsent": true, "telemetryInstallId": new_install_id(), "telemetryCounts": {"pin": 99999, "foo": 1}
        }))
        .unwrap();
        odd.sanitize();
        assert_eq!(odd.telemetry_counts.len(), 1);
        assert_eq!(odd.telemetry_counts["pin"], MAX_COUNT);
    }
}
