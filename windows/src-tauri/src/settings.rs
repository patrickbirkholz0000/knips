//! Einstellungen laden, ändern, speichern (`AppSettings` in Settings.swift). Datei: `settings.json`.
//! In derselben Datei, aber getrennt von den Einstellungen der Oberfläche: der Zustand der
//! Nutzungsstatistik (Felder `telemetry…`, siehe `knips_core::telemetry::TelemetryState`).

use std::path::PathBuf;

use anyhow::Result;
use knips_core::settings::Settings;
use knips_core::telemetry::TelemetryState;
use parking_lot::{Mutex, RwLock};
use serde::Serialize;
use serde_json::Value;

use crate::paths;

pub struct SettingsStore {
    path: PathBuf,
    value: RwLock<Settings>,
    telemetry: RwLock<TelemetryState>,
    /// Hält Schreibvorgänge in Reihe (gleiche Zwischendatei).
    save_lock: Mutex<()>,
}

/// So liegt beides in `settings.json`.
#[derive(Serialize)]
struct File<'a> {
    #[serde(flatten)]
    settings: &'a Settings,
    #[serde(flatten)]
    telemetry: &'a TelemetryState,
}

impl SettingsStore {
    pub fn load() -> Self {
        let dir = paths::config_dir();
        paths::ensure(&dir);
        let path = dir.join("settings.json");
        let raw = std::fs::read(&path).ok().and_then(|data| serde_json::from_slice::<Value>(&data).ok());
        let mut value = raw.clone().and_then(|v| serde_json::from_value::<Settings>(v).ok()).unwrap_or_default();
        value.sanitize();
        let mut telemetry = raw.and_then(|v| serde_json::from_value::<TelemetryState>(v).ok()).unwrap_or_default();
        telemetry.sanitize();
        Self { path, value: RwLock::new(value), telemetry: RwLock::new(telemetry), save_lock: Mutex::new(()) }
    }

    pub fn get(&self) -> Settings {
        self.value.read().clone()
    }

    /// Ändern, bereinigen, speichern. Liefert den neuen Stand.
    pub fn update(&self, change: impl FnOnce(&mut Settings)) -> Settings {
        let mut guard = self.value.write();
        change(&mut guard);
        guard.sanitize();
        let snapshot = guard.clone();
        drop(guard);
        self.persist();
        snapshot
    }

    /// Teiländerung aus der Oberfläche: nur Felder aus `allowed` (je Fenster, siehe `commands::set_settings`),
    /// geprüft von `Settings::patched` (Typen, Auswahlwerte, Bereiche, Pfadregeln); ein neuer Ablageordner
    /// muss außerdem als Ordner existieren. Fehler ändern nichts. Kürzel, interne Merker und die
    /// Nutzungsstatistik lassen sich so nie ändern.
    pub fn patch(&self, patch: &Value, allowed: &[&str]) -> std::result::Result<Settings, String> {
        let current = self.get();
        let next = current.patched(patch, allowed)?;
        if next.save_folder != current.save_folder {
            check_folder_exists(next.save_folder.trim())?;
        }
        // Unter der Sperre noch einmal auf den neuesten Stand anwenden (Kürzel könnten sich inzwischen
        // geändert haben) — nur die Felder aus `patch` ändern sich.
        Ok(self.update(|s| {
            if let Ok(next) = s.patched(patch, allowed) {
                *s = next;
            }
        }))
    }

    pub fn telemetry(&self) -> TelemetryState {
        self.telemetry.read().clone()
    }

    /// Zustand der Nutzungsstatistik ändern; gespeichert wird nur, wenn `change` `true` liefert.
    pub fn update_telemetry(&self, change: impl FnOnce(&mut TelemetryState) -> bool) -> bool {
        let mut guard = self.telemetry.write();
        let changed = change(&mut guard);
        drop(guard);
        if changed {
            self.persist();
        }
        changed
    }

    /// Wie `update_telemetry`, aber ohne zu speichern (der Aufrufer speichert gebündelt mit `persist`).
    pub fn update_telemetry_in_memory(&self, change: impl FnOnce(&mut TelemetryState) -> bool) -> bool {
        change(&mut self.telemetry.write())
    }

    pub fn persist(&self) {
        if let Err(err) = self.save() {
            log::error!("Einstellungen speichern fehlgeschlagen: {err:#}");
        }
    }

    fn save(&self) -> Result<()> {
        let _lock = self.save_lock.lock();
        // Stand erst unter der Sperre lesen — so schreibt der letzte Aufruf immer den neuesten.
        let settings = self.value.read().clone();
        let telemetry = self.telemetry.read().clone();
        let data = serde_json::to_vec_pretty(&File { settings: &settings, telemetry: &telemetry })?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, data)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    /// Pfad von `settings.json` (Selbsttest).
    #[allow(dead_code)]
    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    /// Aufgelöster Ablageordner (leer = Standard). Ein Eintrag, der die Pfadregeln nicht erfüllt (z. B. von
    /// Hand in `settings.json` geschrieben: Netzwerk- oder Gerätepfad), gilt als leer.
    pub fn save_folder(&self) -> PathBuf {
        if paths::test_root().is_some() {
            return paths::default_save_folder();
        }
        let s = self.value.read();
        let folder = s.save_folder.trim();
        if folder.is_empty() || check_folder_rules(folder).is_err() {
            paths::default_save_folder()
        } else {
            PathBuf::from(folder)
        }
    }
}

/// Pfadregeln für den Ablageordner: unter Windows `knips_core::settings::check_save_folder` (Laufwerkspfad,
/// kein UNC-/Gerätepfad), in der Attrappe nur „absolut“.
fn check_folder_rules(folder: &str) -> std::result::Result<(), String> {
    if cfg!(windows) {
        knips_core::settings::check_save_folder(folder)
    } else if folder.is_empty() || std::path::Path::new(folder).is_absolute() {
        Ok(())
    } else {
        Err("Dieser Ordner geht nicht als Ablage: nur vollständige Pfade.".into())
    }
}

/// Neuer Ablageordner aus der Oberfläche: Pfadregeln, und es muss ihn als Ordner geben (keine Datei).
fn check_folder_exists(folder: &str) -> std::result::Result<(), String> {
    check_folder_rules(folder)?;
    if folder.is_empty() {
        return Ok(());
    }
    match std::fs::metadata(folder) {
        Ok(meta) if meta.is_dir() => Ok(()),
        Ok(_) => Err("Dieser Ordner geht nicht als Ablage: Das ist eine Datei, kein Ordner.".into()),
        Err(_) => Err("Dieser Ordner geht nicht als Ablage: Es gibt ihn nicht.".into()),
    }
}
