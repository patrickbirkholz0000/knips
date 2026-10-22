//! Automatische Aktualisierung, ohne eigenen Server: einmal am Tag `latest.json` vom neuesten GitHub-Release holen,
//! eine neuere Version im Hintergrund laden und ihre Signatur prüfen. Installiert wird erst beim Beenden (Menü →
//! „Beenden“, ohne Neustart) oder per „Neu starten und aktualisieren“ — nie während einer Aufnahme, eines
//! Scroll-Screenshots oder offener Schreibvorgänge. Der NSIS-Installer läuft passiv (nur Fortschrittsbalken), pro
//! Benutzer und ohne Administratorrechte; Einstellungen, Ablage, Verlauf und die Druck-Taste fasst er im
//! Aktualisierungsmodus (`/UPDATE`) nicht an.
//!
//! Feed, Signatur und Versionsvergleich übernimmt `tauri-plugin-updater` (Adresse und öffentlicher Schlüssel in
//! tauri.conf.json, `plugins.updater`; die Signatur bindet auch die Versionsnummer). Die Oberfläche bekommt keine
//! Rechte am Plugin, nur die eigenen Befehle `update_check` und `update_install`.
//!
//! Wann gesucht wird: `knips_core::update` — nie in Selbsttests, Test-Sandbox, CI und Entwickler-Builds, außer über
//! den Testkanal `KNIPS_UPDATE_FEED`. Ein geladenes Update liegt im Speicher und in `<Daten>\update\` (Installer und
//! Feed), damit es einen Neustart von Windows übersteht; beim Start und vor dem Installieren prüft das Plugin die
//! Signatur erneut. Selbsttest `update`, Ende-zu-Ende-Test `scripts/update-test.ps1`.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use knips_core::update::{self as upd, Feed};
use parking_lot::{Condvar, Mutex};
use serde::Serialize;
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::{Update, Updater, UpdaterExt};

use crate::app::try_knips;
use crate::settings::SettingsStore;

/// Was der Oberfläche über `Bootstrap.update` gezeigt wird (`UpdateStatus` in src/shared/types.ts).
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    /// Sucht diese Fassung überhaupt nach Updates? Nicht in Entwickler-Builds ohne Testkanal, Test-Sandbox und CI.
    pub available: bool,
    /// "idle" | "checking" | "downloading" | "ready" | "installing"
    pub phase: &'static str,
    /// Geladene, geprüfte neue Version.
    pub version: Option<String>,
    /// Letzte erfolgreiche Suche (Unix-Sekunden).
    pub last_check: Option<i64>,
    /// Ergebnis der letzten Suche in dieser Sitzung: "current" (aktuell), "ready" oder "error".
    pub result: Option<&'static str>,
    /// Kurzer Grund, wenn die letzte Suche oder Installation nicht geklappt hat.
    pub error: Option<String>,
}

/// Ergebnis einer Suche (Protokoll, Selbsttest).
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// Diese Sitzung sucht nie.
    Off,
    /// Einstellung „Automatisch aktualisieren“ ist aus (nur die automatische Suche).
    AutoOff,
    NotDue,
    /// Es läuft schon eine Suche.
    Busy,
    Current,
    Ready(String),
    Failed(String),
}

/// Warum gerade nicht installiert wird.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Blocker {
    Recording,
    Scroll,
    Writing,
    Editors,
}

