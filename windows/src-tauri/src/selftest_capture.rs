//! Selbsttests rund um das Standbild (Feature `dev`):
//!
//! - `firstshot`: das allererste Standbild eines frischen Prozesses. Erst ein Kindprozess ohne App
//!   (`firstshot-roh`: erstes `capture::freeze` im Prozess und die rohen Meldungen einer neuen Desktop
//!   Duplication), dann in der laufenden App zweimal derselbe Weg wie die Druck-Taste
//!   (`Coordinator::perform(CaptureArea)` → Standbild → Auswahl-Overlay). Über einer Testfläche mit
//!   Farbbalken (nur GDI) wird geprüft: Das Standbild zeigt die Balken (nicht schwarz), und das Overlay
//!   erscheint auf dem Bildschirm als abgedunkeltes Standbild — nie schwarz, auch nicht kurz. Dafür ist
//!   das Overlay im Test nicht aus Aufnahmen ausgeschlossen; eine zweite Desktop-Duplication-Sitzung
//!   fotografiert den Bildschirm, während es erscheint. Nur auf Rechnern ohne Nutzer (CI).

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use knips_core::geometry::IRect;
use knips_core::imageops::{self, Brightness};
use knips_core::model::ImageFormat;
use knips_core::settings::HotkeyAction;
use knips_core::RgbaImage;
use knips_platform::capture::RegionCapturer;
use knips_platform::overlay::{self, Purpose};
use knips_platform::{capture, monitors, testinput, Frozen, Monitor};
use parking_lot::Mutex;
use tauri::{AppHandle, Manager, WebviewWindow};

type FreezeHook = Box<dyn Fn(&[Frozen]) + Send + Sync>;

/// Wird nach dem Standbild für das Overlay gerufen, bevor das Overlay erscheint (nur in Selbsttests gesetzt).
static FREEZE_HOOK: Mutex<Option<FreezeHook>> = Mutex::new(None);

/// Vom Koordinator nach jedem Standbild für das Auswahl-Overlay aufgerufen.
pub fn after_freeze(frozen: &[Frozen]) {
    if let Some(hook) = FREEZE_HOOK.lock().as_ref() {
        hook(frozen);
    }
}

fn write(image: &RgbaImage, path: &Path) -> Result<()> {
    std::fs::write(path, imageops::encode(image, ImageFormat::Png)?)?;
    Ok(())
}

/// Testfläche: Mitte des Hauptbildschirms, oben (weg von Hinweiszeile und Taskleiste), global.
fn test_area(m: &Monitor) -> IRect {
    IRect::new(m.rect.x + m.rect.width / 10, m.rect.y + m.rect.height / 8, m.rect.width * 6 / 10, m.rect.height / 2)
}

/// Wie viele Farbbalken der Testfläche (`area`, im Bild) das Bild zeigt.
fn pattern_hits(img: &RgbaImage, area: IRect) -> usize {
    let colors = testinput::PATTERN_COLORS;
    let n = colors.len() as i32;
    colors
        .iter()
        .enumerate()
        .filter(|(i, c)| {
            let x = area.x + area.width * (2 * *i as i32 + 1) / (2 * n);
            let y = area.y + area.height / 2;
            if x < 0 || y < 0 || x >= img.width() as i32 || y >= img.height() as i32 {
                return false;
            }
            let p = img.get_pixel(x as u32, y as u32).0;
            (0..3).all(|k| (p[k] as i32 - c[k] as i32).abs() <= 24)
        })
        .count()
}

/// Innenfläche eines eigenen Fensters (global, physische Pixel).
pub(crate) fn window_rect(app: &AppHandle, label: &str) -> Result<IRect> {
    let w = app.get_webview_window(label).with_context(|| format!("Fenster {label} fehlt"))?;
    let (p, s) = (w.inner_position()?, w.inner_size()?);
    Ok(IRect::new(p.x, p.y, s.width as i32, s.height as i32))
}

