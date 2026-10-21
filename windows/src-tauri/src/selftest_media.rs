//! Selbsttests für Video und Verträglichkeit mit älteren/abgespeckten Windows-Ausgaben (Feature `dev`).
//!
//! - `video` (Teil `vfr_export`): Quelle mit variabler Bildrate wie eine Bildschirmaufnahme → Export hat
//!   ≥ 24 fps und jedes Exportbild zeigt das Quellbild seiner Zeit (Bewegung bleibt erhalten).
//! - `record` (Teil `MouseMover`/`check_recording_export`): Maus bewegt sich während der Aufnahme; der
//!   Export der Aufnahme hat ≥ 24 fps.
//! - `nomedia`: Windows N/KN ohne Media Feature Pack, simuliert mit `KNIPS_TEST_NO_MEDIA`: Importtabelle
//!   der knips.exe (Media Foundation nur verzögert), Videofunktionen melden den Hinweis statt abzustürzen,
//!   Video-Kürzel zeigt den Hinweis statt der Auswahl, Screenshots gehen weiter, Einstellungen und Menü
//!   zeigen den Hinweis. Bilder: `einstellungen-aufnahme-ohne-media.png`, `menu-ohne-media.png`.
//! - `oldwin`: Windows vor 10 2004, simuliert mit `KNIPS_TEST_OLD_WINDOWS`: kein `WDA_EXCLUDEFROMCAPTURE`;
//!   eigene Fenster werden für Standbilder ausgeblendet und danach wieder gezeigt.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use knips_core::geometry::{IRect, Rect};
use knips_core::model::{CaptureKind, RedactStyle, VideoDocument, VideoRedaction};
use knips_core::RgbaImage;
use knips_platform::media::{self, FrameReader};
use knips_platform::{capture, monitors, Monitor};
use tauri::{AppHandle, Manager};

use crate::selftest::{pattern, probe, scrolling_frame, shoot};

// ------------------------------------------------------------------ variable Bildrate

/// Mittlere Abweichung zweier gleich großer Bilder ab Zeile `from_y` (Graustufen, 0…255).
fn diff(a: &RgbaImage, b: &RgbaImage, from_y: u32) -> f64 {
    let (w, h) = (a.width().min(b.width()), a.height().min(b.height()));
    let mut sum = 0u64;
    let mut n = 0u64;
    for y in from_y..h {
        for x in 0..w {
            let (p, q) = (a.get_pixel(x, y).0, b.get_pixel(x, y).0);
            let g = |c: [u8; 4]| (c[0] as i32 * 3 + c[1] as i32 * 6 + c[2] as i32) / 10;
            sum += (g(p) - g(q)).unsigned_abs() as u64;
            n += 1;
        }
    }
    sum as f64 / n.max(1) as f64
}

