//! Symbol im Infobereich der Taskleiste (`StatusBarController` in StatusBar.swift). Klick öffnet das
//! Knips-Panel; während einer Aufnahme stoppt ein Linksklick sofort.

use tauri::image::Image;
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

use crate::app::knips;
use crate::recording::RecordingState;

const ID: &str = "knips";

pub fn install(app: &AppHandle) -> anyhow::Result<()> {
    let icon = app.default_window_icon().cloned().ok_or_else(|| anyhow::anyhow!("kein App-Symbol"))?;
    TrayIconBuilder::with_id(ID)
        .icon(icon)
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
    Ok(())
}

fn tray(app: &AppHandle) -> Option<TrayIcon> {
    app.tray_by_id(ID)
}

/// Roter Punkt während der Aufnahme, Zeit im Tooltip (Windows zeigt keinen Text neben dem Symbol).
pub fn refresh_recording(state: &RecordingState) {
    let app = &knips().app;
    let Some(tray) = tray(app) else { return };
    match state.phase {
        "recording" => {
            let _ = tray.set_icon(Some(record_icon()));
            let _ = tray.set_tooltip(Some(format!("Knips – Aufnahme {} (Klick: stoppen)", knips_core::format::duration(state.elapsed))));
        }
        "countdown" => {
            let _ = tray.set_tooltip(Some(format!("Knips – Aufnahme in {}", state.countdown)));
        }
        _ => {
            if let Some(icon) = app.default_window_icon().cloned() {
                let _ = tray.set_icon(Some(icon));
            }
            let _ = tray.set_tooltip(Some("Knips"));
        }
    }
}

/// Stopp-Symbol: roter Kreis mit weißem Quadrat (wie `stop.circle.fill`).
fn record_icon() -> Image<'static> {
    let n = 32u32;
    let mut rgba = vec![0u8; (n * n * 4) as usize];
    let c = (n as f32 - 1.0) / 2.0;
    for y in 0..n {
        for x in 0..n {
            let d = ((x as f32 - c).powi(2) + (y as f32 - c).powi(2)).sqrt();
            let alpha = (c + 0.5 - d).clamp(0.0, 1.0);
            let inside_square = (x as f32 - c).abs() < 5.5 && (y as f32 - c).abs() < 5.5;
            let i = ((y * n + x) * 4) as usize;
            let (r, g, b) = if inside_square { (255, 255, 255) } else { (255, 59, 48) };
            rgba[i..i + 4].copy_from_slice(&[r, g, b, (alpha * 255.0) as u8]);
        }
    }
    Image::new_owned(rgba, n, n)
}