/// Mittlere Abweichung der Helligkeit (0…255) zweier Bilder im Ausschnitt `r`.
fn region_diff(a: &RgbaImage, b: &RgbaImage, r: IRect) -> f64 {
    let luma = |p: [u8; 4]| 0.299 * p[0] as f64 + 0.587 * p[1] as f64 + 0.114 * p[2] as f64;
    let (mut sum, mut n) = (0.0, 0u64);
    for y in (r.y.max(0) as u32..(r.bottom() as u32).min(a.height()).min(b.height())).step_by(2) {
        for x in (r.x.max(0) as u32..(r.right() as u32).min(a.width()).min(b.width())).step_by(2) {
            sum += (luma(a.get_pixel(x, y).0) - luma(b.get_pixel(x, y).0)).abs();
            n += 1;
        }
    }
    if n == 0 {
        f64::NAN
    } else {
        sum / n as f64
    }
}

/// Mittlere Abweichung zweier Standbilder im Bereich `rect` (global), auf dem Bildschirm, der ihn enthält.
pub(crate) fn still_diff(a: &[Frozen], b: &[Frozen], rect: IRect) -> f64 {
    for fa in a {
        let Some(fb) = b.iter().find(|f| f.monitor.id == fa.monitor.id) else { continue };
        let bounds = IRect::new(0, 0, fa.monitor.rect.width, fa.monitor.rect.height);
        if let Some(local) = rect.offset(-fa.monitor.rect.x, -fa.monitor.rect.y).intersection(&bounds) {
            return region_diff(&fa.image, &fb.image, local);
        }
    }
    f64::NAN
}

fn bright(img: &RgbaImage, area: Option<IRect>) -> Brightness {
    imageops::brightness(img, area, 4)
}

fn show(b: Brightness) -> String {
    format!("Helligkeit {:.0}, schwarz {:.0} %", b.mean, b.black * 100.0)
}

// ------------------------------------------------------------------ Bildschirmübertragungen

