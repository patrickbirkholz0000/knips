//! Selbsttests wie `SelfTest.swift`: `knips --selftest <test> <ordner>`, nur in Entwickler-Builds
//! (Feature `dev`). Läuft isoliert in `<ordner>\sandbox` (Ablage, Originale, Einstellungen) und
//! fasst die echte Zwischenablage nie an.
//!
//! Ohne Fenster: detect, output, selection, capture, record [s], track, video, perf, hotkeys
//! (simulierte Tastendrücke), clipboard (echte Zwischenablage, nur für die CI), telemetry
//! (Nutzungsstatistik gegen einen lokalen Server auf 127.0.0.1).
//! Mit Fenstern (startet die App unsichtbar für den Nutzer, fotografiert nur eigene Fenster): ui, render,
//! links (Rückfrage vor knips://-Aufnahmen; Aufnahmen sind durch eine Liste ersetzt, nimmt nie auf),
//! nomedia (Windows N/KN ohne Media Feature Pack) und oldwin (Windows vor 10 2004) — `selftest_media.rs`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use knips_core::geometry::{IRect, Rect};
use knips_core::links::Immediate;
use knips_core::model::{Annotation, AnnotationKind, ImageDocument, ImageFormat, RedactStyle, SensitiveKind, VideoDocument, VideoRedaction};
use knips_core::settings::HotkeyAction;
use knips_core::{imageops, sensitive, textlayout, tracker, videodetect, RgbaImage};
use knips_platform::media::{self, FrameReader};
use knips_platform::overlay::{self, Purpose};
use knips_platform::{capture, monitors, ocr, sample, Frozen, Monitor, WindowInfo};
use serde::Deserialize;
use tauri::{AppHandle, Manager, WebviewWindow};

use crate::promise::output_promise;
use crate::settings::SettingsStore;
use crate::store::Store;
use crate::wm;

const WINDOW_TESTS: [&str; 5] = ["ui", "render", "links", "nomedia", "oldwin"];

/// `Some(code)`: Test ist durch. `None`: Fenstertest — die App startet normal und
/// `after_setup` übernimmt.
pub fn run(args: &[String]) -> Option<i32> {
    let (Some(test), Some(dir)) = (args.first(), args.get(1)) else {
        eprintln!("Aufruf: knips --selftest <test> <ordner>");
        return Some(2);
    };
    let out = PathBuf::from(dir);
    let _ = std::fs::create_dir_all(&out);
    std::env::set_var("KNIPS_TEST_DIR", out.join("sandbox"));
    knips_platform::clipboard::set_disabled(true);
    if WINDOW_TESTS.contains(&test.as_str()) {
        std::env::set_var("KNIPS_SELFTEST", format!("{test}|{}", out.display()));
        // Simulationen vor dem App-Start setzen (die Werte werden einmal pro Prozess gemerkt).
        match test.as_str() {
            "nomedia" => std::env::set_var("KNIPS_TEST_NO_MEDIA", "1"),
            "oldwin" => std::env::set_var("KNIPS_TEST_OLD_WINDOWS", "1"),
            _ => {}
        }
        return None;
    }
    let result = match test.as_str() {
        "detect" => detect(&out),
        "output" => output(&out),
        "selection" => selection(&out),
        "capture" => capture_test(),
        "record" => record(args.get(2).and_then(|s| s.parse().ok()).unwrap_or(3.0)),
        "track" => track(&out),
        "video" => video(&out),
        "perf" => perf(),
        "hotkeys" => hotkeys_test(),
        "overlay" => overlay_test(),
        "clipboard" => clipboard_test(),
        "telemetry" => telemetry_test(&out),
        other => {
            eprintln!("Unbekannter Test: {other}");
            return Some(2);
        }
    };
    Some(match result {
        Ok(()) => {
            println!("OK");
            0
        }
        Err(err) => {
            println!("FEHLER: {err:#}");
            1
        }
    })
}

fn write(image: &RgbaImage, path: &Path) -> Result<()> {
    std::fs::write(path, imageops::encode(image, ImageFormat::Png)?)?;
    println!("→ {} ({}×{})", path.display(), image.width(), image.height());
    Ok(())
}

fn all_kinds() -> BTreeSet<SensitiveKind> {
    SensitiveKind::ALL.into_iter().collect()
}

/// Rechteck-Umriss (für Fund-Bilder).
fn outline(img: &mut RgbaImage, r: &Rect, color: [u8; 4]) {
    let (w, h) = (img.width() as i64, img.height() as i64);
    let (x0, y0, x1, y1) = (r.x as i64, r.y as i64, r.max_x() as i64, r.max_y() as i64);
    for t in 0..3 {
        for x in x0..=x1 {
            for y in [y0 - t, y1 + t] {
                if x >= 0 && x < w && y >= 0 && y < h {
                    img.put_pixel(x as u32, y as u32, image::Rgba(color));
                }
            }
        }
        for y in y0..=y1 {
            for x in [x0 - t, x1 + t] {
                if x >= 0 && x < w && y >= 0 && y < h {
                    img.put_pixel(x as u32, y as u32, image::Rgba(color));
                }
            }
        }
    }
}

// ------------------------------------------------------------------ detect

fn detect(out: &Path) -> Result<()> {
    let img = sample::sample_image(1400, 880, 2.0);
    write(&img, &out.join("detect-original.png"))?;
    if !ocr::available() {
        bail!("Texterkennung (Windows.Media.Ocr) nicht verfügbar — Sprachpaket fehlt?");
    }
    let t = Instant::now();
    let lines = ocr::recognize(&img)?;
    println!("Texterkennung: {} Zeilen in {} ms", lines.len(), t.elapsed().as_millis());
    for l in &lines {
        println!("   | {}", l.text);
    }
    let findings = sensitive::detect(&lines, &all_kinds());
    let mut marked = img.clone();
    for f in &findings {
        println!("   Fund {:?}: {} @ {:.0},{:.0} {:.0}×{:.0}", f.kind, f.text, f.rect.x, f.rect.y, f.rect.width, f.rect.height);
        outline(&mut marked, &f.rect, [255, 40, 40, 255]);
    }
    write(&marked, &out.join("detect-funde.png"))?;
    ocr_variants(&img, &lines);
    let kinds: BTreeSet<_> = findings.iter().map(|f| f.kind).collect();
    for want in [SensitiveKind::Email, SensitiveKind::Iban, SensitiveKind::Phone, SensitiveKind::Secret] {
        if !kinds.contains(&want) {
            bail!("{want:?} nicht gefunden");
        }
    }
    // Der ganze Schlüssel muss verdeckt sein — auch wenn die Texterkennung seinen Anfang verliert (dann
    // hängt der Fund am Bezeichner „Stripe-Key:“): vom ersten Wort nach dem Bezeichner bis zum Zeilenende.
    let line = lines.iter().find(|l| l.text.contains("Stripe")).context("Zeile mit dem Stripe-Key fehlt")?;
    let label = line.words.iter().position(|w| w.text.ends_with(':')).unwrap_or(0);
    let key_start = line.words.get(label + 1).map(|w| w.rect.x).unwrap_or(line.rect.x);
    let covered = findings
        .iter()
        .any(|f| f.kind == SensitiveKind::Secret && f.rect.x <= key_start + 1.0 && f.rect.max_x() >= line.rect.max_x() - 2.0);
    if !covered {
        bail!("Stripe-Key nicht vollständig verdeckt");
    }
    // Muster ohne Texterkennung (wie `SelfTest.detect` auf dem Mac): erfundener Schlüssel und E-Mail.
    let kinds_of = |s: &str| sensitive::matches(s, &all_kinds()).into_iter().map(|m| m.0).collect::<Vec<_>>();
    if kinds_of(sample::STRIPE_KEY) != [SensitiveKind::Secret] {
        bail!("Muster: Stripe-Key „{}“ nicht erkannt", sample::STRIPE_KEY);
    }
    if kinds_of("kontakt@example.com") != [SensitiveKind::Email] {
        bail!("Muster: E-Mail nicht erkannt");
    }
    println!("   ✓ Stripe-Key „{}“ verdeckt, Muster für Schlüssel und E-Mail greifen", sample::STRIPE_KEY);
    Ok(())
}

/// Diagnose: liest die Windows-Texterkennung die Schlüssel-Zeile vergrößert vollständiger?
fn ocr_variants(img: &RgbaImage, lines: &[knips_core::model::TextLine]) {
    let Some(line) = lines.iter().find(|l| l.text.contains("Stripe")) else { return };
    let r = line.rect.inset(-12.0, -8.0).integral();
    let Some(cut) = imageops::crop(img, IRect::new(r.x as i32, r.y as i32, r.width as i32, r.height as i32)) else { return };
    for factor in [1u32, 2, 3] {
        let big = image::imageops::resize(&cut, cut.width() * factor, cut.height() * factor, image::imageops::FilterType::CatmullRom);
        let text = ocr::recognize(&big).map(|ls| ls.iter().map(|l| l.text.clone()).collect::<Vec<_>>().join(" / ")).unwrap_or_else(|e| format!("Fehler: {e:#}"));
        println!("   Zeile {factor}×: {text}");
    }
}

