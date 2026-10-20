//! Zentraler Zustand und Start (`AppDelegate.swift`). Alle Teile erreichen die App über `knips()`.

use std::collections::BTreeMap;
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
    media_available: OnceLock<bool>,
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
    /// HEVC aufnehmen und wieder lesen (Encoder **und** Decoder); sonst nur H.264 anbieten.
    pub hevc_available: bool,
    /// Media Foundation vorhanden (fehlt in Windows N/KN ohne Media Feature Pack): sonst kein Video.
    pub media_available: bool,
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
            // Bis zur Prüfung (Hintergrund, Millisekunden) nichts sperren.
            media_available: self.media_available.get().copied().unwrap_or(true),
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

    /// Hinweis mit Knopf, der eine Windows-Einstellungsseite (`ms-settings:…`) öffnet, und „Schließen“.
    pub fn alert_with_settings(&self, title: &str, message: &str, button: &str, url: &'static str) {
        log::warn!("{title}: {message}");
        use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
        self.app
            .dialog()
            .message(message)
            .title(title)
            .kind(MessageDialogKind::Warning)
            .buttons(MessageDialogButtons::OkCancelCustom(button.into(), "Schließen".into()))
            .show(move |open| {
                if open {
                    if let Err(err) = knips_platform::shell::open_url(url) {
                        log::warn!("{url} nicht geöffnet: {err:#}");
                    }
                }
            });
    }
}

/// Start der App: Zustand anlegen, Fenster vorwärmen, Kürzel, Tray.
pub fn setup(app: &AppHandle) -> anyhow::Result<()> {
    if paths::test_root().is_some() {
        knips_platform::clipboard::set_disabled(true);
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
        media_available: OnceLock::new(),
    });
    let _ = KNIPS.set(state.clone());

    store.set_on_change(|items| {
        let k = knips();
        k.emit("items-changed", items.clone());
        k.cards.sync(&items);
    });
    state.allow_asset_dirs();
    // Fähigkeiten des Systems im Hintergrund prüfen (WinRT/Media Foundation nie im UI-Thread).
    std::thread::spawn(|| {
        let k = knips();
        let media = knips_platform::media::available();
        let _ = k.media_available.set(media);
        if !media {
            k.broadcast_bootstrap();
        }
        let _ = k.ocr_available.set(knips_platform::ocr::available());
        // Encoder und Decoder (kurzes Testvideo); ohne Media Foundation sofort `false`.
        let _ = k.hevc_available.set(knips_platform::media::hevc_available());
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
