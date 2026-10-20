//! Zentraler Zustand und Start (`AppDelegate.swift`). Alle Teile erreichen die App über `knips()`.

use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, OnceLock};

use knips_core::settings::{HotkeyAction, Settings};
use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use crate::cards::Cards;
use crate::coordinator::Coordinator;
use crate::editor::Editors;
use crate::hud::Hud;
use crate::links::Links;
use crate::pins::Pins;
use crate::recording::Recording;
use crate::scroll::Scroll;
use crate::settings::SettingsStore;
use crate::store::Store;
use crate::telemetry::Telemetry;
use crate::video::VideoJobs;
use crate::{hotkeys, paths, tray, wm};

pub struct Knips {
    pub app: AppHandle,
    pub settings: Arc<SettingsStore>,
    pub store: Arc<Store>,
    pub cards: Cards,
    pub coordinator: Coordinator,
    pub recording: Recording,
    pub scroll: Scroll,
    pub pins: Pins,
    pub hud: Hud,
    pub editors: Editors,
    pub video: VideoJobs,
    pub telemetry: Arc<Telemetry>,
    /// knips://-Befehle mit Rückfrage vor sofortigen Aufnahmen.
    pub links: Links,
    /// Kürzel, die nicht registriert werden konnten.
    pub hotkey_failures: Mutex<Vec<HotkeyAction>>,
    ocr_available: OnceLock<bool>,
    hevc_available: OnceLock<bool>,
}

static KNIPS: OnceLock<Arc<Knips>> = OnceLock::new();

pub fn knips() -> &'static Arc<Knips> {
    KNIPS.get().expect("Knips nicht gestartet")
}

/// Wie `knips()`, aber ohne Absturz, solange die App nicht gestartet ist (Selbsttests ohne Fenster).
pub fn try_knips() -> Option<&'static Arc<Knips>> {
    KNIPS.get()
}

/// Alles, was ein Fenster beim Start braucht (siehe `Bootstrap` in src/shared/types.ts).
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub settings: Settings,
    pub hotkey_labels: BTreeMap<HotkeyAction, String>,
    pub hotkey_failures: Vec<HotkeyAction>,
    pub snipping_key_enabled: bool,
    pub paths: BootPaths,
    pub platform: &'static str,
    pub version: String,
    pub ocr_available: bool,
    pub hevc_available: bool,
    /// Nutzungsstatistik: `null` = noch nicht beantwortet.
    pub telemetry_consent: Option<bool>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct BootPaths {
    pub items_dir: String,
    pub save_folder: String,
    pub default_save_folder: String,
}

impl Knips {
    pub fn bootstrap(&self) -> Bootstrap {
        let settings = self.settings.get();
        let hotkey_labels = settings.hotkeys.iter().map(|(a, c)| (*a, c.display())).collect();
        Bootstrap {
            hotkey_labels,
            hotkey_failures: self.hotkey_failures.lock().clone(),
            snipping_key_enabled: knips_platform::hotkeys::snipping_key_enabled(),
            paths: BootPaths {
                items_dir: paths::items_dir().to_string_lossy().into_owned(),
                save_folder: self.settings.save_folder().to_string_lossy().into_owned(),
                default_save_folder: paths::default_save_folder().to_string_lossy().into_owned(),
            },
            platform: if knips_platform::IS_REAL { "windows" } else { "mock" },
            version: self.app.package_info().version.to_string(),
            ocr_available: self.ocr_available.get().copied().unwrap_or(false),
            hevc_available: self.hevc_available.get().copied().unwrap_or(false),
            telemetry_consent: self.telemetry.consent(),
            settings,
        }
    }

    /// Nach jeder Änderung an Einstellungen, Kürzeln oder Pfaden: alle Fenster informieren.
    pub fn broadcast_bootstrap(&self) {
        let _ = self.app.emit("bootstrap-changed", self.bootstrap());
    }

    pub fn emit<S: Serialize + Clone>(&self, event: &str, payload: S) {
        if let Err(err) = self.app.emit(event, payload) {
            log::warn!("Ereignis {event} nicht gesendet: {err}");
        }
    }