impl Blocker {
    pub fn text(self) -> &'static str {
        match self {
            Blocker::Recording => "Erst nach der Aufnahme.",
            Blocker::Scroll => "Erst nach dem Scroll-Screenshot.",
            Blocker::Writing => "Knips speichert gerade noch.",
            Blocker::Editors => "Erst die offenen Editoren schließen.",
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Busy {
    Checking,
    Downloading,
    Installing,
}

/// Geladenes, geprüftes Update.
struct Ready {
    update: Update,
    bytes: Arc<Vec<u8>>,
}

#[derive(Default)]
struct State {
    busy: Option<Busy>,
    ready: Option<Ready>,
    /// Letzter Versuch in dieser Sitzung, auch ein gescheiterter — danach erst nach `RETRY_SECS` wieder.
    last_attempt: Option<i64>,
    result: Option<&'static str>,
    error: Option<String>,
}

/// Nur Selbsttest: anderer öffentlicher Schlüssel, simuliert belegte Knips.
#[cfg(feature = "dev")]
#[derive(Default)]
pub struct TestHooks {
    pub pubkey: Option<String>,
    pub blocker: Option<Blocker>,
}

pub struct Updates {
    settings: Arc<SettingsStore>,
    /// `None`: Diese Sitzung sucht nie.
    feed: Option<Feed>,
    state: Mutex<State>,
    /// „Jetzt nach Updates suchen“ weckt den Hintergrund-Thread.
    wake: Mutex<bool>,
    wake_signal: Condvar,
    /// Höchstens eine Suche zur Zeit.
    running: Mutex<()>,
    /// Der Installer startet gleich: Knips hat schon aufgeräumt (Taskleisten-Symbol weg).
    exiting: Arc<AtomicBool>,
    #[cfg(feature = "dev")]
    pub test: Mutex<TestHooks>,
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Zwischenspeicher eines geladenen Updates: Installer und Feed (`<Daten>\update\`).
fn cache_dir() -> PathBuf {
    crate::paths::data_dir().join("update")
}
const CACHE_FEED: &str = "latest.json";
const CACHE_SETUP: &str = "Knips-setup.exe";

/// Kurzer Grund für Menschen (Einstellungen → Über Knips). Die genaue Meldung steht im Protokoll.
fn reason(err: &tauri_plugin_updater::Error) -> &'static str {
    use tauri_plugin_updater::Error as E;
    match err {
        E::Minisign(_) | E::SignedVersionMismatch { .. } | E::MissingSignedVersion | E::Base64(_) | E::SignatureUtf8(_) => {
            "Update verworfen: Die Signatur stimmt nicht."
        }
        E::Reqwest(_) | E::Network(_) => "GitHub ist gerade nicht erreichbar.",
        E::ReleaseNotFound | E::Serialization(_) | E::TargetNotFound(_) | E::TargetsNotFound(_) | E::Semver(_) => {
            "Keine passende Update-Information gefunden."
        }
        _ => "Die Suche nach Updates hat nicht geklappt.",
    }
}

fn signature_error(err: &tauri_plugin_updater::Error) -> bool {
    use tauri_plugin_updater::Error as E;
    matches!(err, E::Minisign(_) | E::SignedVersionMismatch { .. } | E::MissingSignedVersion | E::Base64(_) | E::SignatureUtf8(_))
}

impl Updates {
    /// Für die App: Feed aus Build und Umgebung (`knips_core::update::gate`).
    pub fn from_env(settings: Arc<SettingsStore>) -> Self {
        let sandbox = crate::paths::test_root().is_some() || std::env::args().any(|a| a == "--selftest");
        let feed = upd::gate(sandbox, cfg!(feature = "dev"), |k| std::env::var(k).ok());
        Self::new(settings, feed)
    }

    pub fn new(settings: Arc<SettingsStore>, feed: Option<Feed>) -> Self {
        Self {
            settings,
            feed,
            state: Mutex::new(State::default()),
            wake: Mutex::new(false),
            wake_signal: Condvar::new(),
            running: Mutex::new(()),
            exiting: Arc::new(AtomicBool::new(false)),
            #[cfg(feature = "dev")]
            test: Mutex::new(TestHooks::default()),
        }
    }

    pub fn enabled(&self) -> bool {
        self.feed.is_some()
    }

    /// Testkanal aktiv (nur Entwickler-Builds mit `KNIPS_UPDATE_FEED`).
    #[cfg(feature = "dev")]
    pub fn test_channel(&self) -> bool {
        matches!(self.feed, Some(Feed::Test(_)))
    }

    pub fn is_ready(&self) -> bool {
        self.state.lock().ready.is_some()
    }

    pub fn status(&self) -> UpdateStatus {
        let last_check = self.settings.get().update_last_check;
        let st = self.state.lock();
        let phase = match st.busy {
            Some(Busy::Checking) => "checking",
            Some(Busy::Downloading) => "downloading",
            Some(Busy::Installing) => "installing",
            None if st.ready.is_some() => "ready",
            None => "idle",
        };
        UpdateStatus {
            available: self.enabled(),
            phase,
            version: st.ready.as_ref().map(|r| r.update.version.clone()),
            last_check,
            result: st.result,
            error: st.error.clone(),
        }
    }

    fn changed(&self) {
        if let Some(k) = try_knips() {
            k.broadcast_bootstrap();
        }
    }

    fn set_busy(&self, busy: Option<Busy>) {
        self.state.lock().busy = busy;
        self.changed();
    }

    /// Hintergrund-Thread: geladenes Update aus dem Zwischenspeicher übernehmen, erste Suche einige Minuten nach
    /// dem Start, danach stündlich nachsehen, ob eine fällig ist (höchstens eine erfolgreiche am Tag).
    pub fn start(self: &Arc<Self>) {
        match &self.feed {
            None => log::info!("Aktualisierung: aus in dieser Sitzung (Entwickler-Build, Test-Sandbox oder CI)"),
            Some(Feed::Release) => log::info!("Aktualisierung: an (GitHub-Release)"),
            Some(Feed::Test(url)) => log::info!("Aktualisierung: Testkanal {url}"),
        }
        let this = self.clone();
        let spawned = std::thread::Builder::new().name("knips-update".into()).spawn(move || {
            this.restore_cached();
            if !this.enabled() {
                return;
            }
            let mut manual = this.wait(this.first_delay());
            loop {
                let outcome = if manual { this.check_now() } else { this.tick(now()) };
                match &outcome {
                    Outcome::AutoOff => log::info!("Aktualisierung: automatische Suche aus (Einstellung)"),
                    Outcome::Current => log::info!("Aktualisierung: aktuell"),
                    Outcome::Ready(version) => log::info!("Aktualisierung: {version} bereit"),
                    Outcome::Failed(err) => log::info!("Aktualisierung fehlgeschlagen: {err}"),
                    Outcome::NotDue | Outcome::Busy | Outcome::Off => {}
                }
                manual = this.wait(Duration::from_secs(upd::WAKE_SECS));
            }
        });
        if let Err(err) = spawned {
            log::error!("Aktualisierung nicht gestartet: {err}");
        }
    }

    /// Erste automatische Suche: einige Minuten nach dem Start, im Testkanal nach `KNIPS_UPDATE_DELAY` Sekunden
    /// (Standard 5).
    fn first_delay(&self) -> Duration {
        #[cfg(feature = "dev")]
        if self.test_channel() {
            let secs = std::env::var("KNIPS_UPDATE_DELAY").ok().and_then(|s| s.trim().parse().ok()).unwrap_or(5);
            return Duration::from_secs(secs);
        }
        Duration::from_secs(upd::FIRST_CHECK_SECS)
    }

    /// Wartet `timeout` oder bis „Jetzt suchen“ kommt. `true`: geweckt.
    fn wait(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut woken = self.wake.lock();
        while !*woken {
            if self.wake_signal.wait_until(&mut woken, deadline).timed_out() {
                break;
            }
        }
        std::mem::take(&mut *woken)
    }

    /// „Jetzt nach Updates suchen“: im Hintergrund, Ergebnis über `bootstrap-changed`.
    pub fn request_check(&self) {
        if !self.enabled() {
            return;
        }
        *self.wake.lock() = true;
        self.wake_signal.notify_all();
    }

    /// Automatische Suche: nur mit Einstellung und wenn fällig.
    pub fn tick(&self, now: i64) -> Outcome {
        if !self.enabled() {
            return Outcome::Off;
        }
        let settings = self.settings.get();
        if !settings.auto_update {
            return Outcome::AutoOff;
        }
        let attempt = self.state.lock().last_attempt;
        if !upd::due(now, settings.update_last_check, attempt) {
            return Outcome::NotDue;
        }
        self.check_now()
    }

    /// Jetzt suchen und eine neuere Version laden (blockiert, bis Suche und Download fertig sind).
    pub fn check_now(&self) -> Outcome {
        let Some(feed) = self.feed.clone() else { return Outcome::Off };
        let Some(_one) = self.running.try_lock() else { return Outcome::Busy };
        let started = now();
        self.set_busy(Some(Busy::Checking));
        let result = tauri::async_runtime::block_on(self.fetch(&feed));
        let outcome = {
            let mut st = self.state.lock();
            st.busy = None;
            st.last_attempt = Some(started);
            match result {
                Ok(ready) => {
                    st.error = None;
                    let outcome = match ready {
                        Some(ready) => {
                            let version = ready.update.version.clone();
                            st.ready = Some(ready);
                            Outcome::Ready(version)
                        }
                        None => match &st.ready {
                            // Neueste Version liegt schon bereit.
                            Some(r) => Outcome::Ready(r.update.version.clone()),
                            None => Outcome::Current,
                        },
                    };
                    st.result = Some(if matches!(outcome, Outcome::Current) { "current" } else { "ready" });
                    outcome
                }
                Err(err) => {
                    st.result = Some("error");
                    st.error = Some(reason(&err).into());
                    if signature_error(&err) {
                        log::warn!("Aktualisierung abgelehnt (Signatur): {err}");
                    }
                    Outcome::Failed(err.to_string())
                }
            }
        };
        if !matches!(outcome, Outcome::Failed(_)) {
            self.settings.update(|s| s.update_last_check = Some(started));
        }
        self.changed();
        outcome
    }

    fn updater(&self, feed: &Feed) -> tauri_plugin_updater::Result<Updater> {
        let k = try_knips().ok_or_else(|| tauri_plugin_updater::Error::Io(std::io::Error::other("Knips läuft noch nicht")))?;
        let app = k.app.clone();
        let exiting = self.exiting.clone();
        let mut builder = k
            .app
            .updater_builder()
            .timeout(Duration::from_secs(upd::CHECK_TIMEOUT_SECS))
            // Wie im Plugin aufräumen (Taskleisten-Symbol), und merken, dass es passiert ist.
            .on_before_exit(move || {
                exiting.store(true, Ordering::SeqCst);
                app.cleanup_before_exit();
            });
        if let Feed::Test(url) = feed {
            builder = builder.endpoints(vec![url.parse()?])?;
        }
        #[cfg(feature = "dev")]
        if let Some(key) = self.test.lock().pubkey.clone() {
            builder = builder.pubkey(key);
        }
        builder.build()
    }

    /// Suchen; ist eine neuere Version da, die noch nicht bereitliegt: laden und prüfen (Signatur über die Datei,
    /// gebundene Versionsnummer). `None`: nichts Neues.
    async fn fetch(&self, feed: &Feed) -> tauri_plugin_updater::Result<Option<Ready>> {
        let updater = self.updater(feed)?;
        let Some(mut update) = updater.check().await? else { return Ok(None) };
        let ready = self.state.lock().ready.as_ref().map(|r| r.update.version.clone());
        if ready.as_deref() == Some(update.version.as_str()) {
            return Ok(None);
        }
        self.set_busy(Some(Busy::Downloading));
        log::info!("Aktualisierung: lade {} von {}", update.version, update.download_url);
        update.timeout = Some(Duration::from_secs(upd::DOWNLOAD_TIMEOUT_SECS));
        let bytes = update.download(|_, _| {}, || {}).await?;
        log::info!("Aktualisierung: {} geladen und geprüft ({} Bytes)", update.version, bytes.len());
        self.save_cache(&update, &bytes);
        Ok(Some(Ready { update, bytes: Arc::new(bytes) }))
    }

    /// Geladenes Update auf die Platte legen, damit es einen Neustart von Windows übersteht (ohne Erfolgsgarantie).
    fn save_cache(&self, update: &Update, bytes: &[u8]) {
        let dir = cache_dir();
        let _ = std::fs::remove_dir_all(&dir);
        let result = std::fs::create_dir_all(&dir)
            .and_then(|_| std::fs::write(dir.join(CACHE_SETUP), bytes))
            .and_then(|_| std::fs::write(dir.join(CACHE_FEED), serde_json::to_vec(&update.raw_json).unwrap_or_default()));
        if let Err(err) = result {
            log::warn!("Aktualisierung: Zwischenspeicher nicht geschrieben: {err}");
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// Beim Start: Liegt ein früher geladenes Update bereit, das neuer ist als diese Version, und ist seine Signatur
    /// gültig, steht es sofort wieder bereit. Sonst (installiert, älter, verändert) weg damit.
    pub(crate) fn restore_cached(&self) {
        let dir = cache_dir();
        if !dir.exists() {
            return;
        }
        let restored = (|| {
            let feed = self.feed.as_ref()?;
            let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join(CACHE_FEED)).ok()?).ok()?;
            let current = try_knips()?.app.package_info().version.to_string();
            if !upd::is_newer(raw["version"].as_str()?, &current) {
                return None;
            }
            let bytes = std::fs::read(dir.join(CACHE_SETUP)).ok()?;
            // Der Feed im Zwischenspeicher ist nicht signiert: `restore_update` verlangt deshalb immer, dass die
            // Signatur genau diese Version nennt; `verify` prüft die Datei.
            let update = self.updater(feed).ok()?.restore_update(raw).ok()??;
            match update.verify(&bytes) {
                Ok(()) => Some(Ready { update, bytes: Arc::new(bytes) }),
                Err(err) => {
                    log::warn!("Aktualisierung: Zwischenspeicher verworfen: {err}");
                    None
                }
            }
        })();
        match restored {
            Some(ready) => {
                log::info!("Aktualisierung: {} aus dem Zwischenspeicher bereit", ready.update.version);
                let mut st = self.state.lock();
                st.ready = Some(ready);
                st.result = Some("ready");
                drop(st);
                self.changed();
            }
            None => {
                let _ = std::fs::remove_dir_all(&dir);
            }
        }
    }

    /// Was gerade gegen das Installieren spricht. Beim Beenden zählen offene Editoren nicht (die schließt das
    /// Beenden ohnehin), beim Neustart per Knopf schon.
    pub fn blocker(&self, restart: bool) -> Option<Blocker> {
        #[cfg(feature = "dev")]
        if let Some(blocker) = self.test.lock().blocker {
            return Some(blocker);
        }
        let k = try_knips()?;
        if k.recording.is_busy() {
            return Some(Blocker::Recording);
        }
        if k.scroll.is_active() {
            return Some(Blocker::Scroll);
        }
        if k.store.writing() || k.video.busy() {
            return Some(Blocker::Writing);
        }
        let editors = k.app.webview_windows().keys().any(|l| l.starts_with("editor-") || l.starts_with("video-"));
        if restart && editors {
            return Some(Blocker::Editors);
        }
        None
    }

    /// Geladenes Update installieren: Installer passiv starten, Knips beendet sich (`restart`: der Installer startet
    /// Knips danach wieder). Kommt nur mit einem Grund zurück, warum es gerade nicht geht.
    pub fn install(&self, restart: bool) -> Result<(), String> {
        if !knips_platform::IS_REAL {
            return Err("Aktualisieren geht nur unter Windows.".into());
        }
        if let Some(blocker) = self.blocker(restart) {
            return Err(blocker.text().into());
        }
        let ready = self.state.lock().ready.as_ref().map(|r| (r.update.clone(), r.bytes.clone()));
        let Some((update, bytes)) = ready else { return Err("Es ist kein Update geladen.".into()) };
        let Some(_one) = self.running.try_lock() else { return Err("Knips sucht gerade nach Updates.".into()) };
        self.set_busy(Some(Busy::Installing));
        if let Some(k) = try_knips() {
            k.settings.persist();
        }
        log::info!("Aktualisierung: installiere {} ({})", update.version, if restart { "danach Neustart" } else { "beim Beenden" });
        // Unter Windows kehrt `install` nur zurück, wenn der Installer nicht startet — sonst beendet sich Knips hier.
        let err = match update.restart_after_install(restart).install(&*bytes) {
            Ok(()) => "Installer beendet, ohne dass Knips sich beendet hat".to_string(),
            Err(err) => err.to_string(),
        };
        log::error!("Aktualisierung: Installer nicht gestartet: {err}");
        if self.exiting.load(Ordering::SeqCst) {
            // Schon aufgeräumt (Taskleisten-Symbol weg): Knips neu starten bzw. beenden statt halb weiterzulaufen.
            if let Some(k) = try_knips() {
                if restart {
                    k.app.restart();
                } else {
                    k.app.exit(0);
                }
            }
        }
        {
            let mut st = self.state.lock();
            st.busy = None;
            st.error = Some("Der Installer ließ sich nicht starten.".into());
        }
        self.changed();
        Err("Der Installer ließ sich nicht starten.".into())
    }
}

/// Menü → „Beenden“. Liegt ein geprüftes Update bereit, installiert Knips es jetzt (ohne Neustart) — außer während
/// einer Aufnahme oder eines Scroll-Screenshots; auf offene Schreibvorgänge wartet es höchstens 10 s. Sonst wie bisher.
pub fn quit(app: &AppHandle) {
    crate::menu::close(app);
    let app = app.clone();
    std::thread::spawn(move || {
        if let Some(k) = try_knips() {
            if k.updates.is_ready() {
                let deadline = Instant::now() + Duration::from_secs(10);
                while k.updates.blocker(false) == Some(Blocker::Writing) && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(100));
                }
                if let Err(why) = k.updates.install(false) {
                    log::info!("Aktualisierung beim Beenden ausgelassen: {why}");
                }
            }
        }
        app.exit(0);
    });
}

/// Testkanal über `http://127.0.0.1` (lokaler Server der CI): Das Plugin ließe die Adresse sonst nicht zu. Nur in
/// Entwickler-Builds und nur für `http://` auf diesen Rechner — die Weitergabe-Konfiguration kennt nur HTTPS.
#[cfg(feature = "dev")]
pub fn allow_test_feed<R: tauri::Runtime>(context: &mut tauri::Context<R>) {
    let Ok(url) = std::env::var("KNIPS_UPDATE_FEED") else { return };
    if !upd::test_feed_insecure(url.trim()) {
        return;
    }
    if let Some(config) = context.config_mut().plugins.0.get_mut("updater").and_then(|v| v.as_object_mut()) {
        config.insert("dangerousInsecureTransportProtocol".into(), true.into());
    }
}

/// Test-Befehle `knips://debug-update-check|debug-update-install|debug-quit` — nur Entwickler-Builds mit Testkanal
/// (Ende-zu-Ende-Test in der CI: die installierte App wie ein Nutzer bedienen).
#[cfg(feature = "dev")]
pub fn handle_test_command(app: &AppHandle, command: &str) -> bool {
    let Some(k) = try_knips() else { return false };
    if !k.updates.test_channel() {
        return false;
    }
    match command {
        "debug-update-check" => k.updates.request_check(),
        "debug-update-install" => {
            std::thread::spawn(|| {
                if let Some(k) = try_knips() {
                    if let Err(why) = k.updates.install(true) {
                        log::warn!("Aktualisierung nicht installiert: {why}");
                    }
                }
            });
        }
        "debug-quit" => quit(app),
        _ => return false,
    }
    true
}