/// Fenstertest `sharing`: Knips-Fenster in Bildschirmübertragungen (Teams, Discord, OBS) und in Knips' eigenen
/// Aufnahmen. Ausschluss wie in der echten App (`wm::set_sandbox_exclusion`). Eine Desktop Duplication sieht,
/// was jede andere Aufnahme-App sieht.
pub fn sharing(app: &AppHandle, out: &Path) -> Result<()> {
    use crate::selftest::probe;
    use crate::wm;
    let k = crate::app::knips();
    if !capture::exclusion_supported() {
        bail!("Windows kann hier keine Fenster aus Aufnahmen ausschließen");
    }
    let mut failures: Vec<String> = vec![];
    let mut check = |name: &str, ok: bool| {
        println!("   {}  {name}", if ok { "ok    " } else { "FALSCH" });
        if !ok {
            failures.push(name.to_string());
        }
    };
    wm::set_sandbox_exclusion(true);
    wm::apply_capture_policy_all(app);
    let m = monitors::primary();
    let excluded = |label: &str| app.get_webview_window(label).and_then(|w| wm::hwnd(&w)).map(capture::is_excluded);

    // Fenster aller Arten: Einstellungen, Karte (nach einer Aufnahme), Pin, Menü (vorgewärmt), Einblendung, Leisten.
    crate::commands::show_settings(app, Some("privacy".into()));
    k.coordinator.finish(knips_platform::sample::sample_image(640, 400, 1.0), 1.0, &m);
    k.pins.pin(Arc::new(knips_platform::sample::sample_image(320, 200, 1.0)), 1.0)?;
    k.hud.show("Test", "check");
    for (label, route, size) in [(crate::recording::CONTROLS, "rec-controls", (246.0, 44.0)), (crate::recording::COUNTDOWN, "rec-countdown", (150.0, 176.0)), (crate::scroll::PANEL, "scroll-controls", (380.0, 48.0))] {
        wm::ensure(app, &wm::Spec::floating(label, route, size))?;
    }
    std::thread::sleep(Duration::from_millis(1500));
    let pin = app.webview_windows().into_keys().find(|l| l.starts_with("pin-")).context("Pin fehlt")?;
    let normal = ["settings", crate::cards::LABEL, crate::menu::LABEL, pin.as_str()];
    println!("Standard (Einstellung aus):");
    for label in normal {
        check(&format!("{label}: für andere Apps sichtbar"), excluded(label) == Some(false));
    }
    for label in wm::CAPTURE_CHROME {
        check(&format!("{label}: gehört zur Aufnahme, ausgeschlossen"), excluded(label) == Some(true));
    }
    let cards_visible = || app.get_webview_window(crate::cards::LABEL).is_some_and(|w| w.is_visible().unwrap_or(false));
    check("Karte nach der Aufnahme sichtbar", cards_visible());

    // Bildschirmbild wie bei Discord/OBS: zeigt die Einstellungen. Vergleich: Bild ohne sie (ausgeblendet), in der
    // oberen Hälfte der Einstellungen — der Pin (immer obenauf) kommt dafür in die Ecke unten rechts.
    if let Some(p) = app.get_webview_window(&pin) {
        let size = p.outer_size()?;
        let _ = p.set_position(tauri::PhysicalPosition::new(m.work.right() - size.width as i32 - 8, m.work.bottom() - size.height as i32 - 8));
    }
    let settings = app.get_webview_window("settings").context("Einstellungen fehlen")?;
    let settings_h = wm::hwnd(&settings).context("Einstellungen ohne HWND")?;
    let rect = window_rect(app, "settings")?;
    let upper = IRect::new(rect.x, rect.y, rect.width, rect.height / 2);
    std::thread::sleep(Duration::from_millis(500));
    let with_settings = capture::freeze(&monitors::list())?;
    // Vergleichsbild: der Bildschirm ohne alle Knips-Fenster (ausgeblendet).
    let shown: Vec<WebviewWindow> = app.webview_windows().into_values().filter(|w| w.is_visible().unwrap_or(false)).collect();
    let describe_window = |w: &WebviewWindow| match (w.outer_position(), w.outer_size()) {
        (Ok(p), Ok(s)) => format!("{} ({}, {}, {}×{})", w.label(), p.x, p.y, s.width, s.height),
        _ => w.label().to_string(),
    };
    println!("   sichtbare Knips-Fenster: {}", shown.iter().map(describe_window).collect::<Vec<_>>().join(", "));
    for w in app.webview_windows().values() {
        let h = wm::hwnd(w).unwrap_or(0);
        println!(
            "      {}: sichtbar {}, aufnehmbar {}, ausgeschlossen {}",
            describe_window(w),
            w.is_visible().unwrap_or(false),
            capture::capturable(h),
            capture::is_excluded(h)
        );
    }
    for w in &shown {
        let _ = w.hide();
    }
    std::thread::sleep(Duration::from_millis(700));
    let truth = capture::freeze(&monitors::list())?;
    for w in &shown {
        let _ = w.show();
    }
    std::thread::sleep(Duration::from_millis(700));
    let save = |frozen: &[Frozen], name: &str| {
        if let Some(f) = frozen.iter().find(|f| f.monitor.id == m.id) {
            let _ = write(&f.image, &out.join(format!("sharing-{name}.png")));
        }
    };
    save(&with_settings, "mit-einstellungen");
    save(&truth, "ohne-einstellungen");
    let seen = still_diff(&with_settings, &truth, upper);
    println!("   Bildschirmbild (wie Discord/OBS): Abweichung zum Bild ohne Einstellungen {seen:.1}");
    check("Bildschirmbild (wie Discord/OBS) zeigt die Einstellungen", seen >= 10.0);

    // Wie lange braucht der Ausschluss, bis ein frisches Standbild ihn zeigt? (für `CONCEAL_SETTLE`)
    for delay in [0u64, 16, 33, 50, 100] {
        capture::exclude_from_capture(settings_h, true);
        std::thread::sleep(Duration::from_millis(delay));
        let still = capture::freeze(&monitors::list())?;
        capture::exclude_from_capture(settings_h, false);
        let d = still_diff(&still, &truth, upper);
        println!("   Ausschluss + {delay} ms: Abweichung {d:.1} ({})", if d <= 3.0 { "ohne Einstellungen" } else { "noch mit" });
        std::thread::sleep(Duration::from_millis(150));
    }

    // Knips' eigenes Standbild: ohne Knips-Fenster, auf dem Bildschirm bleiben sie unverändert.
    let t = Instant::now();
    let conceal = wm::conceal_for_still();
    let during_capturable = capture::capturable(settings_h);
    let during_visible = settings.is_visible().unwrap_or(false) && cards_visible();
    let still = capture::freeze(&monitors::list())?;
    drop(conceal);
    let ms = t.elapsed().as_millis();
    save(&still, "eigenes-standbild");
    let d = still_diff(&still, &truth, upper);
    println!("   eigenes Standbild: Abweichung {d:.1}, Fenster {ms} ms für Aufnahmen verborgen");
    check("eigenes Standbild ohne Knips-Fenster", d <= 3.0);
    check("dabei auf dem Bildschirm unverändert (sichtbar, nur für Aufnahmen verborgen)", !during_capturable && during_visible);
    check("danach wieder für andere Apps sichtbar", excluded("settings") == Some(false) && capture::capturable(settings_h));

    // Schalter „In Bildschirmübertragungen verbergen“ (Datenschutz) — über die Oberfläche.
    let switch = "[...document.querySelectorAll('.k-row')].find(r => r.textContent.includes('In Bildschirmübertragungen verbergen'))?.querySelector('[role=switch]')";
    let found = probe(&settings, &format!("(() => {{ const s = {switch}; if (!s) return 'fehlt'; s.scrollIntoView({{ block: 'center' }}); return s.getAttribute('aria-checked'); }})()"), Duration::from_secs(3))?;
    std::thread::sleep(Duration::from_millis(500));
    crate::selftest::shoot(app, "settings", out, "einstellungen-datenschutz-uebertragung.png")?;
    check("Schalter in Datenschutz, standardmäßig aus", found == "false");
    probe(&settings, &format!("({switch}.click(), 'ok')"), Duration::from_secs(3))?;
    let on = (0..40).any(|_| {
        std::thread::sleep(Duration::from_millis(50));
        k.settings.get().hide_from_screen_sharing
    });
    check("Schalter schaltet die Einstellung ein", on);
    println!("Einstellung an:");
    for label in normal.iter().copied().chain(wm::CAPTURE_CHROME) {
        check(&format!("{label}: sofort ausgeschlossen"), excluded(label) == Some(true));
    }
    crate::commands::show_history(app);
    std::thread::sleep(Duration::from_millis(1200));
    check("neues Fenster (Verlauf) ausgeschlossen", excluded("history") == Some(true));
    if let Some(h) = app.get_webview_window("history") {
        let _ = h.hide();
    }
    std::thread::sleep(Duration::from_millis(300));
    let hidden = capture::freeze(&monitors::list())?;
    save(&hidden, "einstellung-an");
    let d = still_diff(&hidden, &truth, upper);
    println!("   Bildschirmbild mit Einstellung an: Abweichung {d:.1}");
    check("Bildschirmbild (wie Discord/OBS) ohne die Einstellungen", d <= 3.0);
    probe(&settings, &format!("({switch}.click(), 'ok')"), Duration::from_secs(3))?;
    let off = (0..40).any(|_| {
        std::thread::sleep(Duration::from_millis(50));
        !k.settings.get().hide_from_screen_sharing
    });
    check("Schalter schaltet die Einstellung aus", off);
    println!("Einstellung wieder aus:");
    for label in normal {
        check(&format!("{label}: wieder sichtbar"), excluded(label) == Some(false));
    }
    check("Einblendung bleibt ausgeschlossen", excluded(crate::hud::LABEL) == Some(true));

    // Verborgene Fenster: Ein ausdrückliches WDA_NONE auf ein verborgenes Fenster darf es nicht ins Bild holen
    // (Menü, vorgewärmt und nie gezeigt). Vergleich im Bereich des Menüs mit dem Bild davor.
    println!("Verborgenes Menü:");
    let menu_w = app.get_webview_window(crate::menu::LABEL).context("Menü fehlt")?;
    let menu_h = wm::hwnd(&menu_w).context("Menü ohne HWND")?;
    let menu_rect = {
        let (p, s) = (menu_w.outer_position()?, menu_w.outer_size()?);
        IRect::new(p.x, p.y, s.width as i32, s.height as i32)
    };
    let base = capture::freeze(&monitors::list())?;
    save(&base, "menue-vorher");
    let conceal = wm::conceal_for_still();
    drop(conceal);
    std::thread::sleep(Duration::from_millis(200));
    let after_still = capture::freeze(&monitors::list())?;
    save(&after_still, "menue-nach-standbild");
    capture::exclude_from_capture(menu_h, true);
    capture::exclude_from_capture(menu_h, false);
    std::thread::sleep(Duration::from_millis(200));
    let after_none = capture::freeze(&monitors::list())?;
    save(&after_none, "menue-nach-wda-none");
    let (d_still, d_none) = (still_diff(&after_still, &base, menu_rect), still_diff(&after_none, &base, menu_rect));
    println!("   Abweichung im Bereich des Menüs zum Bild davor: nach einem Standbild {d_still:.1}, nach ausdrücklichem WDA_NONE {d_none:.1}");
    check("verborgenes Menü bleibt nach einem Standbild unsichtbar", d_still <= 3.0);

    // Videoaufnahme (bis zum Countdown, dann abgebrochen): Karten und Menü weg, eigene Fenster aus dem Video.
    println!("Videoaufnahme:");
    k.settings.update(|s| s.recording_countdown = true);
    crate::menu::show(app, Some((m.work.right() - 200, m.work.bottom() + 10)));
    std::thread::sleep(Duration::from_millis(800));
    k.recording.begin(m.clone(), IRect::new(m.rect.width / 4, m.rect.height / 4, m.rect.width / 2, m.rect.height / 2));
    std::thread::sleep(Duration::from_millis(800));
    check("Countdown läuft", k.recording.is_busy());
    check("Karten ausgeblendet", !cards_visible() && k.cards.is_suspended());
    check("Menü geschlossen", !crate::menu::is_open(app));
    check("Einstellungen und Pin aus dem Video", excluded("settings") == Some(true) && excluded(&pin) == Some(true));
    k.recording.stop(false);
    std::thread::sleep(Duration::from_millis(1200));
    check("nach der Aufnahme: Einstellungen und Pin wieder sichtbar", excluded("settings") == Some(false) && excluded(&pin) == Some(false));
    check("nach der Aufnahme: Karten wieder da", cards_visible() && !k.cards.is_suspended());

    wm::set_sandbox_exclusion(false);
    wm::apply_capture_policy_all(app);
    if !failures.is_empty() {
        bail!("Bildschirmübertragung: {}", failures.join(", "));
    }
    Ok(())
}