/// Quelle wie eine Bildschirmaufnahme mit 30 fps: Bilder nur bei Änderung — 0,5 s Stillstand, 1 s
/// Bewegung (30 Bilder), 2 s Stillstand. Durchschnitt ≈ 9 fps; vorher exportierte Knips mit dieser
/// Durchschnittsrate (CI: „2,4 fps“), Bewegung ruckelte und Zensur traf nur grob die Zeit.
pub fn vfr_export(out: &Path) -> Result<()> {
    let (w, h, step, moving) = (1280u32, 720u32, 12u32, 30usize);
    let mut times = vec![0.0];
    times.extend((0..moving).map(|i| 0.5 + i as f64 / 30.0));
    let duration = 3.5;
    let content = pattern(w, h + (moving as u32 + 2) * step + 100, 11);
    let src = out.join("video-vfr-quelle.mp4");
    media::write_test_video_vfr(&src, w, h, &times, duration, &mut |i| scrolling_frame(&content, w, h, i as u32 * step))?;
    let info = media::probe(&src)?;
    let average = times.len() as f64 / duration;
    println!("VFR-Quelle: {} Bilder in {duration} s (Durchschnitt {average:.1} fps), wirksam {:.1} fps", times.len(), info.fps);
    if info.fps < 24.0 {
        bail!("wirksame Bildrate der Quelle {:.1} fps statt ≈ 30", info.fps);
    }

    let bar = Rect::new(40.0, 80.0, 200.0, 60.0);
    let doc = VideoDocument { redactions: vec![VideoRedaction::new(bar, 0.0, duration, RedactStyle::Solid)], ..Default::default() };
    let dst = out.join("video-vfr-export.mp4");
    media::export_mp4(&src, &dst, &doc, 1.0, &mut |_| {}, &AtomicBool::new(false))?;
    let ex = media::probe(&dst)?;
    println!("VFR-Export: {:.1} fps, {:.2} s", ex.fps, ex.duration);
    if ex.fps < 24.0 {
        bail!("Export mit {:.1} fps — Bewegung ruckelt", ex.fps);
    }
    if (ex.duration - duration).abs() > 0.2 {
        bail!("Export-Dauer {:.2} s statt {duration} s", ex.duration);
    }

    // Bewegung erhalten: In der Bewegungsphase passt jedes Exportbild zum Quellbild seiner Zeit besser
    // als zu den Nachbarbildern (mit der alten Rate stand ein Bild ~3 Quellbilder lang).
    let mid = |i: usize| times[i] + 1.0 / 60.0;
    let mut sr = FrameReader::open(&src, Some(320))?;
    let mut er = FrameReader::open(&dst, Some(320))?;
    let mut source = Vec::new();
    for i in 0..=moving {
        source.push(sr.frame_at(mid(i))?.context("Quellbild fehlt")?);
    }
    let from_y = 40; // unter Kopf und Balken (320 px breit = ¼)
    let mut wrong = vec![];
    let mut worst: f64 = 0.0;
    for i in 2..moving {
        let e = er.frame_at(mid(i))?.context("Exportbild fehlt")?;
        let own = diff(&e, &source[i], from_y);
        worst = worst.max(own);
        if own >= diff(&e, &source[i - 1], from_y) || own >= diff(&e, &source[i + 1], from_y) {
            wrong.push(i);
        }
    }
    println!("Bewegung: {} von {} Bildern zeitrichtig, größte Abweichung zum eigenen Quellbild {worst:.1}", moving - 2 - wrong.len(), moving - 2);
    if !wrong.is_empty() {
        bail!("Exportbilder {wrong:?} zeigen ein falsches Quellbild (Bewegung verloren)");
    }
    Ok(())
}