// ------------------------------------------------------------------ output

fn describe(path: &Path) -> String {
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let dims = imageops::load(path).map(|i| format!("{}×{}", i.width(), i.height())).unwrap_or_else(|_| "?".into());
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_uppercase();
    format!("{ext} {dims}, {} KB", size / 1024)
}

fn output(out: &Path) -> Result<()> {
    let settings = Arc::new(SettingsStore::load());
    let store = Arc::new(Store::new(settings.clone()));
    // „Retina“-Screenshot: 2 px pro Punkt, Schrift in 4 px pro Punkt gezeichnet wie auf dem Mac.
    let image = sample::sample_image(2800, 1760, 4.0);
    let mut failures = vec![];
    for format in [ImageFormat::Png, ImageFormat::Jpeg] {
        settings.update(|s| s.image_format = format);
        let factor = settings.get().output_factor(2.0);
        let src = image.clone();
        let promise = output_promise(factor, format, move || Some(src));
        let item = store.add_image(image.clone(), 2.0, Some(promise), None)?;
        store.wait_until_written(item.id);
        let file = PathBuf::from(&item.file_path);
        println!("{format:?}: Ablage {} · Original {} · Anzeige-Faktor {}", describe(&file), describe(&store.original_path(&item)), item.display_scale());
        let saved = imageops::load(&file)?;
        if (saved.width(), saved.height()) != (1400, 880) {
            failures.push(format!("{format:?}: {}×{} statt 1400×880", saved.width(), saved.height()));
        }
    }
    settings.update(|s| s.image_format = ImageFormat::Png);

    // Editor-Weg: Zensur über die E-Mail, Speichern verkleinert (1×), Text kopieren ohne E-Mail.
    let item = store.add_image(image.clone(), 2.0, None, None)?;
    store.wait_until_written(item.id);
    let mut bar = Annotation::new(AnnotationKind::Redact, knips_core::geometry::Point::new(760.0, 470.0), knips_core::geometry::Point::new(2000.0, 570.0));
    bar.redact_style = RedactStyle::Solid;
    let doc = ImageDocument { annotations: vec![bar.clone()], ..Default::default() };
    let mut rendered = image.clone();
    knips_core::redact::apply(&mut rendered, &[(bar.rect(), RedactStyle::Solid)], 2.0);
    let factor = settings.get().output_factor(2.0);
    let size = ((rendered.width() as f64 * factor).round() as u32, (rendered.height() as f64 * factor).round() as u32);
    let promise = output_promise(factor, ImageFormat::Png, move || Some(rendered));
    let saved = store.save_image(promise, &doc, &item, size, 2.0 * factor);
    store.wait_until_written(item.id);
    let file = PathBuf::from(&saved.file_path);
    println!("Editor gespeichert: {} · Dokument {} Balken", describe(&file), store.load_image_document(item.id).annotations.len());
    let img = imageops::load(&file)?;
    write(&img, &out.join("ausgabe-editor.png"))?;
    if ocr::available() {
        let text = textlayout::plain_text(&ocr::recognize(&img)?, &[]);
        println!("Text kopieren (Karte):\n{}", text.lines().map(|l| format!("     | {l}")).collect::<Vec<_>>().join("\n"));
        if text.contains('@') {
            failures.push("E-Mail trotz Balken im Text".into());
        } else {
            println!("   ✓ keine E-Mail im kopierten Text");
        }
    }
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}

// ------------------------------------------------------------------ selection

fn selection(out: &Path) -> Result<()> {
    let monitor = Monitor {
        id: 1,
        name: "TEST".into(),
        rect: IRect::new(0, 0, 2560, 1600),
        work: IRect::new(0, 0, 2560, 1552),
        scale: 2.0,
        primary: true,
    };
    let frozen = Frozen { image: sample::sample_image(2560, 1600, 2.0), monitor };
    let windows = vec![WindowInfo { hwnd: 1, rect: IRect::new(840, 600, 1400, 840), title: "Fenster".into(), owner: "test.exe".into() }];
    let bereich = overlay::render_offscreen(&frozen, &windows, Purpose::Screenshot, false, (1400, 1040), Some(IRect::new(600, 760, 1280, 600)))?;
    write(&bereich, &out.join("ui-auswahl-bereich.png"))?;
    let fenster = overlay::render_offscreen(&frozen, &windows, Purpose::Screenshot, true, (1400, 1040), None)?;
    write(&fenster, &out.join("ui-auswahl-fenster.png"))?;
    let text = overlay::render_offscreen(&frozen, &windows, Purpose::Recording, false, (300, 300), None)?;
    write(&text, &out.join("ui-auswahl-aufnahme.png"))?;
    Ok(())
}

// ------------------------------------------------------------------ capture / record / perf

fn capture_test() -> Result<()> {
    let list = monitors::list();
    for m in &list {
        println!("Bildschirm {}: {}×{} px bei ({}, {}), Faktor {}, Arbeitsbereich {}×{}{}", m.name, m.rect.width, m.rect.height, m.rect.x, m.rect.y, m.scale, m.work.width, m.work.height, if m.primary { " (primär)" } else { "" });
    }
    let t = Instant::now();
    let frozen = capture::freeze(&list)?;
    println!("Standbild aller Bildschirme: {} ms", t.elapsed().as_millis());
    for f in &frozen {
        println!("   {}: {}×{} px", f.monitor.name, f.image.width(), f.image.height());
        if (f.image.width() as i32, f.image.height() as i32) != (f.monitor.rect.width, f.monitor.rect.height) {
            bail!("Standbild {} hat falsche Größe", f.monitor.name);
        }
    }
    let windows = capture::windows();
    println!("Fenster erkannt: {}", windows.len());
    for w in windows.iter().take(8) {
        println!("   {} — {} ({}×{})", w.owner, w.title, w.rect.width, w.rect.height);
    }
    if let Some(w) = windows.first() {
        match capture::window_image(w) {
            Ok(img) => println!("Fensteraufnahme {}: {}×{}", w.owner, img.width(), img.height()),
            Err(err) => println!("Fensteraufnahme {} fehlgeschlagen: {err:#}", w.owner),
        }
    }
    let m = monitors::primary();
    let mut region = capture::RegionCapturer::new(&m, IRect::new(0, 0, m.rect.width / 2, m.rect.height / 2))?;
    let t = Instant::now();
    for _ in 0..3 {
        let img = region.grab()?;
        if img.width() as i32 != m.rect.width / 2 {
            bail!("Bereichsaufnahme hat falsche Breite");
        }
    }
    println!("Bereichsaufnahme: 3 Bilder in {} ms", t.elapsed().as_millis());
    Ok(())
}

fn record(seconds: f64) -> Result<()> {
    let m = monitors::primary();
    let even = |v: f64| ((v / 2.0).floor() * 2.0).max(2.0) as u32;
    let (w, h) = (even(m.rect.width as f64 / m.scale), even(m.rect.height as f64 / m.scale));
    let path = std::env::temp_dir().join(format!("knips-selftest-{}.mp4", std::process::id()));
    let opts = media::RecordOptions {
        monitor: m.clone(),
        rect: IRect::new(0, 0, m.rect.width, m.rect.height),
        width: w,
        height: h,
        fps: 30,
        show_cursor: true,
        show_clicks: true,
        microphone: false,
        hevc: false,
        path: path.clone(),
    };
    let t = Instant::now();
    let recorder = media::Recorder::start(opts, Box::new(|e| eprintln!("Aufnahmefehler: {e}")))?;
    println!("Start: {} ms", t.elapsed().as_millis());
    // Maus kreisen lassen: Bildänderungen wie bei echter Nutzung (variable Bildrate).
    let mover = crate::selftest_media::MouseMover::start(&m);
    std::thread::sleep(Duration::from_secs_f64(seconds));
    drop(mover);
    let t = Instant::now();
    let duration = recorder.stop()?;
    println!("Stopp: {} ms, Dauer laut Recorder {duration:.2} s", t.elapsed().as_millis());
    let info = media::probe(&path)?;
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    println!("Datei: {}×{}, {:.2} s, wirksam {:.1} fps, {} KB", info.width, info.height, info.duration, info.fps, size / 1024);
    let exported = crate::selftest_media::check_recording_export(&path);
    let _ = std::fs::remove_file(&path);
    exported?;
    if (info.duration - seconds).abs() > 0.6 {
        bail!("Dauer {:.2} s statt {seconds} s", info.duration);
    }
    if (info.width, info.height) != (w, h) {
        bail!("Größe {}×{} statt {w}×{h}", info.width, info.height);
    }
    Ok(())
}