// ------------------------------------------------------------------ Kindprozess ohne App

/// `firstshot-roh`: erstes Standbild im Prozess (ohne App), dann eine neue Sitzung roh, dann ein zweites Standbild.
pub fn firstshot_raw(out: &Path) -> Result<()> {
    let m = monitors::primary();
    let area = test_area(&m);
    let local = area.offset(-m.rect.x, -m.rect.y);
    let _pattern = testinput::show_pattern(area)?;
    testinput::move_to(m.rect.right() - 4, m.rect.y + 4);
    std::thread::sleep(Duration::from_millis(1200));

    let t = Instant::now();
    let first = capture::freeze(std::slice::from_ref(&m))?.remove(0);
    let first_ms = t.elapsed().as_millis();
    let first_hits = pattern_hits(&first.image, local);
    println!("Erstes Standbild im Prozess: {first_ms} ms, Testfläche {first_hits}/8 Farbbalken, {}", show(bright(&first.image, Some(local))));
    for n in capture::freeze_notes() {
        println!("   {n}");
    }
    if let Some(c) = imageops::crop(&first.image, local) {
        write(&c, &out.join("firstshot-roh-1.png"))?;
    }

    println!("Neue Desktop-Duplication-Sitzung, rohe Meldungen:");
    match capture::probe_duplication(&m, 4) {
        Ok(list) => {
            for (text, img) in list {
                let hits = if img.width() > 1 { format!(" · Testfläche {}/8", pattern_hits(&img, local)) } else { String::new() };
                println!("   {text}{hits}");
            }
        }
        Err(err) => println!("   nicht möglich: {err:#}"),
    }
    // Erste Meldung frischer Sitzungen, während sich der Mauszeiger bewegt (Auskunft: kommt sie ohne Desktop-Bild?).
    let (mut without_image, mut total) = (0, 0);
    for i in 0..12 {
        testinput::move_to(m.rect.right() - 40 - i * 20, m.rect.y + 30 + i * 10);
        if let Ok(list) = capture::probe_duplication(&m, 1) {
            total += 1;
            if let Some((text, img)) = list.first() {
                if text.contains("LastPresentTime 0,") || img.width() <= 1 || pattern_hits(img, local) < 7 {
                    without_image += 1;
                    println!("   frische Sitzung {}: {text}", i + 1);
                }
            }
        }
    }
    println!("Frische Sitzungen bei bewegtem Zeiger: {without_image} von {total} ohne Testfläche in der ersten Meldung");
    testinput::move_to(m.rect.right() - 4, m.rect.y + 4);

    let t = Instant::now();
    let second = capture::freeze(std::slice::from_ref(&m))?.remove(0);
    let second_hits = pattern_hits(&second.image, local);
    println!("Zweites Standbild: {} ms, Testfläche {second_hits}/8 Farbbalken, {}", t.elapsed().as_millis(), show(bright(&second.image, Some(local))));
    for n in capture::freeze_notes() {
        println!("   {n}");
    }
    if std::env::var_os("KNIPS_TEST_DDA_EMPTY_FIRST").is_some() {
        // Die leere erste Meldung muss verworfen worden sein (und das Bild trotzdem stimmen).
        let notes = capture::freeze_notes();
        if !notes.iter().any(|n| n.contains("ohne Desktop-Bild, verworfen")) {
            bail!("leere erste Meldung nicht verworfen");
        }
    }
    if first_hits < 7 {
        bail!("erstes Standbild im Prozess zeigt die Testfläche nicht ({first_hits}/8 Farbbalken, zweites {second_hits}/8)");
    }
    if second_hits < 7 {
        bail!("zweites Standbild zeigt die Testfläche nicht ({second_hits}/8 Farbbalken)");
    }
    Ok(())
}

