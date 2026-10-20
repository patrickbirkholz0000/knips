//! Bildschirmaufnahme steuern (`RecordingController.swift`): Rahmen, Countdown, Leiste, Speichern.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use knips_core::geometry::IRect;
use knips_platform::media::{RecordOptions, Recorder};
use knips_platform::overlay::{FrameColor, FrameWindow};
use knips_platform::{clipboard, Monitor};
use parking_lot::Mutex;
use serde::Serialize;

use crate::app::knips;
use crate::crash::OnDrop;
use crate::{paths, wm};

/// Wie oft der Hinweis „Media Feature Pack fehlt“ kam (Selbsttest `nomedia`).
static MEDIA_HINTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// Windows N/KN ohne Media Feature Pack: Video geht nicht — erklären, wo es das Paket gibt.
pub fn media_missing_hint() {
    MEDIA_HINTS.fetch_add(1, Ordering::SeqCst);
    knips().alert_with_settings(
        "Bildschirmaufnahme nicht verfügbar",
        knips_platform::media::MISSING_HINT,
        "Optionale Features öffnen",
        "ms-settings:optionalfeatures",
    );
}

#[cfg(feature = "dev")]
pub fn media_hints_shown() -> u32 {
    MEDIA_HINTS.load(Ordering::SeqCst)
}

/// Mikrofon ließ sich nicht öffnen oder fiel aus: Video ist (teilweise) ohne Ton. Desktop-Apps fragt
/// Windows 10 nicht nach — der Schalter muss in den Datenschutz-Einstellungen an sein.
fn microphone_hint(warnings: &[String]) {
    let message = format!(
        "{}\n\nPrüfe unter Einstellungen → Datenschutz → Mikrofon, ob „Zugriff auf das Mikrofon“ und \
         „Desktop-Apps den Zugriff auf das Mikrofon erlauben“ eingeschaltet sind und ob ein Mikrofon angeschlossen ist.",
        warnings.join("\n")
    );
    knips().alert_with_settings("Video ohne Ton", &message, "Mikrofon-Einstellungen öffnen", "ms-settings:privacy-microphone");
}

