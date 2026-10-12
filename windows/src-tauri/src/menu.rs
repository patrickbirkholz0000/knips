//! Menü-Panel am Tray-Symbol (`MenuPanelController` in MenuPanel.swift). Klick daneben schließt es.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use knips_platform::monitors;
use tauri::{AppHandle, WindowEvent};

use crate::app::knips;
use crate::wm;

pub const LABEL: &str = "menu";
pub const WIDTH: f64 = 340.0;

static HEIGHT_BITS: AtomicU64 = AtomicU64::new(0);
/// Zeitpunkt (ms), zu dem das Panel durch Fokusverlust geschlossen wurde — ein Klick aufs
/// Tray-Symbol direkt danach soll es nicht gleich wieder öffnen.
static CLOSED_AT: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub fn spec() -> wm::Spec {
    let mut spec = wm::Spec::floating(LABEL, "menu", (WIDTH, 520.0));
    spec.focusable = true;
    spec
}

fn height() -> f64 {
    let h = f64::from_bits(HEIGHT_BITS.load(Ordering::Relaxed));
    if h > 50.0 { h } else { 520.0 }
}

/// Fokusverlust schließt das Panel.
pub fn install(app: &AppHandle) {
    if let Some(window) = wm::get(app, LABEL) {
        let w = window.clone();
        window.on_window_event(move |event| {
            if let WindowEvent::Focused(false) = event {
                if w.is_visible().unwrap_or(false) {
                    let _ = w.hide();
                    CLOSED_AT.store(now_ms(), Ordering::Relaxed);
                }
            }
        });
    }
}

pub fn is_open(app: &AppHandle) -> bool {
    wm::get(app, LABEL).and_then(|w| w.is_visible().ok()).unwrap_or(false)
}

/// `anchor`: Klickpunkt am Tray-Symbol (global, physisch).
pub fn toggle(app: &AppHandle, anchor: Option<(i32, i32)>) {
    if is_open(app) {
        close(app);
    } else if now_ms().saturating_sub(CLOSED_AT.load(Ordering::Relaxed)) > 300 {
        show(app, anchor);
    }
}

pub fn show(app: &AppHandle, anchor: Option<(i32, i32)>) {
    let Ok(window) = wm::ensure(app, &spec()) else { return };
    let (ax, ay) = anchor.unwrap_or_else(monitors::cursor_pos);
    let m = monitors::at_point(ax, ay);
    let (w, h) = ((WIDTH * m.scale) as i32, (height() * m.scale) as i32);
    let gap = (8.0 * m.scale) as i32;
    // Taskleiste unten (üblich): über dem Klickpunkt; oben: darunter; seitlich: daneben.
    let mut x = ax - w / 2;
    let mut y = if ay >= m.work.bottom() { m.work.bottom() - h - gap } else if ay < m.work.y { m.work.y + gap } else { ay - h - gap };
    if ax >= m.work.right() {
        x = m.work.right() - w - gap;
        y = ay - h / 2;
    } else if ax < m.work.x {
        x = m.work.x + gap;
        y = ay - h / 2;
    }
    x = x.clamp(m.work.x + gap, m.work.right() - w - gap);
    y = y.clamp(m.work.y + gap, (m.work.bottom() - h - gap).max(m.work.y));
    wm::place(&window, &m, (WIDTH, height()), (x, y));
    knips().emit("menu-opened", ());
    let _ = window.show();
    let _ = window.set_focus();
    if let Some(h) = wm::hwnd(&window) {
        knips_platform::shell::activate(h);
    }
}

pub fn close(app: &AppHandle) {
    if let Some(w) = wm::get(app, LABEL) {
        let _ = w.hide();
    }
}

/// Die Seite meldet ihre Höhe; das offene Panel wächst nach oben (Unterkante bleibt).
pub fn resize(app: &AppHandle, h: f64) {
    let old = height();
    HEIGHT_BITS.store(h.to_bits(), Ordering::Relaxed);
    let Some(window) = wm::get(app, LABEL) else { return };
    let Ok(pos) = window.outer_position() else { return };
    let m = monitors::at_point(pos.x + 4, pos.y + 4);
    let bottom = pos.y + (old * m.scale) as i32;
    let y = if is_open(app) { bottom - (h * m.scale) as i32 } else { pos.y };
    wm::place(&window, &m, (WIDTH, h), (pos.x, y));
}