/// `firstshot-roh` als frischen Prozess starten. `empty_first`: erste Meldung jeder Desktop-Duplication-Sitzung
/// ohne Desktop-Bild (schwarze Textur) simulieren, wie manche Grafiktreiber sie liefern.
fn run_raw_child(out: &Path, empty_first: bool) -> Result<bool> {
    let dir = out.join(if empty_first { "roh-leer" } else { "roh" });
    std::fs::create_dir_all(&dir)?;
    let mut cmd = std::process::Command::new(std::env::current_exe()?);
    cmd.args(["--selftest", "firstshot-roh"]).arg(&dir).stderr(std::process::Stdio::null());
    if empty_first {
        cmd.env("KNIPS_TEST_DDA_EMPTY_FIRST", "1");
    }
    let output = cmd.output()?;
    let tag = if empty_first { "ohne App, erste Meldung leer" } else { "ohne App" };
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        println!("   [{tag}] {line}");
    }
    Ok(output.status.success())
}

// ------------------------------------------------------------------ Bildschirm während das Overlay erscheint

/// Zweite Desktop-Duplication-Sitzung, die den Bereich der Testfläche fotografiert, bis `finish`.
struct Sampler {
    stop: Arc<AtomicBool>,
    thread: std::thread::JoinHandle<Vec<(u128, RgbaImage)>>,
}