/// Bewegt die Maus im Kreis, solange er lebt — erzeugt Bildänderungen für die Aufnahme (`record`).
pub struct MouseMover {
    run: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl MouseMover {
    pub fn start(m: &Monitor) -> Self {
        let run = Arc::new(AtomicBool::new(true));
        let flag = run.clone();
        let (cx, cy) = (m.rect.x + m.rect.width / 2, m.rect.y + m.rect.height / 2);
        let r = (m.rect.height / 4) as f64;
        let join = std::thread::spawn(move || {
            let t0 = Instant::now();
            while flag.load(Ordering::SeqCst) {
                let a = t0.elapsed().as_secs_f64() * 3.0;
                knips_platform::testinput::move_to(cx + (r * a.cos()) as i32, cy + (r * a.sin()) as i32);
                std::thread::sleep(Duration::from_millis(12));
            }
        });
        Self { run, join: Some(join) }
    }
}

impl Drop for MouseMover {
    fn drop(&mut self) {
        self.run.store(false, Ordering::SeqCst);
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

/// Aufnahme (variable Bildrate) exportieren: Ergebnis muss ≥ 24 fps haben.
pub fn check_recording_export(path: &Path) -> Result<()> {
    let info = media::probe(path)?;
    let doc = VideoDocument {
        redactions: vec![VideoRedaction::new(Rect::new(10.0, 10.0, 80.0, 40.0), 0.0, info.duration, RedactStyle::Solid)],
        ..Default::default()
    };
    let dst = path.with_extension("export.mp4");
    let r = media::export_mp4(path, &dst, &doc, 1.0, &mut |_| {}, &AtomicBool::new(false)).and_then(|_| media::probe(&dst));
    let _ = std::fs::remove_file(&dst);
    let ex = r?;
    println!("Export der Aufnahme: {:.1} fps (Aufnahme wirksam {:.1} fps), {:.2} s", ex.fps, info.fps, ex.duration);
    if ex.fps < 24.0 {
        bail!("Export der Aufnahme mit {:.1} fps — ruckelt", ex.fps);
    }
    Ok(())
}

// ------------------------------------------------------------------ nomedia

/// Wartet, bis `f` gilt (höchstens `secs` Sekunden).
fn wait_for(secs: u64, mut f: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if f() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    f()
}

/// Importtabelle der laufenden knips.exe: Media Foundation darf nur verzögert geladen werden.
fn check_imports() -> Result<()> {
    let exe = std::env::current_exe()?;
    let bytes = std::fs::read(&exe)?;
    let imports = match crate::pe::imports(&bytes) {
        Ok(i) => i,
        Err(e) if !cfg!(windows) => {
            println!("Importtabelle übersprungen (keine Windows-Datei: {e})");
            return Ok(());
        }
        Err(e) => bail!("Importtabelle nicht lesbar: {e}"),
    };
    println!("Importe ({}): {}", imports.normal.len(), imports.normal.join(", "));
    println!("Verzögert ({}): {}", imports.delayed.len(), imports.delayed.join(", "));
    for dll in ["mfplat.dll", "mfreadwrite.dll", "mf.dll"] {
        if imports.normal.iter().any(|d| d == dll) {
            bail!("{dll} wird beim Start geladen — Knips startet ohne Media Feature Pack nicht");
        }
        if !imports.delayed.iter().any(|d| d == dll) {
            bail!("{dll} fehlt in den verzögerten Importen");
        }
    }
    Ok(())
}

fn expect_hint<T>(what: &str, r: Result<T>) -> Result<()> {
    match r {
        Ok(_) => bail!("{what}: lief ohne Media Foundation durch"),
        Err(e) if format!("{e:#}").contains("Media Feature Pack") => {
            println!("   {what}: Hinweis ✓");
            Ok(())
        }
        Err(e) => bail!("{what}: anderer Fehler statt Hinweis: {e:#}"),
    }
}

pub fn nomedia(app: &AppHandle, out: &Path) -> Result<()> {
    let k = crate::app::knips();
    check_imports()?;
    if media::available() {
        bail!("Media Foundation trotz KNIPS_TEST_NO_MEDIA verfügbar");
    }
    if !wait_for(10, || !k.bootstrap().media_available) {
        bail!("Bootstrap meldet Media Foundation weiter als verfügbar");
    }
    if k.bootstrap().hevc_available || media::hevc_available() {
        bail!("HEVC ohne Media Foundation angeboten");
    }

    // Videofunktionen: Hinweis statt Absturz (der verzögerte Import würde den Prozess beenden).
    let tmp = crate::paths::temp_dir().join("nomedia.mp4");
    expect_hint("probe", media::probe(&tmp))?;
    expect_hint("thumbnail", media::thumbnail(&tmp, 200))?;
    expect_hint("FrameReader", FrameReader::open(&tmp, None))?;
    expect_hint("Testvideo schreiben", media::write_test_video(&tmp, 64, 64, 30, 2, false, &mut |_| RgbaImage::new(64, 64)))?;
    let doc = VideoDocument::default();
    expect_hint("MP4-Export", media::export_mp4(&tmp, &out.join("x.mp4"), &doc, 1.0, &mut |_| {}, &AtomicBool::new(false)))?;
    expect_hint("GIF-Export", media::export_gif(&tmp, &out.join("x.gif"), &doc, 1.0, 10, 320, &mut |_| {}, &AtomicBool::new(false)))?;
    let m = monitors::primary();
    let opts = media::RecordOptions {
        monitor: m.clone(),
        rect: IRect::new(0, 0, 320, 240),
        width: 320,
        height: 240,
        fps: 30,
        show_cursor: true,
        show_clicks: false,
        microphone: false,
        hevc: false,
        path: tmp.clone(),
    };
    expect_hint("Aufnahme", media::Recorder::start(opts, Box::new(|_| {})))?;
    if tmp.exists() {
        bail!("Aufnahme hat ohne Media Foundation eine Datei angelegt");
    }

    // Screenshots gehen weiter.
    let before = k.store.items().len();
    k.coordinator.capture_fullscreen();
    let items = k.store.items();
    let shot = items.first().filter(|_| items.len() == before + 1).context("Bildschirmfoto ohne Media Foundation fehlt")?;
    if shot.kind != CaptureKind::Image {
        bail!("neue Aufnahme ist kein Bild");
    }
    k.store.wait_until_written(shot.id);
    if !Path::new(&shot.file_path).exists() {
        bail!("Bildschirmfoto nicht gespeichert");
    }
    println!("Bildschirmfoto ohne Media Foundation: {}×{} ✓", shot.pixel_width, shot.pixel_height);

    // Oberfläche: Hinweis in den Einstellungen, gedämpfte Video-Kachel im Menü.
    crate::commands::show_settings(app, Some("recording".into()));
    std::thread::sleep(Duration::from_millis(1200));
    let settings = app.get_webview_window("settings").context("Einstellungen fehlen")?;
    let text = probe(&settings, "document.body.innerText.includes('Media Feature Pack') && !!document.querySelector('.k-notice')", Duration::from_secs(5))?;
    if text != "true" {
        bail!("Einstellungen zeigen keinen Hinweis auf das Media Feature Pack ({text})");
    }
    shoot(app, "settings", out, "einstellungen-aufnahme-ohne-media.png")?;
    let _ = settings.hide();
    crate::menu::show(app, Some((m.work.right() - 200, m.work.bottom() + 10)));
    std::thread::sleep(Duration::from_millis(1200));
    let menu = app.get_webview_window(crate::menu::LABEL).context("Menü fehlt")?;
    let off = probe(&menu, "!!document.querySelector('.menu-tile.off')", Duration::from_secs(5))?;
    if off != "true" {
        bail!("Video-Kachel im Menü nicht als nicht verfügbar markiert");
    }
    shoot(app, crate::menu::LABEL, out, "menu-ohne-media.png")?;
    crate::menu::close(app);

    // Video-Kürzel: Hinweis statt Auswahl-Overlay, keine Aufnahme (zuletzt — der Dialog bleibt offen).
    let hints = crate::recording::media_hints_shown();
    k.coordinator.toggle_recording();
    if knips_platform::overlay::is_active() {
        knips_platform::overlay::cancel();
        bail!("Auswahl-Overlay trotz fehlender Media Foundation geöffnet");
    }
    if crate::recording::media_hints_shown() != hints + 1 || k.recording.is_busy() {
        bail!("Video-Kürzel zeigt keinen Hinweis oder startet eine Aufnahme");
    }
    println!("Video-Kürzel: Hinweis „Media Feature Pack“ ✓");
    Ok(())
}

// ------------------------------------------------------------------ oldwin

pub fn oldwin(app: &AppHandle, _out: &Path) -> Result<()> {
    let k = crate::app::knips();
    if capture::exclusion_supported() {
        bail!("Ausschluss aus Aufnahmen trotz KNIPS_TEST_OLD_WINDOWS aktiv");
    }
    // Sichtbare eigene Fenster: Einblendung und Einstellungen.
    k.hud.show("Test", "check");
    crate::commands::show_settings(app, Some("general".into()));
    std::thread::sleep(Duration::from_millis(900));
    let visible = || -> Vec<String> {
        app.webview_windows().into_iter().filter(|(_, w)| w.is_visible().unwrap_or(false)).map(|(l, _)| l).collect()
    };
    let shown = visible();
    println!("sichtbar vor dem Standbild: {}", shown.join(", "));
    if !shown.iter().any(|l| l == "settings") {
        bail!("Einstellungen nicht sichtbar");
    }
    // Fenster sind dann verhüllt (DWMWA_CLOAK): für Aufnahmen und Bildschirm weg, aber nicht ausgeblendet
    // (kein Fokuswechsel, keine Animation).
    let capturable = || -> Vec<String> {
        app.webview_windows()
            .into_iter()
            .filter(|(_, w)| crate::wm::hwnd(w).is_some_and(capture::capturable))
            .map(|(l, _)| l)
            .collect()
    };
    let settings_rect = crate::selftest_capture::window_rect(app, "settings")?;
    let with_windows = capture::freeze(&monitors::list())?;
    let t = Instant::now();
    let conceal = crate::wm::conceal_for_still();
    let during = capturable();
    let still_visible = visible();
    let frozen = capture::freeze(&monitors::list());
    drop(conceal);
    let concealed_ms = t.elapsed().as_millis();
    std::thread::sleep(Duration::from_millis(300));
    let after = capturable();
    println!("während: aufnehmbar [{}], nicht ausgeblendet [{}] · danach aufnehmbar: [{}] · verhüllt für {concealed_ms} ms", during.join(", "), still_visible.join(", "), after.join(", "));
    let frozen = frozen?;
    if !during.is_empty() {
        bail!("eigene Fenster während des Standbilds aufnehmbar: {}", during.join(", "));
    }
    if !still_visible.iter().any(|l| l == "settings") {
        bail!("Einstellungen für das Standbild ausgeblendet statt verhüllt");
    }
    let missing: Vec<&String> = shown.iter().filter(|l| *l != crate::hud::LABEL && !after.contains(l)).collect();
    if !missing.is_empty() {
        bail!("nach dem Standbild nicht wieder sichtbar: {missing:?}");
    }
    // Inhalt: Das Standbild zeigt dort, wo die Einstellungen liegen, was dahinter ist (Vergleich mit einem
    // Standbild bei ausgeblendeten Einstellungen) — die obere Hälfte, weg von der Einblendung.
    let settings = app.get_webview_window("settings").context("Einstellungen fehlen")?;
    let _ = settings.hide();
    std::thread::sleep(Duration::from_millis(600));
    let truth = capture::freeze(&monitors::list())?;
    let _ = settings.show();
    std::thread::sleep(Duration::from_millis(600));
    let upper = IRect::new(settings_rect.x, settings_rect.y, settings_rect.width, settings_rect.height / 2);
    let (concealed_diff, visible_diff) = (crate::selftest_capture::still_diff(&frozen, &truth, upper), crate::selftest_capture::still_diff(&with_windows, &truth, upper));
    println!("Abweichung im Bereich der Einstellungen: verhüllt {concealed_diff:.1}, sichtbar {visible_diff:.1}");
    if !(concealed_diff <= 3.0 && visible_diff >= 10.0) {
        bail!("Standbild zeigt die verhüllten Einstellungen (Abweichung {concealed_diff:.1}, sichtbar {visible_diff:.1})");
    }
    // Ganzer Ablauf über den Koordinator und der Aufnahmerahmen (ohne Ausschluss) laufen fehlerfrei.
    let before = k.store.items().len();
    k.coordinator.capture_fullscreen();
    if k.store.items().len() != before + 1 {
        bail!("Bildschirmfoto fehlt");
    }
    if !visible().iter().any(|l| l == "settings") {
        bail!("Einstellungen nach dem Bildschirmfoto nicht wieder sichtbar");
    }
    let m = monitors::primary();
    let frame = knips_platform::overlay::FrameWindow::show(IRect::new(m.rect.x + 100, m.rect.y + 100, 400, 300), knips_platform::overlay::FrameColor::Recording)?;
    std::thread::sleep(Duration::from_millis(300));
    drop(frame);
    println!("Standbild ohne eigene Fenster, danach wieder sichtbar ✓");
    Ok(())
}