fn perf() -> Result<()> {
    let list = monitors::list();
    for i in 0..3 {
        let t = Instant::now();
        let frozen = capture::freeze(&list)?;
        println!("Standbild #{}: {} ms", i + 1, t.elapsed().as_millis());
        if i == 2 {
            let img = &frozen[0].image;
            let t = Instant::now();
            let small = imageops::scaled(img, 1.0 / frozen[0].monitor.scale);
            let png = imageops::encode(&small, ImageFormat::Png)?;
            println!("1× + PNG: {} ms ({} KB)", t.elapsed().as_millis(), png.len() / 1024);
            let t = Instant::now();
            let full = imageops::encode(img, ImageFormat::Png)?;
            println!("Volle Auflösung PNG: {} ms ({} KB)", t.elapsed().as_millis(), full.len() / 1024);
            if ocr::available() {
                let t = Instant::now();
                let lines = ocr::recognize(img)?;
                println!("Texterkennung (≤ 2048 px): {} ms, {} Zeilen", t.elapsed().as_millis(), lines.len());
            }
        }
    }
    Ok(())
}

// ------------------------------------------------------------------ overlay (interaktiv)

/// Das echte Auswahl-Overlay mit simulierter Maus und Tastatur: Ziehen, Umschalt-Quadrat, Esc,
/// Eingabe, Leertaste + Fensterklick. Nur auf einem Rechner ohne Nutzer (CI) laufen lassen.
fn overlay_test() -> Result<()> {
    use knips_platform::overlay::Selection;
    use knips_platform::testinput;
    let m = monitors::primary();
    let (ox, oy) = (m.rect.x, m.rect.y);
    let run = |window_mode: bool, act: &dyn Fn()| -> Result<Selection> {
        let frozen = capture::freeze(&monitors::list())?;
        let windows = capture::windows();
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = parking_lot::Mutex::new(tx);
        overlay::present(frozen, windows, Purpose::Screenshot, window_mode, Box::new(move |sel| {
            let _ = tx.lock().send(sel);
        }))?;
        std::thread::sleep(Duration::from_millis(900));
        act();
        let sel = rx.recv_timeout(Duration::from_secs(6)).context("Overlay hat nicht geantwortet")?;
        std::thread::sleep(Duration::from_millis(300));
        if overlay::is_active() {
            bail!("Overlay meldet sich nach dem Ende noch aktiv");
        }
        Ok(sel)
    };
    let mut failures = vec![];
    let describe = |s: &Selection| match s {
        Selection::Area { rect, .. } => format!("Bereich {}×{} bei {},{}", rect.width, rect.height, rect.x, rect.y),
        Selection::Window { window, .. } => format!("Fenster {} ({})", window.owner, window.title),
        Selection::FullScreen { monitor } => format!("ganzer Bildschirm {}", monitor.name),
        Selection::Cancelled => "abgebrochen".into(),
    };

    // 1. Bereich ziehen
    let sel = run(false, &|| testinput::drag((ox + 200, oy + 200), (ox + 600, oy + 500), false))?;
    println!("Ziehen: {}", describe(&sel));
    match sel {
        Selection::Area { rect, .. } if (rect.x - 200).abs() <= 2 && (rect.y - 200).abs() <= 2 && (rect.width - 400).abs() <= 3 && (rect.height - 300).abs() <= 3 => {}
        _ => failures.push("Ziehen ergab nicht 400×300 bei 200,200".to_string()),
    }
    // 2. Umschalt = Quadrat
    let sel = run(false, &|| testinput::drag((ox + 150, oy + 150), (ox + 550, oy + 350), true))?;
    println!("Umschalt-Ziehen: {}", describe(&sel));
    if !matches!(sel, Selection::Area { rect, .. } if rect.width == rect.height) {
        failures.push("Umschalt-Ziehen ergab kein Quadrat".into());
    }
    // 3. Esc bricht ab
    let sel = run(false, &|| testinput::key(0x1B, 0))?;
    println!("Esc: {}", describe(&sel));
    if !matches!(sel, Selection::Cancelled) {
        failures.push("Esc hat nicht abgebrochen".into());
    }
    // 4. Eingabe = ganzer Bildschirm (Maus auf dem Hauptbildschirm)
    let sel = run(false, &|| {
        testinput::move_to(ox + 300, oy + 300);
        std::thread::sleep(Duration::from_millis(150));
        testinput::key(0x0D, 0);
    })?;
    println!("Eingabe: {}", describe(&sel));
    if !matches!(sel, Selection::FullScreen { .. }) {
        failures.push("Eingabe ergab nicht den ganzen Bildschirm".into());
    }
    // 5. Leertaste → Fenstermodus, Klick auf ein Fenster
    if let Some(target) = capture::windows().into_iter().find(|w| m.rect.contains(w.rect.x + w.rect.width / 2, w.rect.y + w.rect.height / 2)) {
        let (cx, cy) = (target.rect.x + target.rect.width / 2, target.rect.y + target.rect.height / 2);
        let sel = run(false, &|| {
            testinput::move_to(cx, cy);
            std::thread::sleep(Duration::from_millis(150));
            testinput::key(0x20, 0);
            std::thread::sleep(Duration::from_millis(250));
            testinput::click(cx, cy);
        })?;
        println!("Leertaste + Klick: {} (erwartet {})", describe(&sel), target.owner);
        if !matches!(sel, Selection::Window { .. }) {
            failures.push("Fenstermodus lieferte kein Fenster".into());
        }
    } else {
        println!("Kein fremdes Fenster auf dem Hauptbildschirm — Fenstermodus übersprungen");
    }
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}

// ------------------------------------------------------------------ hotkeys / clipboard

/// Kürzel über beide Wege: `RegisterHotKey` (Strg+Alt+F9, Alt+Druck) und Tastatur-Hook (Win+Umschalt+4,
/// Druck solange Windows ihn dem Bildschirmausschnitt gibt). Tasten werden simuliert wie von der Tastatur.
fn hotkeys_test() -> Result<()> {
    use knips_core::settings::{KeyCombo, MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, VK_SNAPSHOT};
    use knips_platform::hotkeys;
    let (tx, rx) = std::sync::mpsc::channel::<u32>();
    let tx = parking_lot::Mutex::new(tx);
    hotkeys::start(Box::new(move |id| {
        let _ = tx.lock().send(id);
    }));
    std::thread::sleep(Duration::from_millis(300));
    println!("Druck-Taste beim Bildschirmausschnitt: {}", hotkeys::snipping_key_enabled());
    let bindings = [
        (1, KeyCombo::new(0x78, MOD_CONTROL | MOD_ALT)),
        (2, KeyCombo::new(0x34, MOD_WIN | MOD_SHIFT)),
        (3, KeyCombo::new(VK_SNAPSHOT, MOD_ALT)),
        (4, KeyCombo::new(VK_SNAPSHOT, MOD_SHIFT)),
    ];
    let failed = hotkeys::apply(&bindings);
    println!("Nicht registrierbar: {failed:?}");
    let mut missing = vec![];
    for (id, combo) in bindings {
        while rx.try_recv().is_ok() {}
        hotkeys::simulate(combo);
        match rx.recv_timeout(Duration::from_millis(1500)) {
            Ok(got) if got == id => println!("   ok     {}", combo.display()),
            Ok(got) => {
                println!("   FALSCH {}: Kennung {got}", combo.display());
                missing.push(combo.display());
            }
            Err(_) => {
                println!("   FALSCH {}: nichts ausgelöst", combo.display());
                missing.push(combo.display());
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    // Abgeschaltet: darf nicht mehr auslösen.
    hotkeys::apply(&[]);
    while rx.try_recv().is_ok() {}
    hotkeys::simulate(bindings[0].1);
    if rx.recv_timeout(Duration::from_millis(800)).is_ok() {
        missing.push("nach dem Abmelden ausgelöst".into());
    }
    if !missing.is_empty() {
        bail!("Kürzel: {}", missing.join(", "));
    }
    Ok(())
}

/// Echte Zwischenablage (nur auf dem CI-Rechner sinnvoll): Bild verzögert anbieten und zurücklesen.
fn clipboard_test() -> Result<()> {
    use knips_platform::clipboard;
    clipboard::set_disabled(false);
    let mut failures = vec![];
    for format in [ImageFormat::Png, ImageFormat::Jpeg] {
        let img = sample::sample_image(800, 500, 1.0);
        clipboard::set_image(Arc::new(crate::promise::ImagePromise::of(img.clone(), format)))?;
        std::thread::sleep(Duration::from_millis(300));
        match clipboard::get_image() {
            Some(back) if (back.width(), back.height()) == (800, 500) => {
                let (a, b) = (img.get_pixel(400, 300).0, back.get_pixel(400, 300).0);
                let diff: i32 = (0..3).map(|i| (a[i] as i32 - b[i] as i32).abs()).sum();
                println!("   {format:?}: {}×{} zurückgelesen, Farbabweichung {diff}", back.width(), back.height());
                if diff > 30 {
                    failures.push(format!("{format:?}: Farben weichen ab"));
                }
            }
            Some(back) => failures.push(format!("{format:?}: {}×{} statt 800×500", back.width(), back.height())),
            None => failures.push(format!("{format:?}: kein Bild in der Zwischenablage")),
        }
    }
    clipboard::set_text("Knips Selbsttest äöü")?;
    clipboard::set_files(&[std::env::temp_dir()])?;
    clipboard::set_disabled(true);
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}

// ------------------------------------------------------------------ telemetry

/// Lokaler HTTP-Server für den Telemetrie-Test: nimmt Anfragen an, merkt sie sich und antwortet
/// mit dem eingestellten Status.
struct PingServer {
    port: u16,
    status: Arc<std::sync::atomic::AtomicU16>,
    requests: Arc<parking_lot::Mutex<Vec<PingRequest>>>,
}

#[derive(Clone)]
struct PingRequest {
    line: String,
    content_type: String,
    body: Vec<u8>,
}

impl PingServer {
    fn start() -> Result<Self> {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        let port = listener.local_addr()?.port();
        let status = Arc::new(std::sync::atomic::AtomicU16::new(204));
        let requests = Arc::new(parking_lot::Mutex::new(vec![]));
        let (st, reqs) = (status.clone(), requests.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                let (mut length, mut content_type) = (0usize, String::new());
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                        break;
                    }
                    if let Some((name, value)) = header.split_once(':') {
                        match name.trim().to_ascii_lowercase().as_str() {
                            "content-length" => length = value.trim().parse().unwrap_or(0),
                            "content-type" => content_type = value.trim().to_string(),
                            _ => {}
                        }
                    }
                }
                let mut body = vec![0u8; length.min(1 << 20)];
                let _ = reader.read_exact(&mut body);
                reqs.lock().push(PingRequest { line: line.trim().to_string(), content_type, body });
                let code = st.load(std::sync::atomic::Ordering::SeqCst);
                let reason = if code < 300 { "No Content" } else { "Error" };
                let mut w = &stream;
                let _ = write!(w, "HTTP/1.1 {code} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                let _ = w.flush();
            }
        });
        Ok(Self { port, status, requests })
    }

    fn set_status(&self, code: u16) {
        self.status.store(code, std::sync::atomic::Ordering::SeqCst);
    }
    fn count(&self) -> usize {
        self.requests.lock().len()
    }
    fn last(&self) -> Option<PingRequest> {
        self.requests.lock().last().cloned()
    }
}