    /// Ordner, die Fenster über das Asset-Protokoll lesen dürfen (Vorschaubilder, Ablage, Pins, Videos).
    pub fn allow_asset_dirs(&self) {
        let scope = self.app.asset_protocol_scope();
        for dir in [paths::items_dir(), self.settings.save_folder(), paths::temp_dir()] {
            paths::ensure(&dir);
            if let Err(err) = scope.allow_directory(&dir, true) {
                log::warn!("Asset-Freigabe {} fehlgeschlagen: {err}", dir.display());
            }
        }
    }

    pub fn shutter(&self) {
        if self.settings.get().play_sound {
            knips_platform::sound::play_shutter();
        }
    }

    /// Fehlermeldung als Dialog (wie `Alerts.error`).
    pub fn alert(&self, title: &str, message: &str) {
        log::error!("{title}: {message}");
        use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
        self.app.dialog().message(message).title(title).kind(MessageDialogKind::Warning).show(|_| {});
    }
}

/// Start der App: Zustand anlegen, Fenster vorwärmen, Kürzel, Tray.
pub fn setup(app: &AppHandle) -> anyhow::Result<()> {
    if paths::test_root().is_some() {
        knips_platform::clipboard::set_disabled(true);
    }
    // Vor dem Laden: Daten älterer Versionen aus dem Installationsordner holen, Zwischendateien
    // (unzensierte Video-Einzelbilder, Reste abgestürzter Aufnahmen/Exporte, Pins) entfernen —
    // es läuft noch nichts, das sie braucht (zweite Instanzen beendet das Single-Instance-Plugin vorher).
    paths::migrate_legacy();
    let removed = paths::clean_temp(None, &|_| false);
    if removed > 0 {
        log::info!("{removed} Zwischendateien entfernt");
    }
    let settings = Arc::new(SettingsStore::load());
    let store = Arc::new(Store::new(settings.clone()));
    let telemetry = Arc::new(Telemetry::from_env(settings.clone(), &app.package_info().version.to_string()));
    let state = Arc::new(Knips {
        app: app.clone(),
        settings: settings.clone(),
        store: store.clone(),
        cards: Cards::default(),
        coordinator: Coordinator::default(),
        recording: Recording::default(),
        scroll: Scroll::default(),
        pins: Pins::default(),
        hud: Hud::default(),
        editors: Editors::default(),
        video: VideoJobs::default(),
        telemetry: telemetry.clone(),
        links: Links::default(),
        hotkey_failures: Mutex::new(vec![]),
        ocr_available: OnceLock::new(),
        hevc_available: OnceLock::new(),
    });
    let _ = KNIPS.set(state.clone());

    store.set_on_change(|items| {
        let k = knips();
        k.emit("items-changed", items.clone());
        k.cards.sync(&items);
    });
    store.set_on_error(|title, message| knips().alert(title, &message));
    start_housekeeping();
    state.allow_asset_dirs();
    // Fähigkeiten des Systems im Hintergrund prüfen (WinRT/Media Foundation nie im UI-Thread).
    std::thread::spawn(|| {
        let k = knips();
        let _ = k.ocr_available.set(knips_platform::ocr::available());
        let _ = k.hevc_available.set(knips_platform::media::hevc_encoder_available());
        k.broadcast_bootstrap();
    });

    // Häufig gebrauchte Fenster unsichtbar vorwärmen — das erste Öffnen kostet sonst spürbar.
    for spec in [crate::cards::spec(), crate::hud::spec(), crate::menu::spec()] {
        if let Err(err) = wm::ensure(app, &spec) {
            log::error!("Fenster {} nicht angelegt: {err:#}", spec.label);
        }
    }
    crate::menu::install(app);
    crate::cards::start_click_through();
    tray::install(app)?;

    hotkeys::start();
    hotkeys::apply();
    // Bis 1.0.0 übernahm Knips die Druck-Taste ohne Vermerk fürs Deinstallieren: einmal nachholen.
    // Der Wert davor ist unbekannt — zurückgeben und neu übernehmen vermerkt „an“ (wie Windows 11
    // ohne Eintrag), damit das Deinstallieren die Taste wieder an Windows gibt.
    {
        use knips_platform::hotkeys as hk;
        if knips_platform::IS_REAL && paths::test_root().is_none() && settings.get().took_snipping_key && hk::snipping_takeover_marker().is_none() && !hk::snipping_key_enabled() {
            if let Err(err) = hk::set_snipping_key(true).and_then(|_| hk::set_snipping_key(false)) {
                log::warn!("Vermerk der Druck-Tasten-Übernahme nicht nachgeholt: {err:#}");
            }
        }
    }

    // Erster Start einer installierten App: mit Windows starten.
    let s = settings.get();
    if !s.did_first_launch {
        let installed = std::env::current_exe().map(|p| !p.to_string_lossy().contains("\\target\\")).unwrap_or(false);
        settings.update(|s| {
            s.did_first_launch = true;
            s.launch_at_login = installed && knips_platform::IS_REAL;
        });
    }
    crate::commands::sync_autostart(app);

    // Wie macOS-Kürzel-Übernahme: einmal nachfragen, ob Knips die Druck-Taste bekommen darf.
    // Danach (nie gleichzeitig) die Frage zur Nutzungsstatistik.
    let app2 = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(800));
        hotkeys::offer_takeover(&app2);
        crate::telemetry::maybe_ask(&app2);
    });
    telemetry.count("app_launch");
    telemetry.start();
    log::info!("Knips gestartet ({})", if knips_platform::IS_REAL { "Windows" } else { "Attrappe" });
    Ok(())
}

