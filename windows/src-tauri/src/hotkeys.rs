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

pub fn start() {
    hotkeys::start(Box::new(|id| {
        if let Some(action) = action_of(id) {
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
    result: &'static str,
    combo: Option<KeyCombo>,
}

/// Nächste Tastenkombination für `action` aufnehmen (Einstellungen).
pub fn record(action: HotkeyAction) {
    hotkeys::record(Box::new(move |result| {
        let k = knips();
        let (kind, combo) = match result {
            RecordResult::Combo(c) => ("combo", Some(c)),
            RecordResult::Remove => ("remove", None),
            RecordResult::Cancel => ("cancel", None),
        };
        match kind {
            "combo" => {
                let combo = combo.expect("Kombination");
                k.settings.update(|s| {
                    // Eine Kombination gehört nur einer Aktion.
                    s.hotkeys.retain(|a, c| *a == action || *c != combo);
                    s.hotkeys.insert(action, combo);
                    s.disabled_hotkeys.remove(&action);
                });
            }
            "remove" => {
                k.settings.update(|s| {
                    s.hotkeys.remove(&action);
                });
            }
            _ => {}
        }
        apply();
        k.emit("hotkey-recorded", Recorded { action, result: kind, combo });
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