/// Nutzungsstatistik: nie in Sandbox/CI, ohne Zustimmung nichts, Zustimmung → Ereignisse → Senden an
/// einen lokalen Server (Nutzlast und Erlaubt-Liste prüfen) → Zähler zurückgesetzt → Fehler behält
/// Zähler → Widerruf löscht Kennung und Zähler.
fn telemetry_test(out: &Path) -> Result<()> {
    use crate::telemetry::{client_info, Config, Outcome, Telemetry};
    use knips_core::telemetry::{self as tm, Channel};
    let mut failures: Vec<String> = vec![];
    let mut expect = |ok: bool, what: &str| {
        if ok {
            println!("   ✓ {what}");
        } else {
            println!("   FALSCH {what}");
            failures.push(what.to_string());
        }
    };
    let settings = Arc::new(SettingsStore::load());

    // 1. Diese Sitzung (Selbsttest, Sandbox, ggf. CI) zählt, fragt und sendet nie.
    let real = Telemetry::from_env(settings.clone(), "0.1.0");
    expect(!real.enabled(), "Selbsttest/Sandbox: Statistik aus");
    expect(!real.should_ask(), "Selbsttest/Sandbox: keine Frage nach Zustimmung");
    expect(real.check() == Outcome::Off, "Selbsttest/Sandbox: kein Senden");
    let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
    expect(tm::gate(false, false, env(&[("CI", "true")])).is_none(), "CI: kein Senden");
    expect(tm::gate(false, false, env(&[("GITHUB_ACTIONS", "true")])).is_none(), "GitHub Actions: kein Senden");
    expect(tm::gate(false, true, env(&[])).is_none(), "Entwickler-Build ohne KNIPS_TELEMETRY: kein Senden");
    expect(tm::gate(false, true, env(&[("KNIPS_TELEMETRY", "1")])) == Some(Channel::Dev), "Entwickler-Build mit KNIPS_TELEMETRY=1: Kanal dev");
    expect(tm::gate(false, false, env(&[])) == Some(Channel::Release), "Weitergabe-Build: Kanal release");

    // 2. Lokaler Server, Statistik mit festem Ziel (Kanal dev).
    let server = PingServer::start()?;
    let info = client_info(Channel::Dev, "0.1.0");
    println!("System: {} · {} · Sprache „{}“", info.os_version, info.arch, info.lang);
    let config = Config { endpoint: format!("http://127.0.0.1:{}/v1/ping", server.port), info: info.clone() };
    let t = Telemetry::new(settings.clone(), Some(config));
    let now = chrono::Utc::now().timestamp();

    // 3. Ohne Zustimmung: nichts zählen, nichts senden; einmal pro Start fragen.
    t.count("capture_area");
    expect(settings.telemetry().telemetry_counts.is_empty(), "ohne Zustimmung wird nicht gezählt");
    expect(t.check_at(now) == Outcome::NoConsent && server.count() == 0, "ohne Zustimmung wird nichts gesendet");
    expect(t.should_ask() && !t.should_ask(), "fragt beim Start genau einmal");

    // 4. Zustimmung → Kennung, Ereignisse zählen (unbekannte verwerfen, Obergrenze).
    t.set_consent(true);
    let id = settings.telemetry().telemetry_install_id.unwrap_or_default();
    expect(tm::is_uuid_v4(&id), "Zustimmung legt eine zufällige UUID v4 an");
    for _ in 0..3 {
        t.count("capture_area");
    }
    t.count("editor_open");
    t.count("editor_open");
    t.count("app_launch");
    t.count("window_title");
    t.count("C:\\Users\\geheim.png");
    for _ in 0..(tm::MAX_COUNT + 5) {
        t.count("export_gif");
    }
    let counts = settings.telemetry().telemetry_counts;
    expect(counts.keys().all(|k| tm::is_allowed(k)), "nur Ereignisse aus der Erlaubt-Liste");
    expect(counts.get("export_gif") == Some(&tm::MAX_COUNT), "Zähler bei 10000 gedeckelt");

    // 5. Senden.
    let result = t.check_at(now);
    expect(result == Outcome::Sent(204), &format!("Senden an den lokalen Server ({result:?})"));
    let req = server.last().context("keine Anfrage angekommen")?;
    std::fs::write(out.join("telemetry-payload.json"), &req.body)?;
    println!("   Nutzlast ({} Bytes): {}", req.body.len(), String::from_utf8_lossy(&req.body));
    expect(req.line == "POST /v1/ping HTTP/1.1", &format!("POST /v1/ping ({})", req.line));
    expect(req.content_type == "application/json", "Content-Type application/json");
    expect(req.body.len() <= tm::MAX_BODY, "Körper ≤ 4 KB");
    let v: serde_json::Value = serde_json::from_slice(&req.body).context("Nutzlast ist kein JSON")?;
    let mut keys: Vec<&str> = v.as_object().map(|o| o.keys().map(String::as_str).collect()).unwrap_or_default();
    keys.sort();
    let mut want = vec!["v", "app", "platform", "channel", "app_version", "build", "os_version", "arch", "lang", "install_id", "events"];
    want.sort();
    expect(keys == want, &format!("genau die Felder des Vertrags ({keys:?})"));
    expect(v["v"] == 1 && v["app"] == "knips" && v["platform"] == "windows" && v["channel"] == "dev", "v/app/platform/channel");
    expect(v["install_id"] == id.as_str(), "install_id = Kennung aus der Zustimmung");
    expect(v["arch"] == "x86_64" || v["arch"] == "arm64", "arch");
    let os_ok = v["os_version"].as_str().map(|s| s.split('.').count() == 3 && s.split('.').all(|p| p.parse::<u32>().is_ok())).unwrap_or(false);
    expect(os_ok, "os_version wie 10.0.26100");
    expect(v["lang"].as_str().map(|l| l.is_empty() || l.len() == 2).unwrap_or(false), "lang mit 2 Buchstaben");
    let events = serde_json::json!({ "app_launch": 1, "capture_area": 3, "editor_open": 2, "export_gif": tm::MAX_COUNT });
    expect(v["events"] == events, &format!("Ereignisse {}", v["events"]));
    let state = settings.telemetry();
    expect(state.telemetry_counts.is_empty() && state.telemetry_last_sent == Some(now), "nach Erfolg: Zähler zurückgesetzt, Zeitpunkt gemerkt");

    // 6. Höchstens einmal in 24 h.
    t.count("pin");
    expect(t.check_at(now + 3600) == Outcome::NotDue && server.count() == 1, "höchstens einmal in 24 Stunden");

    // 7. Fehler (HTTP 500, Server weg): Zähler bleiben, kein neuer Zeitpunkt.
    server.set_status(500);
    let r = t.check_at(now + 25 * 3600);
    let state = settings.telemetry();
    expect(
        matches!(r, Outcome::Failed(_)) && server.count() == 2 && state.telemetry_counts.get("pin") == Some(&1) && state.telemetry_last_sent == Some(now),
        &format!("HTTP 500: Zähler bleiben ({r:?})"),
    );
    let dead_port = std::net::TcpListener::bind("127.0.0.1:0")?.local_addr()?.port();
    let dead = Telemetry::new(settings.clone(), Some(Config { endpoint: format!("http://127.0.0.1:{dead_port}/v1/ping"), info: info.clone() }));
    let started = Instant::now();
    let r = dead.check_at(now + 25 * 3600);
    expect(
        matches!(r, Outcome::Failed(_)) && settings.telemetry().telemetry_counts.get("pin") == Some(&1),
        &format!("Server nicht erreichbar: Zähler bleiben ({r:?}, {} ms)", started.elapsed().as_millis()),
    );
    server.set_status(204);
    let r = t.check_at(now + 26 * 3600);
    let sent: serde_json::Value = server.last().and_then(|q| serde_json::from_slice(&q.body).ok()).unwrap_or_default();
    expect(r == Outcome::Sent(204) && sent["events"] == serde_json::json!({ "pin": 1 }), "nächster Versuch sendet die behaltenen Zähler");

    // 8. Gespeichert in settings.json (Felder „telemetry…“); die Oberfläche kann sie nicht überschreiben.
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(settings.path())?)?;
    let stored: Vec<&str> = raw.as_object().map(|o| o.keys().filter(|k| k.starts_with("telemetry")).map(String::as_str).collect()).unwrap_or_default();
    expect(raw["telemetryConsent"] == true && raw["telemetryInstallId"] == id.as_str(), &format!("in settings.json: {stored:?}"));
    expect(SettingsStore::load().telemetry() == settings.telemetry(), "nach Neustart derselbe Zustand");
    let _ = settings.patch(&serde_json::json!({ "telemetryConsent": false, "telemetryInstallId": "x", "playSound": true }));
    expect(settings.telemetry().telemetry_install_id.as_deref() == Some(id.as_str()), "Einstellungen der Oberfläche ändern die Statistik nicht");

    // 9. Widerruf: Kennung und offene Zähler sofort weg, danach nichts mehr.
    t.count("copy_text");
    t.set_consent(false);
    let state = settings.telemetry();
    expect(state.telemetry_consent == Some(false) && state.telemetry_install_id.is_none() && state.telemetry_counts.is_empty(), "Widerruf löscht Kennung und Zähler");
    t.count("capture_area");
    let before = server.count();
    expect(
        settings.telemetry().telemetry_counts.is_empty() && t.check_at(now + 60 * 3600) == Outcome::NoConsent && server.count() == before,
        "nach Widerruf wird nichts gezählt oder gesendet",
    );
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(settings.path())?)?;
    expect(raw["telemetryConsent"] == false && raw.get("telemetryInstallId").map(|v| v.is_null()).unwrap_or(true), "Widerruf in settings.json");
    expect(!t.should_ask(), "nach einer Antwort keine Frage mehr");

    // 10. TLS über das System (nur Diagnose, sendet nichts): GET /v1/health.
    match crate::telemetry::probe("https://knips.velno.ai/v1/health") {
        Ok(status) => println!("   (Diagnose) HTTPS zu knips.velno.ai: HTTP {status}"),
        Err(err) => println!("   (Diagnose) HTTPS zu knips.velno.ai nicht erreichbar: {err:#}"),
    }
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}