/// Aufnahmen, die gerade in einem Editor oder Video-Editor offen sind.
pub fn open_item_ids() -> HashSet<knips_core::model::Id> {
    knips()
        .app
        .webview_windows()
        .keys()
        .filter_map(|label| label.strip_prefix("editor-").or_else(|| label.strip_prefix("video-")))
        .filter_map(|id| id.parse().ok())
        .collect()
}

/// Alle 6 Stunden aufräumen, nicht nur beim Start (Knips läuft oft wochenlang durch): abgelaufene
/// Originale (Frist aus den Einstellungen) und Zwischendateien, die seit einem Tag niemand braucht.
fn start_housekeeping() {
    const EVERY: std::time::Duration = std::time::Duration::from_secs(6 * 3600);
    let spawned = std::thread::Builder::new().name("knips-housekeeping".into()).spawn(|| loop {
        std::thread::sleep(EVERY);
        housekeeping();
    });
    if let Err(err) = spawned {
        log::error!("Aufräumen nicht gestartet: {err}");
    }
}

/// Ein Durchgang des regelmäßigen Aufräumens (auch für den Selbsttest).
pub fn housekeeping() -> (usize, usize) {
    let k = knips();
    let open = open_item_ids();
    let expired = k.store.expire(&open);
    let pins = k.pins.paths();
    let open_prefixes: Vec<String> = open.iter().map(|id| format!("{id}-")).collect();
    let keep = |path: &std::path::Path| {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        pins.iter().any(|p| p == path) || open_prefixes.iter().any(|p| name.starts_with(p.as_str()))
    };
    let removed = paths::clean_temp(Some(std::time::Duration::from_secs(24 * 3600)), &keep);
    if expired + removed > 0 {
        log::info!("Aufgeräumt: {expired} abgelaufene Aufnahmen, {removed} Zwischendateien");
    }
    (expired, removed)
}

/// URL-Befehle `knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` — immer
/// von außen (Deep Link, zweiter Start, Startargument). Sofort aufnehmende Befehle fragen vorher nach
/// (`links.rs`).
pub fn handle_url(url: &str) {
    let k = knips();
    if k.links.run(url, true) {
        return;
    }
    #[cfg(feature = "dev")]
    {
        let command = url.trim_start_matches("knips://").trim_matches('/').split(['/', '?']).next().unwrap_or("");
        if crate::selftest::handle_debug_command(command) {
            return;
        }
    }
    log::info!("Unbekannter Befehl: {url}");
}

/// Fenster eines Editors/Videos usw. ist zu → Zustand aufräumen.
pub fn on_window_destroyed(label: &str) {
    let k = knips();
    if let Some(n) = label.strip_prefix("pin-").and_then(|n| n.parse::<u32>().ok()) {
        k.pins.remove(n);
    }
    if let Some(id) = label.strip_prefix("editor-").and_then(|s| s.parse().ok()) {
        k.editors.close(id);
    }
    if let Some(id) = label.strip_prefix("video-") {
        k.video.cancel(id);
    }
    if label.starts_with(crate::links::LABEL_PREFIX) {
        k.links.window_destroyed(label);
    }
}

#[allow(dead_code)]
pub fn main_window_count(app: &AppHandle) -> usize {
    app.webview_windows().len()
}