impl Sampler {
    /// Startet und wartet, bis das erste Bild da ist. Zeiten in ms ab `t0`.
    fn start(monitor: Monitor, local: IRect, t0: Instant) -> Result<Sampler> {
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel::<std::result::Result<(), String>>();
        let flag = stop.clone();
        let thread = std::thread::spawn(move || {
            let mut frames: Vec<(u128, RgbaImage)> = Vec::new();
            let mut capturer = match RegionCapturer::new(&monitor, local) {
                Ok(c) => c,
                Err(err) => {
                    let _ = tx.send(Err(format!("{err:#}")));
                    return frames;
                }
            };
            let mut ready = Some(tx);
            while !flag.load(Ordering::SeqCst) {
                if let Ok(img) = capturer.grab() {
                    if frames.last().is_none_or(|(_, last)| last.as_raw() != img.as_raw()) {
                        frames.push((t0.elapsed().as_millis(), img));
                    }
                }
                if let Some(tx) = ready.take() {
                    let _ = tx.send(Ok(()));
                }
            }
            frames
        });
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Sampler { stop, thread }),
            Ok(Err(e)) => bail!("Bildschirm-Probe: {e}"),
            Err(_) => bail!("Bildschirm-Probe: kein erstes Bild"),
        }
    }

    fn finish(self) -> Vec<(u128, RgbaImage)> {
        self.stop.store(true, Ordering::SeqCst);
        self.thread.join().unwrap_or_default()
    }
}

