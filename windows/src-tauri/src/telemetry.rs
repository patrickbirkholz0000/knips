//! Anonyme Nutzungsstatistik (Vertrag v1, wie auf dem Mac): nach Zustimmung zählen, höchstens einmal
//! am Tag im Hintergrund senden. Regeln, Nutzlast und Zustand: `knips_core::telemetry`.
//!
//! Gezählt wird an den Stellen, an denen eine Aktion wirklich passiert ist (`count("capture_area")`
//! usw. in coordinator.rs, commands.rs, recording.rs, scroll.rs; „censor_manual“/„censor_smart“
//! meldet der Editor über `telemetry_count`). Ohne Zustimmung, in Selbsttests, in der Test-Sandbox
//! und in der CI wird weder gezählt noch gefragt noch gesendet.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use knips_core::telemetry::{self as tm, Channel, ClientInfo};
use parking_lot::Mutex;
use tauri::AppHandle;

use crate::settings::SettingsStore;
use crate::wm;

pub const CONSENT_LABEL: &str = "consent";
const CONSENT_SIZE: (f64, f64) = (460.0, 296.0);

/// Wohin und als was gesendet wird.
#[derive(Clone, Debug)]
pub struct Config {
    pub endpoint: String,
    pub info: ClientInfo,
}

/// Ergebnis einer Prüfung.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// Diese Sitzung sendet nie (Sandbox, CI, Entwickler-Build ohne `KNIPS_TELEMETRY=1`).
    Off,
    NoConsent,
    NotDue,
    Sent(u16),
    /// Zähler bleiben, nächster Versuch bei der nächsten Prüfung.
    Failed(String),
}

pub struct Telemetry {
    settings: Arc<SettingsStore>,
    /// `None`: Diese Sitzung zählt, fragt und sendet nicht.
    config: Option<Config>,
    /// Pro Start höchstens einmal fragen.
    asked: AtomicBool,
    /// Zähler werden gebündelt gespeichert (nicht bei jedem Klick im Haupt-Thread).
    save_pending: Arc<AtomicBool>,
    sending: Mutex<()>,
}

impl Telemetry {
    /// Für die App: Kanal und Ziel aus Build und Umgebung.
    pub fn from_env(settings: Arc<SettingsStore>, app_version: &str) -> Self {
        let sandbox = crate::paths::test_root().is_some() || std::env::args().any(|a| a == "--selftest");
        let channel = tm::gate(sandbox, cfg!(feature = "dev"), |k| std::env::var(k).ok());
        Self::new(settings, channel.map(|c| Config { endpoint: endpoint(), info: client_info(c, app_version) }))
    }

    pub fn new(settings: Arc<SettingsStore>, config: Option<Config>) -> Self {
        Self { settings, config, asked: AtomicBool::new(false), save_pending: Arc::new(AtomicBool::new(false)), sending: Mutex::new(()) }
    }

    pub fn enabled(&self) -> bool {
        self.config.is_some()
    }

    pub fn consent(&self) -> Option<bool> {
        self.settings.telemetry().telemetry_consent
    }

    /// Ereignis zählen (nur erlaubte Namen, nur mit Zustimmung, nie in Sandbox/CI).
    pub fn count(&self, event: &str) {
        if !self.enabled() {
            return;
        }
        if !self.settings.update_telemetry_in_memory(|s| s.record(event)) {
            return;
        }
        // Speichern gebündelt im Hintergrund.
        if !self.save_pending.swap(true, Ordering::SeqCst) {
            let settings = self.settings.clone();
            let pending = self.save_pending.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(800));
                pending.store(false, Ordering::SeqCst);
                settings.persist();
            });
        }
    }

    /// Zustimmung: neue Kennung, ab jetzt zählen. Ablehnung: Kennung und Zähler sofort löschen.
    pub fn set_consent(&self, yes: bool) {
        self.settings.update_telemetry(|s| {
            if yes {
                s.opt_in(tm::new_install_id());
            } else {
                s.opt_out();
            }
            true
        });
        log::info!("Nutzungsstatistik: {}", if yes { "zugestimmt" } else { "abgelehnt" });
    }

    /// Beim Start fragen? Nur wenn diese Sitzung senden darf, noch keine Antwort vorliegt und in
    /// diesem Start noch nicht gefragt wurde (Schließen ohne Wahl = „nein“, beim nächsten Start wieder).
    pub fn should_ask(&self) -> bool {
        self.enabled() && self.consent().is_none() && !self.asked.swap(true, Ordering::SeqCst)
    }

    pub fn check(&self) -> Outcome {
        self.check_at(chrono::Utc::now().timestamp())
    }

    /// Senden, wenn fällig (höchstens einmal in 24 h). Erfolg: gesendete Zähler abziehen,
    /// Zeitpunkt merken. Fehler: Zähler bleiben.
    pub fn check_at(&self, now: i64) -> Outcome {
        let Some(config) = &self.config else { return Outcome::Off };
        let _one = self.sending.lock();
        let state = self.settings.telemetry();
        let (true, Some(id)) = (state.counting(), state.telemetry_install_id.clone()) else { return Outcome::NoConsent };
        if !tm::due(now, state.telemetry_last_sent) {
            return Outcome::NotDue;
        }
        let sent = state.telemetry_counts.clone();
        let body = tm::payload(&config.info, &id, &sent);
        if body.len() > tm::MAX_BODY {
            return Outcome::Failed(format!("Nutzlast zu groß ({} Bytes)", body.len()));
        }
        match post(&config.endpoint, &body) {
            Ok(status) if (200..300).contains(&status) => {
                // Zwischendurch widerrufen oder neu zugestimmt? Dann nichts mehr anfassen.
                self.settings.update_telemetry(|s| {
                    let same = s.telemetry_install_id.as_deref() == Some(id.as_str());
                    if same {
                        s.mark_sent(&sent, now);
                    }
                    same
                });
                Outcome::Sent(status)
            }
            Ok(status) => Outcome::Failed(format!("HTTP {status}")),
            Err(err) => Outcome::Failed(format!("{err:#}")),
        }
    }

    /// Hintergrund-Thread: ~30 s nach dem Start prüfen, danach alle 6 Stunden.
    pub fn start(self: &Arc<Self>) {
        if !self.enabled() {
            return;
        }
        let this = self.clone();
        std::thread::Builder::new()
            .name("knips-telemetry".into())
            .spawn(move || {
                std::thread::sleep(Duration::from_secs(tm::FIRST_CHECK_SECS));
                loop {
                    match this.check() {
                        Outcome::Sent(status) => log::info!("Nutzungsstatistik gesendet ({status})"),
                        Outcome::Failed(err) => log::info!("Nutzungsstatistik nicht gesendet: {err}"),
                        _ => {}
                    }
                    std::thread::sleep(Duration::from_secs(tm::CHECK_INTERVAL_SECS));
                }
            })
            .ok();
    }
}

