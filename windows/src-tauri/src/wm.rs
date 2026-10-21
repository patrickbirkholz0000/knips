//! Fenster anlegen, platzieren, zeigen. Alle Knips-Fenster sind Web-Fenster derselben Seite
//! (`index.html#/<ansicht>`), nur das Auswahl-Overlay und die Aufnahmerahmen sind nativ.

#[cfg(feature = "dev")]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU8, Ordering};

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
    apply_capture_policy(&window);
    Ok(window)
}

// ---------------------------------------------------------------- Aufnahmen und Bildschirmübertragungen
//
// Knips-Fenster sind für andere Apps (Teams, Discord, OBS …) sichtbar wie jedes andere Fenster. Aus Knips'
// eigenen Bildern und Videos bleiben sie trotzdem heraus (wie der Content-Filter auf dem Mac):
// - Standbild: `conceal_for_still` nimmt sie kurz heraus (ab Windows 10 2004 nur für Aufnahmen, auf dem
//   Bildschirm ändert sich nichts).
// - Video und Scroll-Screenshot: `set_capture_session` schließt sie aus, solange die Aufnahme läuft; Karten und
//   Menü verschwinden dafür ganz.
// - Was zur Aufnahme selbst gehört (`CAPTURE_CHROME`, dazu Overlay und Rahmen im Plattform-Teil), ist immer
//   ausgeschlossen.
// - Einstellung „In Bildschirmübertragungen verbergen“ (`hide_from_screen_sharing`): alle Fenster immer aus.
// Vor Windows 10 2004 wirkt der Ausschluss nicht (`capture::exclusion_supported`); dann werden Fenster für ein
// Standbild verhüllt, und in Videos können eigene Fenster erscheinen.

/// Fenster, die zur Aufnahme selbst gehören und nie in einem Bild oder Video landen dürfen: Einblendung,
/// Aufnahme-Leiste, Countdown, Scroll-Leiste.
pub const CAPTURE_CHROME: [&str; 4] = [crate::hud::LABEL, crate::recording::CONTROLS, crate::recording::COUNTDOWN, crate::scroll::PANEL];

/// Laufende Video- bzw. Scroll-Aufnahme (Bits von `Session`): eigene Fenster sind so lange ausgeschlossen.
static CAPTURE_SESSION: AtomicU8 = AtomicU8::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Session {
    Recording = 1,
    Scroll = 2,
}

/// Selbsttest `sharing`: in der Sandbox ausschließen wie in der echten App (sonst bleiben dort alle Fenster
/// sichtbar, damit die Selbsttests sie fotografieren können).
#[cfg(feature = "dev")]
static SANDBOX_EXCLUSION: AtomicBool = AtomicBool::new(false);

#[cfg(feature = "dev")]
pub fn set_sandbox_exclusion(on: bool) {
    SANDBOX_EXCLUSION.store(on, Ordering::SeqCst);
}

fn sandbox() -> bool {
    #[cfg(feature = "dev")]
    if SANDBOX_EXCLUSION.load(Ordering::SeqCst) {
        return false;
    }
    paths::test_root().is_some()
}

/// Soll das Fenster `label` gerade aus allen Aufnahmen ausgeschlossen sein?
pub fn excluded_from_capture(label: &str) -> bool {
    if sandbox() {
        return false;
    }
    let hide_all = crate::app::try_knips().is_some_and(|k| k.settings.get().hide_from_screen_sharing);
    hide_all || CAPTURE_CHROME.contains(&label) || CAPTURE_SESSION.load(Ordering::SeqCst) != 0
}

/// Ausschluss eines Fensters nach den Regeln oben setzen.
pub fn apply_capture_policy(window: &WebviewWindow) {
    if let Some(h) = hwnd(window) {
        knips_platform::capture::exclude_from_capture(h, excluded_from_capture(window.label()));
    }
}

/// Nach einer Änderung (Einstellung, Beginn/Ende einer Aufnahme): alle offenen Fenster neu einstellen.
pub fn apply_capture_policy_all(app: &AppHandle) {
    for window in app.webview_windows().values() {
        apply_capture_policy(window);
    }
}

/// Beginn/Ende einer Video- oder Scroll-Aufnahme: eigene Fenster so lange ausschließen; Karten und Menü
/// verschwinden beim Beginn (auch vor Windows 10 2004, wo der Ausschluss nicht wirkt) und Karten kommen danach
/// wieder. Laufen beide, gilt das bis zum Ende der letzten.
pub fn set_capture_session(who: Session, active: bool) {
    let Some(k) = crate::app::try_knips() else { return };
    let bit = who as u8;
    let before = if active { CAPTURE_SESSION.fetch_or(bit, Ordering::SeqCst) } else { CAPTURE_SESSION.fetch_and(!bit, Ordering::SeqCst) };
    let after = if active { before | bit } else { before & !bit };
    if (before != 0) == (after != 0) {
        return;
    }
    if active {
        crate::menu::close(&k.app);
        k.cards.suspend();
    }
    apply_capture_policy_all(&k.app);
    if !active {
        k.cards.resume();
    }
}

/// Eigene Fenster, die für ein Standbild verborgen wurden; lässt sie beim Drop wieder zu.
pub struct StillConceal(Vec<(String, isize)>);

impl StillConceal {
    /// Ab Windows 10 2004 sind die Fenster nur für Aufnahmen verborgen, auf dem Bildschirm unverändert — dann
    /// gleich nach dem Standbild freigeben. Davor sind sie unsichtbar und bleiben es, bis die Auswahl vorbei
    /// ist (das Overlay zeigt ohnehin das Standbild).
    pub fn on_screen(&self) -> bool {
        knips_platform::capture::exclusion_supported()
    }
}

impl Drop for StillConceal {
    fn drop(&mut self) {
        if self.0.is_empty() {
            return;
        }
        let handles: Vec<isize> = self.0.iter().map(|(_, h)| *h).collect();
        knips_platform::capture::reveal_after_capture(&handles);
        // Regeln erneut anwenden: Hat sich inzwischen etwas geändert (Einstellung, Aufnahme), gilt das.
        for (label, h) in &self.0 {
            if excluded_from_capture(label) {
                knips_platform::capture::exclude_from_capture(*h, true);
            }
        }
    }
}

/// Alle Knips-Fenster (Karten, Menü, Pins, Editor, Einstellungen …) für ein Standbild aus dem Bild nehmen —
/// Knips' eigene Bilder zeigen nie Knips. Fenster, die ohnehin ausgeschlossen sind, bleiben unberührt.
pub fn conceal_for_still() -> StillConceal {
    let Some(k) = crate::app::try_knips() else { return StillConceal(Vec::new()) };
    let windows: Vec<(String, isize)> = k.app.webview_windows().into_iter().filter_map(|(label, w)| hwnd(&w).map(|h| (label, h))).collect();
    let handles: Vec<isize> = windows.iter().map(|(_, h)| *h).collect();
    let concealed = knips_platform::capture::conceal_for_capture(&handles);
    StillConceal(windows.into_iter().filter(|(_, h)| concealed.contains(h)).collect())
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
