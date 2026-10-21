//! Globale Kürzel (Hotkeys.swift) und die einmalige Frage, ob Knips die Druck-Taste übernehmen darf
//! (`ShortcutTakeover` in AppDelegate.swift).

use knips_core::settings::{HotkeyAction, KeyCombo, VK_SNAPSHOT};
use knips_platform::hotkeys::{self, RecordResult};
use serde::Serialize;
use tauri::AppHandle;

use crate::app::knips;

fn id_of(action: HotkeyAction) -> u32 {
    HotkeyAction::ALL.iter().position(|a| *a == action).map(|i| i as u32 + 1).unwrap_or(0)
}

fn action_of(id: u32) -> Option<HotkeyAction> {
    HotkeyAction::ALL.get(id.checked_sub(1)? as usize).copied()
}

/// Selbsttest: ausgelöste Kürzel nur mitschreiben statt aufnehmen.
#[cfg(feature = "dev")]
type TestFire = std::sync::Arc<dyn Fn(HotkeyAction) + Send + Sync>;
#[cfg(feature = "dev")]
static TEST_FIRE: parking_lot::RwLock<Option<TestFire>> = parking_lot::RwLock::new(None);

/// Selbsttest: Ausführen ersetzen (`None` = wieder echt).
#[cfg(feature = "dev")]
pub fn set_test_fire(f: Option<TestFire>) {
    *TEST_FIRE.write() = f;
}

pub fn start() {
    hotkeys::start(Box::new(|id| {
        if let Some(action) = action_of(id) {
            #[cfg(feature = "dev")]
            if let Some(f) = TEST_FIRE.read().clone() {
                f(action);
                return;
            }
            knips().coordinator.perform(action);
        }
    }));
}

/// Aktive Kürzel registrieren; was nicht klappt, steht danach in `hotkey_failures`.
pub fn apply() {
    let k = knips();
    let bindings: Vec<(u32, KeyCombo)> = k.settings.get().active_hotkeys().into_iter().map(|(a, c)| (id_of(a), c)).collect();
    let failed = hotkeys::apply(&bindings);
    let actions: Vec<HotkeyAction> = failed.into_iter().filter_map(action_of).collect();
    if !actions.is_empty() {
        log::warn!("Kürzel nicht registriert: {actions:?}");
    }
    *k.hotkey_failures.lock() = actions;
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Recorded {
    action: HotkeyAction,
    /// „combo“, „remove“, „cancel“ oder „rejected“ (Kombination tippt ein Zeichen, siehe `message`).
    result: &'static str,
    combo: Option<KeyCombo>,
    message: Option<String>,
}

/// Anzeige eines Kürzels mit den Tastennamen des aktuellen Layouts.
pub fn label(combo: &KeyCombo) -> String {
    combo.display_with(hotkeys::key_name)
}

/// Warum `combo` nicht als Kürzel taugt: Strg+Alt ist unter Windows dasselbe wie AltGr. Ergibt die
/// Kombination auf einem installierten Layout ein Zeichen (deutsch: Strg+Alt+Q = „@“), ließe es sich nicht
/// mehr tippen, solange Knips läuft.
pub fn altgr_conflict(combo: &KeyCombo) -> Option<String> {
    let ch = hotkeys::altgr_char(*combo)?;
    let alt_gr = combo.display_with(hotkeys::key_name).replacen("Strg+Alt+", "AltGr+", 1);
    Some(format!(
        "{} geht nicht: Unter Windows ist Strg+Alt dasselbe wie AltGr, und {alt_gr} tippt „{ch}“. Als Kürzel ließe sich „{ch}“ nicht mehr eingeben – bitte eine andere Kombination wählen.",
        label(combo)
    ))
}

/// Nächste Tastenkombination für `action` aufnehmen (Einstellungen).
pub fn record(action: HotkeyAction) {
    hotkeys::record(Box::new(move |result| {
        let k = knips();
        let (kind, combo, message) = match result {
            RecordResult::Combo(c) => match altgr_conflict(&c) {
                Some(message) => ("rejected", Some(c), Some(message)),
                None => ("combo", Some(c), None),
            },
            RecordResult::Remove => ("remove", None, None),
            RecordResult::Cancel => ("cancel", None, None),
        };
        match (kind, combo) {
            ("combo", Some(combo)) => {
                k.settings.update(|s| {
                    // Eine Kombination gehört nur einer Aktion.
                    s.hotkeys.retain(|a, c| *a == action || *c != combo);
                    s.hotkeys.insert(action, combo);
                    s.disabled_hotkeys.remove(&action);
                });
            }
            ("remove", _) => {
                k.settings.update(|s| {
                    s.hotkeys.remove(&action);
                });
            }
            ("rejected", _) => log::info!("Kürzel abgelehnt: {}", message.as_deref().unwrap_or_default()),
            _ => {}
        }
        apply();
        k.emit("hotkey-recorded", Recorded { action, result: kind, combo, message });
        k.broadcast_bootstrap();
    }));
}

pub fn uses_print_screen() -> bool {
    knips().settings.get().active_hotkeys().values().any(|c| c.vk == VK_SNAPSHOT)
}

/// Druck-Taste von Windows (Bildschirmausschnitt) übernehmen.
pub fn take_over() -> bool {
    let k = knips();
    match hotkeys::set_snipping_key(false) {
        Ok(()) => {
            k.settings.update(|s| s.took_snipping_key = true);
            apply();
            k.broadcast_bootstrap();
            true
        }
        Err(err) => {
            log::error!("Druck-Taste übernehmen fehlgeschlagen: {err:#}");
            false
        }
    }
}

pub fn restore() {
    let k = knips();
    if let Err(err) = hotkeys::set_snipping_key(true) {
        log::error!("Druck-Taste zurückgeben fehlgeschlagen: {err:#}");
    }
    k.settings.update(|s| s.took_snipping_key = false);
    apply();
    k.broadcast_bootstrap();
}

/// Bietet einmalig an, die Druck-Taste für Knips freizumachen (wie ⇧⌘3/4/5 auf dem Mac).
pub fn offer_takeover(app: &AppHandle) {
    let k = knips();
    // Test-Sandbox: keine Rückfrage, die Systemeinstellung bleibt unangetastet.
    if crate::paths::test_root().is_some() {
        return;
    }
    if k.settings.get().asked_shortcut_takeover || !hotkeys::snipping_key_enabled() || !uses_print_screen() {
        return;
    }
    k.settings.update(|s| s.asked_shortcut_takeover = true);
    use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
    let accepted = app
        .dialog()
        .message("Windows öffnet mit der Druck-Taste den Bildschirmausschnitt. Knips schaltet das ab – in den Knips-Einstellungen unter „Tastaturkürzel“ jederzeit wiederherstellbar.")
        .title("Druck-Taste für Knips übernehmen?")
        .buttons(MessageDialogButtons::OkCancelCustom("Übernehmen".into(), "Nicht jetzt".into()))
        .blocking_show();
    if accepted && take_over() {
        k.hud.show("Kürzel übernommen", "check");
    }
}