// ------------------------------------------------------------------ track / video

/// Pseudo-zufälliges, textähnliches Muster (deterministisch).
pub(crate) fn pattern(width: u32, height: u32, seed: u32) -> RgbaImage {
    let mut state = seed.wrapping_mul(2_654_435_761).wrapping_add(1);
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state
    };
    let mut img = RgbaImage::from_pixel(width, height, image::Rgba([238, 240, 244, 255]));
    let mut y = 20;
    while y + 24 < height {
        let mut x = 30 + next() % 40;
        while x + 20 < width - 30 {
            let w = 12 + next() % 60;
            let shade = 30 + (next() % 60) as u8;
            for yy in y..y + 16 {
                for xx in x..(x + w).min(width - 30) {
                    img.put_pixel(xx, yy, image::Rgba([shade, shade, shade + 10, 255]));
                }
            }
            x += w + 8 + next() % 10;
        }
        y += 28 + next() % 6;
    }
    img
}

/// Scrollendes Testvideo: fester Kopf (60 px), Inhalt wandert `speed` px pro Bild nach oben.
pub(crate) fn scrolling_frame(content: &RgbaImage, width: u32, height: u32, offset: u32) -> RgbaImage {
    let mut frame = RgbaImage::from_pixel(width, height, image::Rgba([210, 214, 222, 255]));
    for y in 60..height {
        let cy = y - 60 + offset;
        if cy >= content.height() {
            continue;
        }
        for x in 0..width {
            frame.put_pixel(x, y, *content.get_pixel(x, cy));
        }
    }
    frame
}

fn track(out: &Path) -> Result<()> {
    let (w, h, fps, count, speed) = (1280u32, 720u32, 30u32, 90usize, 5u32);
    let content = pattern(w, h + count as u32 * speed + 200, 7);
    let path = out.join("track.mp4");
    media::write_test_video(&path, w, h, fps, count, false, &mut |i| scrolling_frame(&content, w, h, i as u32 * speed))?;
    println!("Testvideo: {} ({} Bilder, {speed} px/Bild)", path.display(), count);
    // Balken über einem Inhaltsstück, gesetzt bei t0 = 1 s (Bild 30).
    let t0 = 1.0;
    let frame0 = (t0 * fps as f64) as u32;
    let target_content_y = 420.0;
    let rect = Rect::new(300.0, 60.0 + target_content_y - (frame0 * speed) as f64, 320.0, 40.0);
    let cancel = AtomicBool::new(false);
    let mut reader = FrameReader::open(&path, Some(1280))?;
    let params = tracker::TrackParams { rect, t0, start: 0.0, end: (count as f64 - 1.0) / fps as f64, fps: fps as f64, video_width: w as f64, video_height: h as f64, cancel: &cancel };
    let t = Instant::now();
    let points = tracker::track(&params, &mut |t| reader.frame_at(t).ok().flatten(), &mut |_| {})?;
    println!("Verfolgt: {} Positionen in {} ms", points.len(), t.elapsed().as_millis());
    let mut worst: f64 = 0.0;
    let mut uncovered = 0;
    for p in &points {
        let frame = (p.time * fps as f64).round();
        let truth_y = 60.0 + target_content_y - frame * speed as f64;
        if truth_y < 60.0 || truth_y + 40.0 > h as f64 {
            continue;
        }
        let truth = Rect::new(300.0, truth_y, 320.0, 40.0);
        worst = worst.max((p.rect.mid_y() - truth.mid_y()).abs());
        if p.rect.intersection(&truth).area() < truth.area() * 0.95 {
            println!("   nicht verdeckt bei {:.3} s (Bild {frame}): Balken y {:.0}–{:.0}, Inhalt y {truth_y:.0}–{:.0}", p.time, p.rect.y, p.rect.max_y(), truth.max_y());
            uncovered += 1;
        }
    }
    println!("Größte Abweichung der Mitte: {worst:.1} px · Zeitpunkte ohne volle Abdeckung: {uncovered}");
    if uncovered > 0 {
        bail!("{uncovered} Zeitpunkte nicht vollständig verdeckt");
    }
    Ok(())
}