/// Die Aufnahme ließ sich nicht in die Ablage übernehmen (z. B. nicht lesbar): Datei nicht im
/// Temp-Ordner liegen lassen, sondern in den Ablageordner legen und im Fehler nennen.
fn rescue(temp: &std::path::Path, err: anyhow::Error) -> anyhow::Error {
    if !temp.exists() {
        return err;
    }
    let folder = knips().settings.save_folder();
    paths::ensure(&folder);
    let stem = format!("Knips Aufnahme {}", knips_core::format::file_date_now());
    let mut target = folder.join(format!("{stem}.mp4"));
    let mut n = 2;
    while target.exists() {
        target = folder.join(format!("{stem} ({n}).mp4"));
        n += 1;
    }
    let moved = std::fs::rename(temp, &target).or_else(|_| std::fs::copy(temp, &target).map(|_| {
        let _ = std::fs::remove_file(temp);
    }));
    match moved {
        Ok(()) => anyhow::anyhow!("{err:#}\n\nDas Video liegt unbearbeitet unter {}", target.display()),
        Err(e) => {
            log::warn!("Aufnahme nicht in die Ablage verschoben: {e}");
            anyhow::anyhow!("{err:#}\n\nDas Video liegt unter {}", temp.display())
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Idle,
    Countdown(u32),
    Recording,
    Finishing,
}

#[derive(Serialize, Clone)]
pub struct RecordingState {
    pub phase: &'static str,
    pub countdown: u32,
    pub elapsed: f64,
}

struct Inner {
    phase: Phase,
    recorder: Option<Recorder>,
    started: Option<Instant>,
    frame: Option<FrameWindow>,
    monitor: Option<Monitor>,
    /// Pixel pro Punkt des Videos.
    scale: f64,
    cancel: Arc<AtomicBool>,
    global: IRect,
    full: bool,
    /// Zieldatei der laufenden Aufnahme.
    path: Option<std::path::PathBuf>,
}

impl Default for Inner {
    fn default() -> Self {
        Self {
            phase: Phase::Idle,
            recorder: None,
            started: None,
            frame: None,
            monitor: None,
            scale: 1.0,
            cancel: Arc::new(AtomicBool::new(false)),
            global: IRect::default(),
            full: false,
            path: None,
        }
    }
}

#[derive(Default)]
pub struct Recording {
    inner: Mutex<Inner>,
}

const CONTROLS: &str = "rec-controls";
const COUNTDOWN: &str = "rec-countdown";
const CONTROLS_SIZE: (f64, f64) = (246.0, 44.0);
const COUNTDOWN_SIZE: (f64, f64) = (150.0, 176.0);

impl Recording {
    pub fn phase(&self) -> Phase {
        self.inner.lock().phase
    }
    pub fn is_busy(&self) -> bool {
        self.phase() != Phase::Idle
    }
    pub fn is_recording(&self) -> bool {
        self.phase() == Phase::Recording
    }

    pub fn state(&self) -> RecordingState {
        let inner = self.inner.lock();
        let (phase, countdown) = match inner.phase {
            Phase::Idle => ("idle", 0),
            Phase::Countdown(n) => ("countdown", n),
            Phase::Recording => ("recording", 0),
            Phase::Finishing => ("finishing", 0),
        };
        let elapsed = if inner.phase == Phase::Recording { inner.started.map(|s| s.elapsed().as_secs_f64()).unwrap_or(0.0) } else { 0.0 };
        RecordingState { phase, countdown, elapsed }
    }

    fn publish(&self) {
        let state = self.state();
        crate::tray::refresh_recording(&state);
        knips().emit("recording-state", state);
    }

    fn set_phase(&self, phase: Phase) {
        self.inner.lock().phase = phase;
        self.publish();
    }

    /// `rect`: monitor-lokal, physische Pixel.
    pub fn begin(&self, monitor: Monitor, rect: IRect) {
        let s = monitor.scale;
        if self.is_busy() || (rect.width as f64) < 16.0 * s || (rect.height as f64) < 16.0 * s {
            return;
        }
        let k = knips();
        let settings = k.settings.get();
        // Videos in Bildschirmgröße (1×): 1 Pixel pro Punkt; sonst volle Auflösung. Höchstens 4096 px.
        let mut px_per_point = if settings.recording_at_screen_size { 1.0 } else { s };
        let longest = rect.width.max(rect.height) as f64 / s * px_per_point;
        if longest > 4096.0 {
            px_per_point *= 4096.0 / longest;
        }
        let even = |v: f64| ((v / 2.0).floor() * 2.0).max(2.0) as u32;
        let width = even(rect.width as f64 / s * px_per_point);
        let height = even(rect.height as f64 / s * px_per_point);
        let global = wm::global(&monitor, rect);
        let full = rect.width == monitor.rect.width && rect.height == monitor.rect.height;
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut inner = self.inner.lock();
            inner.monitor = Some(monitor.clone());
            inner.scale = px_per_point;
            inner.cancel = cancel.clone();
            inner.global = global;
            inner.full = full;
            if !full {
                inner.frame = FrameWindow::show(global, FrameColor::Recording).ok();
            }
            inner.phase = Phase::Countdown(3);
        }
        let path = paths::temp_dir().join(format!("aufnahme-{}.mp4", uuid::Uuid::new_v4()));
        self.inner.lock().path = Some(path.clone());
        let options = RecordOptions {
            monitor: monitor.clone(),
            rect,
            width,
            height,
            fps: settings.recording_fps,
            show_cursor: settings.recording_show_cursor,
            show_clicks: settings.recording_show_clicks,
            microphone: settings.recording_microphone,
            hevc: settings.recording_hevc,
            path,
        };
        std::thread::spawn(move || {
            let rec = &knips().recording;
            if settings.recording_countdown {
                rec.show_countdown(&monitor, global);
                for n in (1..=3).rev() {
                    rec.set_phase(Phase::Countdown(n));
                    std::thread::sleep(Duration::from_secs(1));
                    if cancel.load(Ordering::SeqCst) {
                        return;
                    }
                }
                rec.hide_window(COUNTDOWN);
            }
            if cancel.load(Ordering::SeqCst) {
                return;
            }
            let on_error: Box<dyn Fn(String) + Send + Sync> = Box::new(|message| {
                log::error!("Aufnahme-Stream beendet: {message}");
                let rec = &knips().recording;
                if rec.is_recording() {
                    rec.stop(true);
                }
            });
            // Stürzt der Start ab, nicht im Countdown hängen bleiben (sonst nie wieder eine Aufnahme).
            let _reset = OnDrop(|| {
                if std::thread::panicking() {
                    knips().recording.teardown();
                }
            });
            match Recorder::start(options, on_error) {
                Ok(recorder) => {
                    let mic_problem = !recorder.warnings().is_empty();
                    {
                        let mut inner = rec.inner.lock();
                        inner.recorder = Some(recorder);
                        inner.started = Some(Instant::now());
                        inner.phase = Phase::Recording;
                    }
                    rec.publish();
                    rec.show_controls(&monitor, global, full);
                    rec.tick();
                    crate::telemetry::count("recording_start");
                    // Einblendung ist aus Aufnahmen ausgeschlossen; Einzelheiten nach dem Speichern.
                    if mic_problem {
                        knips().hud.show("Mikrofon nicht verfügbar – Video ohne Ton", "error");
                    }
                }
                Err(err) => {
                    rec.teardown();
                    knips().alert("Aufnahme konnte nicht starten", &format!("{err:#}"));
                }
            }
        });
    }

    /// Zeit in der Leiste und im Tray fortschreiben.
    fn tick(&self) {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_millis(250));
            let rec = &knips().recording;
            if !rec.is_recording() {
                break;
            }
            rec.publish();
        });
    }

    pub fn stop(&self, save: bool) {
        let phase = self.phase();
        match phase {
            Phase::Idle | Phase::Finishing => return,
            Phase::Countdown(_) => {
                self.inner.lock().cancel.store(true, Ordering::SeqCst);
                self.teardown();
                return;
            }
            Phase::Recording => {}
        }
        let (recorder, monitor, scale, path) = {
            let mut inner = self.inner.lock();
            inner.phase = Phase::Finishing;
            inner.frame = None;
            (inner.recorder.take(), inner.monitor.clone(), inner.scale, inner.path.clone().unwrap_or_default())
        };
        self.hide_window(CONTROLS);
        self.publish();
        let Some(recorder) = recorder else {
            self.teardown();
            return;
        };
        std::thread::spawn(move || {
            let k = knips();
            let rec = &k.recording;
            // Stürzt das Speichern ab, nicht in „Finishing“ hängen bleiben (sonst nie wieder eine Aufnahme).
            let _reset = OnDrop(|| {
                if std::thread::panicking() {
                    knips().recording.teardown();
                }
            });
            if !save {
                recorder.cancel();
                rec.teardown();
                k.hud.show("Aufnahme verworfen", "trash");
                return;
            }
            let warnings = recorder.warnings();
            let stopped = recorder.stop();
            let result = match stopped {
                Ok(_) => k.store.add_video(&path, scale).map_err(|err| rescue(&path, err)),
                Err(err) => Err(err),
            };
            rec.teardown();
            match result {
                Ok(item) => {
                    crate::telemetry::count("recording_saved");
                    let settings = k.settings.get();
                    if settings.copy_to_clipboard {
                        let _ = clipboard::set_files(&[std::path::PathBuf::from(&item.file_path)]);
                    }
                    if settings.show_quick_access {
                        k.cards.show(item, monitor.unwrap_or_else(knips_platform::monitors::at_cursor));
                    }
                    if !warnings.is_empty() {
                        microphone_hint(&warnings);
                    }
                }
                Err(err) => k.alert("Aufnahme konnte nicht gespeichert werden", &format!("{err:#}")),
            }
        });
    }

    pub(crate) fn teardown(&self) {
        {
            let mut inner = self.inner.lock();
            let cancel = inner.cancel.clone();
            *inner = Inner::default();
            inner.cancel = cancel;
        }
        self.hide_window(CONTROLS);
        self.hide_window(COUNTDOWN);
        self.publish();
    }

    fn hide_window(&self, label: &str) {
        if let Some(w) = wm::get(&knips().app, label) {
            let _ = w.hide();
        }
    }

    fn show_countdown(&self, monitor: &Monitor, area: IRect) {
        let Ok(window) = wm::ensure(&knips().app, &wm::Spec::floating(COUNTDOWN, "rec-countdown", COUNTDOWN_SIZE)) else { return };
        let s = monitor.scale;
        let (w, h) = ((COUNTDOWN_SIZE.0 * s) as i32, (COUNTDOWN_SIZE.1 * s) as i32);
        wm::place(&window, monitor, COUNTDOWN_SIZE, (area.x + (area.width - w) / 2, area.y + (area.height - h) / 2));
        let _ = window.show();
    }

    /// Leiste unter dem Bereich; passt sie nicht, darüber; bei Vollbild unten im Bild.
    fn show_controls(&self, monitor: &Monitor, area: IRect, full: bool) {
        let Ok(window) = wm::ensure(&knips().app, &wm::Spec::floating(CONTROLS, "rec-controls", CONTROLS_SIZE)) else { return };
        let s = monitor.scale;
        let (w, h) = ((CONTROLS_SIZE.0 * s) as i32, (CONTROLS_SIZE.1 * s) as i32);
        let gap = (12.0 * s) as i32;
        let work = monitor.work;
        let mut x = area.x + (area.width - w) / 2;
        let mut y = area.bottom() + gap;
        if full || y + h > work.bottom() - (4.0 * s) as i32 {
            y = area.y - h - gap;
            if full || y < work.y + (4.0 * s) as i32 {
                y = area.bottom().min(work.bottom()) - h - (16.0 * s) as i32;
            }
        }
        x = x.clamp(work.x + (8.0 * s) as i32, work.right() - w - (8.0 * s) as i32);
        wm::place(&window, monitor, CONTROLS_SIZE, (x, y));
        let _ = window.show();
    }
}

