//! Fenster anlegen, platzieren, zeigen. Alle Knips-Fenster sind Web-Fenster derselben Seite
//! (`index.html#/<ansicht>`), nur das Auswahl-Overlay und die Aufnahmerahmen sind nativ.

use anyhow::Result;
use knips_platform::{monitors, IRect, Monitor};
use tauri::{AppHandle, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::paths;

#[derive(Clone)]
pub struct Spec {
    pub label: String,
    pub route: String,
    pub title: String,
    /// Logische Pixel.
    pub size: (f64, f64),
    pub min_size: Option<(f64, f64)>,
    pub max_size: Option<(f64, f64)>,
    /// Normales Fenster mit Titelleiste (Editor, Einstellungen, Verlauf).
    pub decorated: bool,
    pub dark: bool,
    pub resizable: bool,
    /// Darf den Fokus bekommen. Karten, Einblendung und Leisten nicht — sonst verliert die App,
    /// in der gearbeitet wird, beim Erscheinen den Fokus.
    pub focusable: bool,
    /// WebView2 im InPrivate-Modus: nichts landet im Festplatten-Cache (`EBWebView`) — dort lägen
    /// sonst Originale, Vorschaubilder und Videos, die die Fenster über das Asset-Protokoll laden.
    /// Immer an; nur der Selbsttest schaltet es zum Vergleich ab.
    pub incognito: bool,
}

impl Spec {
    /// Rahmenloses, transparentes Schwebefenster (Menü, Karten, Einblendung, Leisten, Pins).
    pub fn floating(label: &str, route: &str, size: (f64, f64)) -> Self {
        Self {
            label: label.into(),
            route: route.into(),
            title: "Knips".into(),
            size,
            min_size: None,
            max_size: None,
            decorated: false,
            dark: true,
            resizable: false,
            focusable: false,
            incognito: true,
        }
    }

    pub fn window(label: &str, route: &str, title: &str, size: (f64, f64)) -> Self {
        Self {
            label: label.into(),
            route: route.into(),
            title: title.into(),
            size,
            min_size: None,
            max_size: None,
            decorated: true,
            dark: false,
            resizable: true,
            focusable: true,
            incognito: true,
        }
    }
}

pub fn get(app: &AppHandle, label: &str) -> Option<WebviewWindow> {
    app.get_webview_window(label)
}

/// Vorhandenes Fenster holen oder unsichtbar anlegen.
pub fn ensure(app: &AppHandle, spec: &Spec) -> Result<WebviewWindow> {
    if let Some(w) = app.get_webview_window(&spec.label) {
        return Ok(w);
    }
    let url = WebviewUrl::App(format!("index.html#/{}", spec.route.trim_start_matches('/')).into());
    let mut b = WebviewWindowBuilder::new(app, &spec.label, url)
        .title(&spec.title)
        .inner_size(spec.size.0, spec.size.1)
        .visible(false)
        .resizable(spec.resizable)
        .decorations(spec.decorated)
        // HTML-Ziehen startet natives Herausziehen (`item_start_drag`); Tauris Dateiablage würde stören.
        .disable_drag_drop_handler()
        .incognito(spec.incognito);
    if let Some((w, h)) = spec.min_size {
        b = b.min_inner_size(w, h);
    }
    if let Some((w, h)) = spec.max_size {
        b = b.max_inner_size(w, h);
    }
    if spec.dark {
        b = b.theme(Some(tauri::Theme::Dark));
    }
    if !spec.decorated {
        b = b
            .transparent(true)
            .always_on_top(true)
            .skip_taskbar(true)
            .shadow(false)
            .focused(false)
            .focusable(spec.focusable)
            .maximizable(false)
            .minimizable(false);
    } else {
        b = b.center();
    }
    let window = b.build()?;
    exclude_from_capture(&window);
    Ok(window)
}

/// Eigene Fenster gehören nie ins Bild (wie der Content-Filter auf dem Mac). In der Test-Sandbox
/// bleiben sie sichtbar, damit die Selbsttests sie fotografieren können.
pub fn exclude_from_capture(window: &WebviewWindow) {
    if paths::test_root().is_some() {
        return;
    }
    if let Some(hwnd) = hwnd(window) {
        knips_platform::capture::exclude_from_capture(hwnd, true);
    }
}

pub fn hwnd(window: &WebviewWindow) -> Option<isize> {
    #[cfg(windows)]
    {
        window.hwnd().ok().map(|h| h.0 as isize)
    }
    #[cfg(not(windows))]
    {
        let _ = window;
        None
    }
}

/// Fenster auf einem Monitor platzieren: Größe in logischen Pixeln, Ursprung physisch.
pub fn place(window: &WebviewWindow, monitor: &Monitor, logical: (f64, f64), origin: (i32, i32)) {
    let size = PhysicalSize::new((logical.0 * monitor.scale).round() as u32, (logical.1 * monitor.scale).round() as u32);
    // Erst auf den Zielmonitor schieben (Windows passt die Größe beim DPI-Wechsel an), dann Größe setzen.
    let _ = window.set_position(PhysicalPosition::new(origin.0, origin.1));
    let _ = window.set_size(size);
    let _ = window.set_position(PhysicalPosition::new(origin.0, origin.1));
}

/// Mittig auf dem Monitor mit der Maus.
pub fn center_on_cursor_monitor(window: &WebviewWindow, logical: (f64, f64)) {
    let m = monitors::at_cursor();
    let w = (logical.0 * m.scale) as i32;
    let h = (logical.1 * m.scale) as i32;
    place(window, &m, logical, (m.work.x + (m.work.width - w) / 2, m.work.y + (m.work.height - h) / 2));
}

/// Normales Fenster zeigen und nach vorn holen.
pub fn present(window: &WebviewWindow) {
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    if let Some(h) = hwnd(window) {
        knips_platform::shell::activate(h);
    }
}

/// Größe in logischen Pixeln auf den Arbeitsbereich begrenzen (90 %).
pub fn clamp_to_work(monitor: &Monitor, size: (f64, f64), min: (f64, f64)) -> (f64, f64) {
    let (ww, wh) = monitor.work_points();
    (size.0.max(min.0).min(ww * 0.9), size.1.max(min.1).min(wh * 0.9))
}

/// Globales physisches Rechteck eines monitor-lokalen Bereichs.
pub fn global(monitor: &Monitor, local: IRect) -> IRect {
    local.offset(monitor.rect.x, monitor.rect.y)
}