/// Was ein Bild der Testfläche gegenüber dem Bildschirm vor dem Overlay zeigt.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Look {
    /// wie vorher (kein Overlay)
    Live,
    /// abgedunkeltes Standbild (Overlay, Abdunklung 38 %)
    Dimmed,
    /// schwarz bzw. fast schwarz
    Black,
    Other,
}

fn look(b: Brightness, reference: f64) -> Look {
    let r = b.mean / reference.max(1.0);
    if r < 0.2 || b.black > 0.9 {
        Look::Black
    } else if r > 0.85 {
        Look::Live
    } else if (0.45..=0.8).contains(&r) {
        Look::Dimmed
    } else {
        Look::Other
    }
}

struct Round {
    frozen: Frozen,
    still_hits: usize,
    still: Brightness,
    notes: Vec<String>,
    freeze_ms: u128,
    timeline: Vec<String>,
    black_frames: usize,
    dimmed_frames: usize,
}

/// Einmal Druck-Taste: Standbild + Overlay über den Koordinator, Bildschirm beobachten, Overlay abbrechen.
fn shot_round(round: u32, m: &Monitor, area: IRect, out: &Path) -> Result<Round> {
    let k = crate::app::knips();
    let local = area.offset(-m.rect.x, -m.rect.y);
    let t0 = Instant::now();
    let (tx, rx) = std::sync::mpsc::channel::<(Vec<Frozen>, Vec<String>, u128)>();
    let sampler: Arc<Mutex<Option<Sampler>>> = Arc::new(Mutex::new(None));
    let sampler_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    {
        let tx = Mutex::new(tx);
        let (slot, error, monitor) = (sampler.clone(), sampler_error.clone(), m.clone());
        *FREEZE_HOOK.lock() = Some(Box::new(move |frozen: &[Frozen]| {
            let _ = tx.lock().send((frozen.to_vec(), capture::freeze_notes(), t0.elapsed().as_millis()));
            // Erst beobachten, dann darf das Overlay erscheinen (zweite Sitzung erst nach dem Standbild,
            // damit das Standbild des Koordinators das erste im Prozess bleibt).
            match Sampler::start(monitor.clone(), local, t0) {
                Ok(s) => *slot.lock() = Some(s),
                Err(e) => *error.lock() = Some(format!("{e:#}")),
            }
        }));
    }
    k.coordinator.perform(HotkeyAction::CaptureArea);
    let received = rx.recv_timeout(Duration::from_secs(15));
    let result = (|| -> Result<Round> {
        let (frozen, notes, freeze_ms) = received.context("kein Standbild vom Koordinator")?;
        if let Some(e) = sampler_error.lock().take() {
            bail!("{e}");
        }
        let still = frozen.iter().find(|f| f.monitor.id == m.id).context("Standbild des Hauptbildschirms fehlt")?;
        let still_hits = pattern_hits(&still.image, local);
        let still_b = bright(&still.image, Some(local));
        if let Some(c) = imageops::crop(&still.image, local) {
            write(&c, &out.join(format!("firstshot-standbild-{round}.png")))?;
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !overlay::is_active() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        if !overlay::is_active() {
            bail!("Overlay erschien nicht");
        }
        let shown_ms = t0.elapsed().as_millis();
        std::thread::sleep(Duration::from_millis(1500));
        overlay::cancel();
        let deadline = Instant::now() + Duration::from_secs(5);
        while overlay::is_active() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let frames = sampler.lock().take().map(Sampler::finish).unwrap_or_default();
        let Some((_, first)) = frames.first() else { bail!("keine Bilder vom Bildschirm") };
        // Maßstab: der Bildschirm vor dem Overlay (erstes Bild der Probe) bzw. das Standbild, falls heller.
        let reference = bright(first, None).mean.max(still_b.mean);
        let mut timeline = vec![];
        let (mut black_frames, mut dimmed_frames, mut saved_dimmed) = (0, 0, false);
        for (i, (ms, img)) in frames.iter().enumerate() {
            let b = bright(img, None);
            let l = look(b, reference);
            timeline.push(format!("{ms} ms {l:?} ({}){}", show(b), if i == 0 { " — erstes Bild der Probe" } else { "" }));
            if i == 0 {
                continue;
            }
            match l {
                Look::Black => {
                    black_frames += 1;
                    write(img, &out.join(format!("firstshot-schwarz-{round}-{i}.png")))?;
                }
                Look::Dimmed => {
                    dimmed_frames += 1;
                    if !saved_dimmed {
                        write(img, &out.join(format!("firstshot-overlay-{round}.png")))?;
                        saved_dimmed = true;
                    }
                }
                _ => {}
            }
        }
        timeline.insert(0, format!("Standbild nach {freeze_ms} ms, Overlay aktiv nach {shown_ms} ms; Maßstab Helligkeit {reference:.0}"));
        let frozen = still.clone();
        Ok(Round { frozen, still_hits, still: still_b, notes, freeze_ms, timeline, black_frames, dimmed_frames })
    })();
    *FREEZE_HOOK.lock() = None;
    if overlay::is_active() {
        overlay::cancel();
    }
    if let Some(s) = sampler.lock().take() {
        s.finish();
    }
    result
}

/// Fenstertest `firstshot` (siehe Modulkommentar).
pub fn firstshot(_app: &AppHandle, out: &Path) -> Result<()> {
    let mut failures: Vec<String> = vec![];
    // 1. Ohne App, im frischen Kindprozess — einmal normal, einmal mit leerer erster Meldung (simuliert).
    for empty_first in [false, true] {
        let what = if empty_first { "mit leerer erster Meldung" } else { "ohne App" };
        match run_raw_child(out, empty_first) {
            Ok(true) => println!("   ok     erstes Standbild ({what}) zeigt die Testfläche"),
            Ok(false) => failures.push(format!("erstes Standbild ({what}, Kindprozess)")),
            Err(err) => failures.push(format!("Kindprozess ({what}): {err:#}")),
        }
    }

    // 2. In der App, über den Weg der Druck-Taste
    let m = monitors::primary();
    let area = test_area(&m);
    let _pattern = testinput::show_pattern(area)?;
    // Zeiger in die Ecke: Fadenkreuz und Lupe liegen dann außerhalb der Testfläche.
    testinput::move_to(m.rect.right() - 4, m.rect.y + 4);
    std::thread::sleep(Duration::from_millis(1500));
    overlay::set_capturable_for_tests(true);
    let mut first_still = None;
    for round in 1..=2 {
        let r = match shot_round(round, &m, area, out) {
            Ok(r) => r,
            Err(err) => {
                failures.push(format!("Druck #{round}: {err:#}"));
                continue;
            }
        };
        println!("Druck #{round}: Standbild nach {} ms, Testfläche {}/8 Farbbalken, {}", r.freeze_ms, r.still_hits, show(r.still));
        for n in &r.notes {
            println!("   {n}");
        }
        println!("   Bildschirm, während das Overlay erscheint:");
        for t in &r.timeline {
            println!("      {t}");
        }
        if r.still_hits < 7 {
            failures.push(format!("Druck #{round}: Standbild zeigt die Testfläche nicht ({}/8, {})", r.still_hits, show(r.still)));
        }
        if r.black_frames > 0 {
            failures.push(format!("Druck #{round}: Overlay {} Bild(er) schwarz", r.black_frames));
        }
        if r.dimmed_frames == 0 {
            failures.push(format!("Druck #{round}: Overlay nicht als abgedunkeltes Standbild gesehen"));
        }
        if round == 1 {
            first_still = Some(r);
        }
    }
    overlay::set_capturable_for_tests(false);

    // 3. Overlay aus dem ersten Standbild offscreen gezeichnet (wie `selection`): abgedunkelt, nicht schwarz.
    if let Some(f) = first_still.map(|r| r.frozen) {
        let local = area.offset(-m.rect.x, -m.rect.y);
        let img = overlay::render_offscreen(&f, &[], Purpose::Screenshot, false, (f.monitor.rect.width - 4, 4), None)?;
        let (b, s) = (bright(&img, Some(local)), bright(&f.image, Some(local)));
        let l = look(b, s.mean);
        println!("Overlay offscreen aus dem ersten Standbild: {l:?} ({}, Standbild {})", show(b), show(s));
        if let Some(c) = imageops::crop(&img, local) {
            write(&c, &out.join("firstshot-overlay-offscreen.png"))?;
        }
        if l != Look::Dimmed {
            failures.push(format!("Overlay offscreen aus dem ersten Standbild: {l:?}"));
        }
    }
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}