/// Ziel: der Knips-Server. Nur Entwickler-Builds (Feature `dev`) nehmen stattdessen `KNIPS_TELEMETRY_URL`,
/// und nur `https://…` oder `http://` auf diesen Rechner (`tm::endpoint_override_allowed`). Weitergabe-Builds
/// lesen die Variable nie — sonst könnte eine Umgebungsvariable die Statistik umleiten, auch unverschlüsselt.
pub fn endpoint() -> String {
    #[cfg(feature = "dev")]
    if let Some(url) = std::env::var("KNIPS_TELEMETRY_URL").ok().map(|u| u.trim().to_string()).filter(|u| !u.is_empty()) {
        if tm::endpoint_override_allowed(&url) {
            return url;
        }
        log::warn!("KNIPS_TELEMETRY_URL ignoriert: nur https:// oder http:// auf diesen Rechner");
    }
    tm::ENDPOINT.into()
}

pub fn client_info(channel: Channel, app_version: &str) -> ClientInfo {
    ClientInfo {
        platform: "windows",
        channel,
        app_version: app_version.to_string(),
        build: option_env!("KNIPS_BUILD").unwrap_or("0").to_string(),
        os_version: knips_platform::system::os_version(),
        arch: tm::arch_name(std::env::consts::ARCH),
        lang: tm::lang_code(&knips_platform::system::ui_language()),
    }
}

fn agent() -> Result<ureq::Agent> {
    let tls = native_tls::TlsConnector::new()?;
    Ok(ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(tm::TIMEOUT_SECS))
        .redirects(0)
        .user_agent("Knips")
        .tls_connector(Arc::new(tls))
        .build())
}

fn status_of(result: std::result::Result<ureq::Response, ureq::Error>) -> Result<u16> {
    match result {
        Ok(response) => Ok(response.status()),
        Err(ureq::Error::Status(status, _)) => Ok(status),
        Err(err) => Err(err.into()),
    }
}

/// Ein POST mit 10 s Zeitlimit, ohne Wiederholung, ohne Weiterleitung. Liefert den HTTP-Status.
fn post(url: &str, body: &[u8]) -> Result<u16> {
    status_of(agent()?.post(url).set("Content-Type", "application/json").send_bytes(body))
}

/// Nur Selbsttest: GET ohne Daten (prüft TLS über das System, z. B. `/v1/health`).
#[cfg(feature = "dev")]
pub fn probe(url: &str) -> Result<u16> {
    status_of(agent()?.get(url).call())
}

/// Zählt über die laufende App (tut nichts, solange sie nicht gestartet ist).
pub fn count(event: &str) {
    if let Some(k) = crate::app::try_knips() {
        k.telemetry.count(event);
    }
}

/// Einmal pro Start nach der Zustimmung fragen (nach der Druck-Tasten-Frage, nie gleichzeitig).
pub fn maybe_ask(app: &AppHandle) {
    let Some(k) = crate::app::try_knips() else { return };
    if k.telemetry.should_ask() {
        show_consent(app);
    }
}

/// Fenster „Knips verbessern?“ (`#/consent`). Schließen ohne Wahl = nein, beim nächsten Start wieder.
pub fn show_consent(app: &AppHandle) {
    if let Some(w) = wm::get(app, CONSENT_LABEL) {
        wm::present(&w);
        return;
    }
    let mut spec = wm::Spec::window(CONSENT_LABEL, "consent", "Knips", CONSENT_SIZE);
    spec.resizable = false;
    match wm::ensure(app, &spec) {
        Ok(w) => {
            wm::center_on_cursor_monitor(&w, CONSENT_SIZE);
            wm::present(&w);
        }
        Err(err) => log::error!("Frage zur Nutzungsstatistik nicht geöffnet: {err:#}"),
    }
}
