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
use tauri::AppHandle;

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

fn bright(img: &RgbaImage, area: Option<IRect>) -> Brightness {
    imageops::brightness(img, area, 4)
}

fn show(b: Brightness) -> String {
    format!("Helligkeit {:.0}, schwarz {:.0} %", b.mean, b.black * 100.0)
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

    let t = Instant::now();
    let second = capture::freeze(std::slice::from_ref(&m))?.remove(0);
    let second_hits = pattern_hits(&second.image, local);
    println!("Zweites Standbild: {} ms, Testfläche {second_hits}/8 Farbbalken, {}", t.elapsed().as_millis(), show(bright(&second.image, Some(local))));
    for n in capture::freeze_notes() {
        println!("   {n}");
    }
    if first_hits < 7 {
        bail!("erstes Standbild im Prozess zeigt die Testfläche nicht ({first_hits}/8 Farbbalken, zweites {second_hits}/8)");
    }
    if second_hits < 7 {
        bail!("zweites Standbild zeigt die Testfläche nicht ({second_hits}/8 Farbbalken)");
    }
    Ok(())
}

fn run_raw_child(out: &Path) -> Result<bool> {
    let dir = out.join("roh");
    std::fs::create_dir_all(&dir)?;
    let output = std::process::Command::new(std::env::current_exe()?)
        .args(["--selftest", "firstshot-roh"])
        .arg(&dir)
        .stderr(std::process::Stdio::null())
        .output()?;
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        println!("   [ohne App] {line}");
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
    // 1. Ohne App, im frischen Kindprozess
    match run_raw_child(out) {
        Ok(true) => println!("   ok     erstes Standbild ohne App zeigt die Testfläche"),
        Ok(false) => failures.push("erstes Standbild ohne App (Kindprozess)".into()),
        Err(err) => failures.push(format!("Kindprozess: {err:#}")),
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
