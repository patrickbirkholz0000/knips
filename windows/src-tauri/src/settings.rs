//! Einstellungen laden, ändern, speichern (`AppSettings` in Settings.swift). Datei: `settings.json`.

use std::path::PathBuf;

use anyhow::Result;
use knips_core::settings::Settings;
use parking_lot::RwLock;
use serde_json::Value;

use crate::paths;

pub struct SettingsStore {
    path: PathBuf,
    value: RwLock<Settings>,
}

impl SettingsStore {
    pub fn load() -> Self {
        let dir = paths::config_dir();
        paths::ensure(&dir);
        let path = dir.join("settings.json");
        let mut value = std::fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice::<Settings>(&data).ok())
            .unwrap_or_default();
        value.sanitize();
        Self { path, value: RwLock::new(value) }
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
        if let Err(err) = self.save(&snapshot) {
            log::error!("Einstellungen speichern fehlgeschlagen: {err:#}");
        }
        snapshot
    }

    /// Teiländerung aus der Oberfläche (JSON-Objekt mit beliebigen Feldern von `Settings`).
    pub fn patch(&self, patch: &Value) -> Result<Settings> {
        let current = serde_json::to_value(self.get())?;
        let mut merged = current;
        if let (Some(target), Some(source)) = (merged.as_object_mut(), patch.as_object()) {
            for (k, v) in source {
                target.insert(k.clone(), v.clone());
            }
        }
        let next: Settings = serde_json::from_value(merged)?;
        Ok(self.update(|s| *s = next))
    }

    fn save(&self, s: &Settings) -> Result<()> {
        let data = serde_json::to_vec_pretty(s)?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, data)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
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