fn video(out: &Path) -> Result<()> {
    let (w, h, fps, count) = (1280u32, 720u32, 30u32, 120usize);
    let content = pattern(w, h + 800, 3);
    let src = out.join("video-quelle.mp4");
    media::write_test_video(&src, w, h, fps, count, false, &mut |i| scrolling_frame(&content, w, h, i as u32 * 4))?;
    let info = media::probe(&src)?;
    println!("Quelle: {}×{}, {:.2} s, {:.1} fps", info.width, info.height, info.duration, info.fps);

    // Kürzen 1–3 s, Balken oben links über die ganze Länge.
    let bar = Rect::new(100.0, 120.0, 300.0, 120.0);
    let doc = VideoDocument {
        trim_start: Some(1.0),
        trim_end: Some(3.0),
        redactions: vec![VideoRedaction::new(bar, 0.0, 4.0, RedactStyle::Solid)],
        ..Default::default()
    };
    let cancel = AtomicBool::new(false);
    let mp4 = out.join("video-export.mp4");
    let t = Instant::now();
    media::export_mp4(&src, &mp4, &doc, 1.0, &mut |_| {}, &cancel)?;
    let ex = media::probe(&mp4)?;
    println!("MP4: {}×{}, {:.2} s in {} ms", ex.width, ex.height, ex.duration, t.elapsed().as_millis());
    if (ex.duration - 2.0).abs() > 0.2 {
        bail!("MP4-Dauer {:.2} s statt 2 s", ex.duration);
    }
    let mut reader = FrameReader::open(&mp4, None)?;
    let frame = reader.frame_at(1.0)?.context("kein Bild bei 1 s")?;
    write(&frame, &out.join("video-export-1s.png"))?;
    let p = frame.get_pixel(bar.mid_x() as u32, bar.mid_y() as u32);
    println!("Pixel im Balken: {:?}", p.0);
    if p.0[0] > 40 || p.0[1] > 40 || p.0[2] > 40 {
        bail!("Balken fehlt im exportierten Video");
    }

    let gif = out.join("video-export.gif");
    let size = media::export_gif(&src, &gif, &doc, 1.0, 10, 640, &mut |_| {}, &cancel)?;
    let frames = image::codecs::gif::GifDecoder::new(std::io::BufReader::new(std::fs::File::open(&gif)?))
        .map(|d| image::AnimationDecoder::into_frames(d).count())
        .unwrap_or(0);
    println!("GIF: {}×{}, {frames} Bilder, {} KB", size.0, size.1, std::fs::metadata(&gif)?.len() / 1024);
    if size.0 != 640 || frames == 0 {
        bail!("GIF hat falsche Größe oder keine Bilder");
    }

    // Variable Bildrate wie eine Bildschirmaufnahme: Export ≥ 24 fps, Bewegung bleibt erhalten.
    crate::selftest_media::vfr_export(out)?;

    // Auto-Zensur im Video: stehendes Bild mit Kundendaten.
    if ocr::available() {
        let still = sample::sample_image(1400, 880, 2.0);
        let text_video = out.join("video-text.mp4");
        media::write_test_video(&text_video, 1400, 880, 10, 20, false, &mut |_| still.clone())?;
        let mut reader = FrameReader::open(&text_video, Some(knips_core::OCR_MAX_PIXEL))?;
        let kinds = all_kinds();
        let params = videodetect::DetectParams { start: 0.0, end: 1.9, step: 0.5, video_width: 1400.0, video_height: 880.0, style: RedactStyle::Solid, kinds: &kinds, cancel: &cancel };
        let found = videodetect::detect(&params, &mut |t| reader.frame_at(t).ok().flatten(), &mut |img| ocr::recognize(img).unwrap_or_default(), &mut |_| {})?;
        println!("Auto-Zensur im Video: {} Felder", found.len());
        for r in &found {
            println!("   {:.1}–{:.1} s @ {:.0},{:.0} {:.0}×{:.0}", r.start, r.end, r.rect.x, r.rect.y, r.rect.width, r.rect.height);
        }
        if found.len() < 3 {
            bail!("Auto-Zensur im Video fand zu wenig");
        }
    }
    Ok(())
}

// ------------------------------------------------------------------ Fenstertests (ui, render)

pub fn after_setup(app: &AppHandle) {
    let Ok(spec) = std::env::var("KNIPS_SELFTEST") else { return };
    let Some((test, out)) = spec.split_once('|') else { return };
    let (test, out) = (test.to_string(), PathBuf::from(out));
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(1500));
        let result = match test.as_str() {
            "ui" => ui(&app, &out),
            "render" => render(&app, &out),
            "links" => links(&app, &out),
            "nomedia" => crate::selftest_media::nomedia(&app, &out),
            "oldwin" => crate::selftest_media::oldwin(&app, &out),
            _ => Ok(()),
        };
        let code = match result {
            Ok(()) => {
                println!("OK");
                0
            }
            Err(err) => {
                println!("FEHLER: {err:#}");
                1
            }
        };
        std::process::exit(code);
    });
}

/// Eigenes Fenster fotografieren (nicht ausgeschlossen, da Test-Sandbox).
pub(crate) fn shoot(app: &AppHandle, label: &str, out: &Path, name: &str) -> Result<()> {
    let window = app.get_webview_window(label).with_context(|| format!("Fenster {label} fehlt"))?;
    let hwnd = wm::hwnd(&window).with_context(|| format!("Fenster {label} ohne HWND"))?;
    let image = capture::own_window_image(hwnd)?;
    write(&image, &out.join(name))
}

fn ui(app: &AppHandle, out: &Path) -> Result<()> {
    let k = crate::app::knips();
    let mut failures = vec![];
    let mut check = |name: &str, r: Result<()>| {
        if let Err(err) = r {
            println!("   FALSCH {name}: {err:#}");
            failures.push(name.to_string());
        }
    };
    // Beispielaufnahmen
    let m = monitors::primary();
    let mut items = vec![];
    for (w, h) in [(1400, 880), (900, 1200), (1600, 700), (1400, 880), (1200, 800)] {
        items.push(k.store.add_image(sample::sample_image(w * 2, h * 2, 4.0), 2.0, None, None)?);
    }
    for i in &items {
        k.store.wait_until_written(i.id);
    }
    let video = {
        let content = pattern(1280, 1500, 5);
        let path = crate::paths::temp_dir().join("ui-video.mp4");
        media::write_test_video(&path, 1280, 720, 30, 60, false, &mut |i| scrolling_frame(&content, 1280, 720, i as u32 * 4))
            .and_then(|_| k.store.add_video(&path, 1.0))
            .map_err(|e| println!("   Video übersprungen: {e:#}"))
            .ok()
    };

    // Karten (5 Stück) und Einblendung
    for i in &items {
        k.cards.show(i.clone(), m.clone());
    }
    std::thread::sleep(Duration::from_millis(1500));
    check("karten", shoot(app, crate::cards::LABEL, out, "karten.png"));
    k.hud.show("Kopiert", "check");
    std::thread::sleep(Duration::from_millis(500));
    check("hud", shoot(app, crate::hud::LABEL, out, "hud.png"));

    // Menü
    crate::menu::show(app, Some((m.work.right() - 200, m.work.bottom() + 10)));
    std::thread::sleep(Duration::from_millis(1200));
    check("menu", shoot(app, crate::menu::LABEL, out, "menu.png"));
    crate::menu::close(app);

    // Einstellungen je Bereich
    for pane in ["general", "shortcuts", "recording", "redaction", "export", "storage", "privacy", "about"] {
        crate::commands::show_settings(app, Some(pane.into()));
        std::thread::sleep(Duration::from_millis(900));
        check(&format!("einstellungen-{pane}"), shoot(app, "settings", out, &format!("einstellungen-{pane}.png")));
    }
    // Allgemein, Datenschutz und Über Knips zusätzlich nach unten gescrollt („Befehle per Link“, Lizenz,
    // „So arbeitet Knips“) — der CI-Bildschirm ist nur 1024×768, ein höheres Fenster ginge nicht.
    for pane in ["general", "privacy", "about"] {
        crate::commands::show_settings(app, Some(pane.into()));
        std::thread::sleep(Duration::from_millis(900));
        if let Some(w) = app.get_webview_window("settings") {
            let _ = w.eval("document.querySelector('.st-page')?.scrollTo(0, 100000)");
        }
        std::thread::sleep(Duration::from_millis(500));
        check(&format!("einstellungen-{pane}-unten"), shoot(app, "settings", out, &format!("einstellungen-{pane}-unten.png")));
    }
    // Frage zur Nutzungsstatistik (erscheint sonst nur beim ersten Start, nie in der Sandbox).
    crate::telemetry::show_consent(app);
    std::thread::sleep(Duration::from_millis(1200));
    check("einwilligung", shoot(app, crate::telemetry::CONSENT_LABEL, out, "einwilligung.png"));
    if let Some(w) = app.get_webview_window(crate::telemetry::CONSENT_LABEL) {
        let _ = w.destroy();
    }
    let sandbox_off = if k.telemetry.consent().is_some() || k.telemetry.enabled() {
        Err(anyhow::anyhow!("Sandbox: Statistik aktiv oder Zustimmung gesetzt"))
    } else {
        Ok(())
    };
    check("statistik-sandbox", sandbox_off);

    // Rückfrage vor einer Aufnahme per knips://-Link. Ausführen ist ersetzt: nimmt nie auf.
    k.links.set_test_hooks(Some((Arc::new(|_| {}), Arc::new(|| false))));
    let saved = k.settings.get().link_capture_without_confirm;
    k.settings.update(|s| s.link_capture_without_confirm = false);
    crate::app::handle_url("knips://fullscreen");
    let prompt = wait_prompt(app, Immediate::Fullscreen).and_then(|(label, _)| {
        std::thread::sleep(Duration::from_millis(900)); // „Aufnehmen“ nach der Schutzzeit
        shoot(app, &label, out, "link-rueckfrage.png").map(|_| label)
    });
    match prompt {
        Ok(label) => {
            k.links.decide(&label, false, false);
        }
        Err(err) => check("link-rueckfrage", Err(err)),
    }
    k.links.set_test_hooks(None);
    k.settings.update(|s| s.link_capture_without_confirm = saved);

    // Verlauf
    crate::commands::show_history(app);
    std::thread::sleep(Duration::from_millis(1500));
    check("verlauf", shoot(app, "history", out, "verlauf.png"));

    // Bild-Editor und Video-Editor
    crate::commands::open_item(app, items[0].id, Some("redact".into()));
    std::thread::sleep(Duration::from_millis(3000));
    check("editor", shoot(app, &format!("editor-{}", items[0].id), out, "editor.png"));
    if let Some(v) = &video {
        crate::commands::open_item(app, v.id, None);
        std::thread::sleep(Duration::from_millis(3500));
        check("video-editor", shoot(app, &format!("video-{}", v.id), out, "video-editor.png"));
    }

    // Anpinnen
    let pin_image = imageops::load(Path::new(&items[1].file_path))?;
    k.pins.pin(Arc::new(pin_image), 1.0)?;
    std::thread::sleep(Duration::from_millis(1200));
    if let Some(label) = app.webview_windows().keys().find(|l| l.starts_with("pin-")).cloned() {
        check("pin", shoot(app, &label, out, "pin.png"));
    }

    // Leisten (Aufnahme, Countdown, Scroll) mit Platzhalter-Zustand
    for (label, route, size) in [("rec-controls", "rec-controls", (246.0, 44.0)), ("rec-countdown", "rec-countdown", (150.0, 176.0)), ("scroll-controls", "scroll-controls", (380.0, 48.0))] {
        if let Ok(w) = wm::ensure(app, &wm::Spec::floating(label, route, size)) {
            wm::center_on_cursor_monitor(&w, size);
            let _ = w.show();
            std::thread::sleep(Duration::from_millis(900));
            check(label, shoot(app, label, out, &format!("{label}.png")));
            let _ = w.hide();
        }
    }
    if !failures.is_empty() {
        bail!("Fenster ohne Bild: {}", failures.join(", "));
    }
    Ok(())
}

