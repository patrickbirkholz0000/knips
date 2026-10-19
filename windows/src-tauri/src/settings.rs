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

    /// Teiländerung aus der Oberfläche (JSON-Objekt mit beliebigen Feldern von `Settings`).
    /// Felder der Nutzungsstatistik lassen sich so nicht ändern (nur über `telemetry_set_consent`).
    pub fn patch(&self, patch: &Value) -> Result<Settings> {
        let current = serde_json::to_value(self.get())?;
        let mut merged = current;
        if let (Some(target), Some(source)) = (merged.as_object_mut(), patch.as_object()) {
            for (k, v) in source.iter().filter(|(k, _)| !k.starts_with("telemetry")) {
                target.insert(k.clone(), v.clone());
            }
        }
        let next: Settings = serde_json::from_value(merged)?;
        Ok(self.update(|s| *s = next))
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

    /// Aufgelöster Ablageordner (leer = Standard).
    pub fn save_folder(&self) -> PathBuf {
        if paths::test_root().is_some() {
            return paths::default_save_folder();
        }
        let s = self.value.read();
        if s.save_folder.trim().is_empty() {
            paths::default_save_folder()
        } else {
            PathBuf::from(&s.save_folder)
        }
    }
}
