//! Symbol im Infobereich der Taskleiste (`StatusBarController` in StatusBar.swift). Klick öffnet das
//! Knips-Panel; während einer Aufnahme stoppt ein Linksklick sofort.
//!
//! Das Symbol ist das Zeichen von Knips (`tray_glyph.rs`): hell auf dunkler, dunkel auf heller Taskleiste, in der
//! Größe des Infobereichs (16 px bei 100 %, 32 px bei 200 %); während eines Videos mit rotem Punkt.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tauri::image::Image;
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

use crate::app::knips;
use crate::recording::RecordingState;

/// Bild des Symbols (reine Rechnung, eigene Datei für die Tests).
#[path = "tray_glyph.rs"]
mod tray_glyph;

const ID: &str = "knips";

/// Läuft gerade ein Video? (Punkt statt Balken.)
static RECORDING: AtomicBool = AtomicBool::new(false);
/// Zuletzt gesetztes Symbol: (Größe, helle Taskleiste, Aufnahme) — nur bei Änderung neu setzen.
static SHOWN: Mutex<Option<(u32, bool, bool)>> = Mutex::new(None);

/// Gewünschtes Symbol: Größe nach der Skalierung des Hauptbildschirms (dort liegt der Infobereich),
/// Farbe nach der Taskleiste.
fn wanted() -> (u32, bool, bool) {
    let scale = knips_platform::monitors::primary().scale;
    let size = ((16.0 * scale).round() as u32).clamp(16, 64);
    (size, knips_platform::shell::taskbar_light(), RECORDING.load(Ordering::Relaxed))
}

fn image((size, light, recording): (u32, bool, bool)) -> Image<'static> {
    Image::new_owned(tray_glyph::render(size, light, recording), size, size)
}

/// Symbol setzen, wenn sich Größe, Taskleistenfarbe oder Aufnahme-Zustand geändert haben.
fn update_icon(app: &AppHandle) {
    let Some(tray) = tray(app) else { return };
    let key = wanted();
    let mut shown = SHOWN.lock().unwrap_or_else(|e| e.into_inner());
    if *shown == Some(key) {
        return;
    }
    if tray.set_icon(Some(image(key))).is_ok() {
        *shown = Some(key);
    }
}

pub fn install(app: &AppHandle) -> anyhow::Result<()> {
    let key = wanted();
    TrayIconBuilder::with_id(ID)
        .icon(image(key))
        .tooltip("Knips")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button, button_state: MouseButtonState::Up, position, .. } = event {
                let app = tray.app_handle();
                let k = knips();
                if button == MouseButton::Left && k.recording.is_recording() {
                    k.recording.stop(true);
                    return;
                }
                crate::menu::toggle(app, Some((position.x as i32, position.y as i32)));
            }
        })
        .build(app)?;
    *SHOWN.lock().unwrap_or_else(|e| e.into_inner()) = Some(key);
    // Hell/Dunkel der Taskleiste und die Skalierung können sich jederzeit ändern; ein Blick alle 3 s genügt
    // (ein Registry-Wert, eine Monitor-Abfrage).
    let handle = app.clone();
    let watcher = std::thread::Builder::new().name("knips-tray".into()).spawn(move || loop {
        std::thread::sleep(Duration::from_secs(3));
        update_icon(&handle);
    });
    if let Err(err) = watcher {
        log::warn!("Taskleisten-Symbol folgt Hell/Dunkel nicht: {err}");
    }
    Ok(())
}

fn tray(app: &AppHandle) -> Option<TrayIcon> {
    app.tray_by_id(ID)
}

/// Roter Punkt während der Aufnahme, Zeit im Tooltip (Windows zeigt keinen Text neben dem Symbol).
pub fn refresh_recording(state: &RecordingState) {
    let app = &knips().app;
    let Some(tray) = tray(app) else { return };
    RECORDING.store(state.phase == "recording", Ordering::Relaxed);
    update_icon(app);
    match state.phase {
        "recording" => {
            let _ = tray.set_tooltip(Some(format!("Knips – Aufnahme {} (Klick: stoppen)", knips_core::format::duration(state.elapsed))));
        }
        "countdown" => {
            let _ = tray.set_tooltip(Some(format!("Knips – Aufnahme in {}", state.countdown)));
        }
        _ => {
            let _ = tray.set_tooltip(Some("Knips"));
        }
    }
}