// ------------------------------------------------------------------ knips://-Links (links)

static PROBES: parking_lot::Mutex<BTreeMap<u32, String>> = parking_lot::Mutex::new(BTreeMap::new());
static PROBE_ID: AtomicU32 = AtomicU32::new(1);

/// Antwort auf `probe` aus einem Fenster.
#[tauri::command]
pub fn selftest_probe(id: u32, value: String) {
    PROBES.lock().insert(id, value);
}

/// Wertet den JavaScript-Ausdruck `expr` im Fenster aus und liefert das Ergebnis als Text.
pub(crate) fn probe(window: &WebviewWindow, expr: &str, timeout: Duration) -> Result<String> {
    let id = PROBE_ID.fetch_add(1, Ordering::SeqCst);
    let send = "window.__TAURI_INTERNALS__.invoke('selftest_probe'";
    window.eval(format!(
        "Promise.resolve().then(() => ({expr})).then(v => {send}, {{ id: {id}, value: String(v) }}), e => {send}, {{ id: {id}, value: 'Fehler: ' + e }}))"
    ))?;
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(value) = PROBES.lock().remove(&id) {
            return Ok(value);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    bail!("Fenster {} antwortet nicht", window.label())
}

/// Wartet, bis die Rückfrage für `kind` offen und ihre Oberfläche bereit ist.
fn wait_prompt(app: &AppHandle, kind: Immediate) -> Result<(String, WebviewWindow)> {
    let k = crate::app::knips();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match k.links.pending() {
            Some((label, open)) if open == kind => {
                if let Some(window) = app.get_webview_window(&label) {
                    let ready = probe(&window, "document.querySelector('[data-act=confirm]') ? 'bereit' : 'nein'", Duration::from_millis(400));
                    if ready.ok().as_deref() == Some("bereit") {
                        return Ok((label, window));
                    }
                }
            }
            Some((_, open)) => bail!("Rückfrage für knips://{} statt knips://{}", open.name(), kind.name()),
            None => {}
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!("keine Rückfrage für knips://{}", kind.name())
}

/// Wartet, bis die Rückfrage `label` erledigt ist.
fn wait_resolved(label: &str) -> bool {
    let k = crate::app::knips();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if k.links.pending().map(|(l, _)| l) != Some(label.to_string()) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    false
}

/// Rückfrage vor sofort aufnehmenden knips://-Links (Vollbild, letzter Bereich, Videostart) — wie
/// `SelfTest.links` auf dem Mac: ohne Einstellung erst Rückfrage, Esc/Schließen/Abbrechen = nichts,
/// Aufnehmen erst nach der Schutzzeit (in Rust und in der Oberfläche), „Nicht mehr fragen“ nur mit
/// Aufnehmen, Stoppen und eigene Wege direkt; mit Einstellung direkt. Ausführen ist durch eine Liste
/// ersetzt: Es wird nie aufgenommen und nie das Auswahl-Overlay geöffnet.
fn links(app: &AppHandle, out: &Path) -> Result<()> {
    let k = crate::app::knips();
    let calls: Arc<parking_lot::Mutex<Vec<HotkeyAction>>> = Arc::default();
    let recording = Arc::new(AtomicBool::new(false));
    let (c, r) = (calls.clone(), recording.clone());
    k.links.set_test_hooks(Some((Arc::new(move |a| c.lock().push(a)), Arc::new(move || r.load(Ordering::SeqCst)))));
    let saved = k.settings.get().link_capture_without_confirm;
    let result = links_steps(app, out, &calls, &recording);
    k.links.set_test_hooks(None);
    k.settings.update(|s| s.link_capture_without_confirm = saved);
    result
}

fn links_steps(app: &AppHandle, out: &Path, calls: &parking_lot::Mutex<Vec<HotkeyAction>>, recording: &AtomicBool) -> Result<()> {
    use HotkeyAction as A;
    let k = crate::app::knips();
    let link = |command: &str| crate::app::handle_url(&format!("knips://{command}"));
    // Bestätigtes läuft 150 ms verzögert (Rückfrage erst ausblenden) — kurz warten, dann abholen.
    let take = || {
        std::thread::sleep(Duration::from_millis(400));
        std::mem::take(&mut *calls.lock())
    };
    let setting = || k.settings.get().link_capture_without_confirm;
    let armed = || std::thread::sleep(knips_core::links::ARM_DELAY + Duration::from_millis(300));
    // Knöpfe und Tasten schließen das Fenster — erst antworten, dann (kurz danach) auslösen.
    let click = |w: &WebviewWindow, act: &str| {
        probe(w, &format!("(setTimeout(() => document.querySelector('[data-act={act}]').click(), 50), 'ok')"), Duration::from_secs(3))
    };
    let key = |w: &WebviewWindow, name: &str| {
        probe(
            w,
            &format!("(setTimeout(() => window.dispatchEvent(new KeyboardEvent('keydown', {{ key: '{name}', bubbles: true }})), 50), 'ok')"),
            Duration::from_secs(3),
        )
    };
    // Häkchen „Nicht mehr fragen“ setzen; Zustand nach dem Neuzeichnen zurückmelden.
    let tick = |w: &WebviewWindow| {
        probe(
            w,
            "new Promise(r => { const c = document.querySelector('[data-act=dont-ask]'); c.click(); setTimeout(() => r(document.querySelector('[data-act=dont-ask]').checked), 100); })",
            Duration::from_secs(3),
        )
    };
    let mut failed: Vec<String> = vec![];
    let mut check = |name: &str, ok: bool, seen: &[A]| {
        let open = k.links.pending().map(|(_, kind)| format!(", Rückfrage {} offen", kind.name())).unwrap_or_default();
        let seen = if seen.is_empty() { "nichts".to_string() } else { seen.iter().map(|a| format!("{a:?}")).collect::<Vec<_>>().join(", ") };
        println!("   {} {name} → {seen}{open}", if ok { "ok    " } else { "FALSCH" });
        if !ok {
            failed.push(name.to_string());
        }
    };

    k.settings.update(|s| s.link_capture_without_confirm = false);
    println!("Einstellung aus (Standard):");
    link("fullscreen");
    let (full, full_w) = wait_prompt(app, Immediate::Fullscreen)?;
    let seen = take();
    check("fullscreen fragt nach, nimmt nichts auf", seen.is_empty(), &seen);
    shoot(app, &full, out, "link-rueckfrage-fullscreen.png")?;
    link("last");
    let seen = take();
    check("weiterer Link bei offener Rückfrage verfällt", seen.is_empty() && k.links.pending().map(|p| p.0) == Some(full.clone()), &seen);
    key(&full_w, "Escape")?;
    let resolved = wait_resolved(&full);
    let seen = take();
    check("Esc = Abbrechen", resolved && seen.is_empty() && k.links.pending().is_none(), &seen);

    link("last");
    let (last, _) = k.links.pending().context("keine Rückfrage für knips://last")?;
    let early = k.links.decide(&last, true, false);
    let seen = take();
    check("Aufnehmen vor der Schutzzeit wirkt nicht (Rust)", !early && k.links.pending().map(|p| p.0) == Some(last.clone()) && seen.is_empty(), &seen);
    let (_, last_w) = wait_prompt(app, Immediate::Last)?;
    // Oberfläche: ⏎ sofort nach dem Öffnen — nur prüfbar, solange die Schutzzeit noch läuft.
    let pressed = probe(
        &last_w,
        "(() => { const b = document.querySelector('[data-act=confirm]'); if (!b.disabled) return 'scharf'; \
         window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); return 'gedrückt'; })()",
        Duration::from_secs(3),
    )?;
    if pressed == "gedrückt" {
        let seen = take();
        check("⏎ vor der Schutzzeit bestätigt nichts (Oberfläche)", k.links.pending().map(|p| p.0) == Some(last.clone()) && seen.is_empty(), &seen);
    } else {
        println!("   (Schutzzeit schon abgelaufen, als die Oberfläche bereit war — ⏎-Prüfung der Oberfläche übersprungen)");
    }
    armed();
    key(&last_w, "Enter")?;
    let resolved = wait_resolved(&last);
    let seen = take();
    check("⏎ = Aufnehmen → letzter Bereich", resolved && seen == [A::CaptureLastArea] && !setting(), &seen);

    link("record");
    let (record, record_w) = wait_prompt(app, Immediate::Record)?;
    armed();
    shoot(app, &record, out, "link-rueckfrage-record.png")?;
    let ticked = tick(&record_w)?;
    click(&record_w, "cancel")?;
    let resolved = wait_resolved(&record);
    let seen = take();
    check("Abbrechen mit „Nicht mehr fragen“ ändert nichts", ticked == "true" && resolved && seen.is_empty() && !setting(), &seen);

    link("fullscreen");
    let (closing, closing_w) = wait_prompt(app, Immediate::Fullscreen)?;
    closing_w.close()?;
    let resolved = wait_resolved(&closing);
    let seen = take();
    check("Fenster schließen = Abbrechen", resolved && seen.is_empty(), &seen);

    recording.store(true, Ordering::SeqCst);
    link("record");
    let seen = take();
    check("record stoppt laufende Aufnahme ohne Rückfrage", seen == [A::ToggleRecording] && k.links.pending().is_none(), &seen);
    recording.store(false, Ordering::SeqCst);
    link("record");
    let (late, late_w) = wait_prompt(app, Immediate::Record)?;
    recording.store(true, Ordering::SeqCst); // inzwischen per Kürzel gestartet
    armed();
    click(&late_w, "confirm")?;
    let resolved = wait_resolved(&late);
    let seen = take();
    check("Bestätigen stoppt eine inzwischen gestartete Aufnahme nicht", resolved && seen.is_empty(), &seen);
    recording.store(false, Ordering::SeqCst);

    for (command, action) in [("area", A::CaptureArea), ("window", A::CaptureWindow), ("text", A::CaptureText), ("scroll", A::CaptureScrolling), ("pin", A::PinClipboard)] {
        link(command);
        let seen = take();
        check(&format!("{command} direkt (nur Oberfläche)"), seen == [action] && k.links.pending().is_none(), &seen);
    }
    k.links.run("knips://fullscreen", false);
    let seen = take();
    check("eigener Weg (Selbsttest) ohne Rückfrage", seen == [A::CaptureFullscreen] && k.links.pending().is_none(), &seen);

    link("fullscreen");
    let (remember, remember_w) = wait_prompt(app, Immediate::Fullscreen)?;
    let ticked = tick(&remember_w)?;
    armed();
    click(&remember_w, "confirm")?;
    let resolved = wait_resolved(&remember);
    let seen = take();
    let stored = std::fs::read_to_string(k.settings.path()).unwrap_or_default().contains("\"linkCaptureWithoutConfirm\": true");
    check("Aufnehmen mit „Nicht mehr fragen“ schaltet die Einstellung ein", ticked == "true" && resolved && seen == [A::CaptureFullscreen] && setting() && stored, &seen);

    println!("Einstellung an:");
    for (command, action) in [("fullscreen", A::CaptureFullscreen), ("last", A::CaptureLastArea), ("record", A::ToggleRecording)] {
        link(command);
        let seen = take();
        check(&format!("{command} direkt"), seen == [action] && k.links.pending().is_none(), &seen);
    }

    // Schalter unter Einstellungen → Allgemein → „Befehle per Link“
    k.settings.update(|s| s.link_capture_without_confirm = false);
    k.broadcast_bootstrap();
    crate::commands::show_settings(app, Some("general".into()));
    std::thread::sleep(Duration::from_millis(1200));
    let settings_w = app.get_webview_window("settings").context("Einstellungen fehlen")?;
    let switch = "[...document.querySelectorAll('.st-row')].find(r => r.textContent.includes('Aufnahmen per Link ohne Rückfrage'))?.querySelector('[role=switch]')";
    let found = probe(&settings_w, &format!("(() => {{ const s = {switch}; if (!s) return 'fehlt'; s.scrollIntoView({{ block: 'center' }}); return s.getAttribute('aria-checked'); }})()"), Duration::from_secs(3))?;
    std::thread::sleep(Duration::from_millis(400));
    shoot(app, "settings", out, "link-einstellung-allgemein.png")?;
    probe(&settings_w, &format!("({switch}.click(), 'ok')"), Duration::from_secs(3))?;
    std::thread::sleep(Duration::from_millis(500));
    let on = setting();
    probe(&settings_w, &format!("({switch}.click(), 'ok')"), Duration::from_secs(3))?;
    std::thread::sleep(Duration::from_millis(500));
    check("Schalter in Allgemein (aus → an → aus)", found == "false" && on && !setting(), &[]);
    let _ = settings_w.hide();

    if !failed.is_empty() {
        bail!("Link-Rückfrage falsch: {}", failed.join(", "));
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct Rendered {
    name: String,
    width: u32,
    height: u32,
    png: String,
}

static RENDER_OUT: parking_lot::Mutex<Option<(PathBuf, std::sync::mpsc::Sender<usize>)>> = parking_lot::Mutex::new(None);

/// Renderer der Oberfläche (`src/editor/renderer.ts`) mit denselben Dokumenten wie `SelfTest.render`.
fn render(app: &AppHandle, out: &Path) -> Result<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    *RENDER_OUT.lock() = Some((out.to_path_buf(), tx));
    let window = wm::ensure(app, &wm::Spec::window("selftest", "selftest-render", "Knips – Selbsttest", (1200.0, 800.0)))?;
    let _ = window.show();
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        let _ = window.eval(
            "if (window.__knipsSelftestRender && !window.__knipsReported) { window.__knipsReported = true; \
             window.__knipsSelftestRender().then(r => window.__TAURI_INTERNALS__.invoke('selftest_report', { results: r })); }",
        );
        if let Ok(n) = rx.recv_timeout(Duration::from_millis(700)) {
            if n < 3 {
                bail!("nur {n} Bilder gerendert");
            }
            return Ok(());
        }
    }
    bail!("Renderer hat nicht geantwortet")
}

#[tauri::command]
pub fn selftest_report(results: Vec<Rendered>) -> Result<(), String> {
    let Some((out, tx)) = RENDER_OUT.lock().clone() else { return Ok(()) };
    let mut n = 0;
    for r in &results {
        let b64 = r.png.split_once(',').map(|(_, b)| b).unwrap_or(&r.png);
        let data = base64_decode(b64).map_err(|e| e.to_string())?;
        let path = out.join(format!("render-{}.png", r.name));
        std::fs::write(&path, &data).map_err(|e| e.to_string())?;
        println!("→ {} ({}×{})", path.display(), r.width, r.height);
        n += 1;
    }
    let _ = tx.send(n);
    Ok(())
}

fn base64_decode(s: &str) -> Result<Vec<u8>> {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut map = [255u8; 256];
    for (i, c) in T.iter().enumerate() {
        map[*c as usize] = i as u8;
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes().filter(|c| !c.is_ascii_whitespace() && *c != b'=') {
        let v = map[c as usize];
        if v == 255 {
            bail!("ungültiges Base64");
        }
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Ok(out)
}

/// Test-Befehle über `knips://debug-…` (nur in der Sandbox).
pub fn handle_debug_command(command: &str) -> bool {
    if crate::paths::test_root().is_none() {
        return false;
    }
    let k = crate::app::knips();
    match command {
        "debug-sample" => {
            if let Ok(item) = k.store.add_image(sample::sample_image(2800, 1760, 4.0), 2.0, None, None) {
                k.cards.show(item, monitors::primary());
            }
            true
        }
        "debug-lastarea" => {
            k.coordinator.debug_set_last_area(IRect::new(200, 200, 800, 600));
            true
        }
        _ => false,
    }
}
