//! Bildschirmaufnahme: Desktop Duplication (schnell) mit Graphics Capture als Rückfall,
//! Fensterliste, Fensterbild, Bereichs-Aufnahme für Scroll-Screenshots.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use knips_core::RgbaImage;
use windows::core::PWSTR;
use windows::core::BOOL;
use windows::Win32::Foundation::{CloseHandle, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::System::Threading::{
    GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetLayeredWindowAttributes, GetWindowLongPtrW, GetWindowRect, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, SetWindowDisplayAffinity, ShowWindow, GWL_EXSTYLE,
    LWA_ALPHA, SW_HIDE, SW_SHOWNA, WDA_EXCLUDEFROMCAPTURE, WDA_NONE, WS_EX_APPWINDOW, WS_EX_LAYERED,
    WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
};

use parking_lot::Mutex;

use super::d3d::{item_for_monitor, item_for_window, Dda, DdaGrab, Wgc};
use super::util::{from_wide, hwnd, init_com};
use crate::types::{Frozen, IRect, Monitor, WindowInfo};

// ---------------------------------------------------------------- Standbilder

/// Was beim letzten `freeze` geschah (je Monitor: Weg, Meldungen der Desktop Duplication, Helligkeit) —
/// für Log und Selbsttests.
static FREEZE_NOTES: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn note(text: String) {
    log::debug!("Standbild: {text}");
    FREEZE_NOTES.lock().push(text);
}

/// Notizen zum letzten Standbild (`freeze`).
pub fn freeze_notes() -> Vec<String> {
    FREEZE_NOTES.lock().clone()
}

fn describe(img: &RgbaImage) -> String {
    let b = knips_core::imageops::brightness(img, None, 8);
    format!("Helligkeit {:.1}, schwarz {:.1} %", b.mean, b.black * 100.0)
}

/// Ein Monitor: Desktop Duplication, bei Fehlern Graphics Capture.
fn freeze_one(m: &Monitor) -> Result<RgbaImage> {
    init_com();
    let start = Instant::now();
    let ms = || start.elapsed().as_millis();
    let dda_err = match Dda::open(m) {
        Ok(mut dda) => {
            note(format!("{}: Desktop Duplication offen nach {} ms", m.name, ms()));
            // Der erste Aufruf liefert den aktuellen Desktop; ein, zwei Wiederholungen für Randfälle.
            let mut res = Err(anyhow!("kein Bild"));
            for _ in 0..3 {
                match dda.acquire(None, 250) {
                    Ok(DdaGrab::Frame(f, img)) => {
                        note(format!(
                            "{}: Meldung nach {} ms, LastPresentTime {}, AccumulatedFrames {}, Zeiger {}, {}",
                            m.name,
                            ms(),
                            f.last_present,
                            f.accumulated,
                            f.pointer,
                            describe(&img)
                        ));
                        res = Ok(img);
                        break;
                    }
                    Ok(DdaGrab::Timeout) => note(format!("{}: nichts Neues nach {} ms", m.name, ms())),
                    Err(e) => {
                        res = Err(e);
                        break;
                    }
                }
            }
            match res {
                Ok(img) => return Ok(img),
                Err(e) => e,
            }
        }
        Err(e) => e,
    };
    note(format!("{}: Desktop Duplication nicht möglich ({dda_err:#}), nehme Graphics Capture", m.name));
    let item = item_for_monitor(m.id)?;
    let mut wgc = Wgc::start(&item)?;
    match wgc.grab(None, 1500, true)? {
        Some((img, _)) => {
            note(format!("{}: Graphics Capture nach {} ms, {}", m.name, ms(), describe(&img)));
            Ok(img)
        }
        None => bail!("Graphics Capture lieferte kein Bild für {}", m.name),
    }
}

/// Selbsttest: neue Desktop-Duplication-Sitzung öffnen und die ersten `n` Meldungen beschreiben (Zeit,
/// LastPresentTime, AccumulatedFrames, Zeiger, Helligkeit) — mit dem Bild, das jede Meldung liefert.
#[cfg(feature = "dev")]
pub fn probe_duplication(m: &Monitor, n: usize) -> Result<Vec<(String, RgbaImage)>> {
    init_com();
    let start = Instant::now();
    let mut dda = Dda::open(m)?;
    let mut out = Vec::new();
    for i in 0..n {
        match dda.acquire(None, 100)? {
            DdaGrab::Frame(f, img) => {
                let text = format!(
                    "Meldung {} nach {} ms: LastPresentTime {}, AccumulatedFrames {}, Zeiger {}, {}",
                    i + 1,
                    start.elapsed().as_millis(),
                    f.last_present,
                    f.accumulated,
                    f.pointer,
                    describe(&img)
                );
                out.push((text, img));
            }
            DdaGrab::Timeout => out.push((format!("Meldung {}: nichts Neues nach {} ms", i + 1, start.elapsed().as_millis()), RgbaImage::new(1, 1))),
        }
    }
    Ok(out)
}

/// Standbild aller angegebenen Monitore; eigene Fenster (mit `exclude_from_capture`) fehlen darin.
pub fn freeze(monitors: &[Monitor]) -> Result<Vec<Frozen>> {
    FREEZE_NOTES.lock().clear();
    let results: Vec<Result<RgbaImage>> = if monitors.len() <= 1 {
        monitors.iter().map(freeze_one).collect()
    } else {
        std::thread::scope(|s| {
            let handles: Vec<_> = monitors.iter().map(|m| s.spawn(move || freeze_one(m))).collect();
            handles
                .into_iter()
                .map(|h| h.join().unwrap_or_else(|_| Err(anyhow!("Aufnahme-Thread abgestürzt"))))
                .collect()
        })
    };
    let mut out = Vec::new();
    let mut last_err = None;
    for (m, r) in monitors.iter().zip(results) {
        match r {
            Ok(image) => out.push(Frozen { monitor: m.clone(), image }),
            Err(e) => {
                log::warn!("Aufnahme von {} fehlgeschlagen: {e:#}", m.name);
                last_err = Some(e);
            }
        }
    }
    if out.is_empty() {
        return Err(last_err.unwrap_or_else(|| anyhow!("kein Bildschirm")));
    }
    Ok(out)
}

// ---------------------------------------------------------------- Fensterliste

struct EnumState {
    own_pid: u32,
    out: Vec<WindowInfo>,
    owners: HashMap<u32, String>,
}

fn rect_of(r: &RECT) -> IRect {
    IRect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
}

fn exe_name(pid: u32) -> String {
    // SAFETY: Handle wird geschlossen; Puffer und Länge passen zusammen.
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return String::new() };
        let mut buf = [0u16; 520];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        if !ok {
            return String::new();
        }
        let path = from_wide(&buf[..(len as usize).min(buf.len())]);
        path.rsplit(['\\', '/']).next().unwrap_or("").to_string()
    }
}

/// Sichtbarer Rahmen ohne Schatten (global).
fn frame_bounds(h: windows::Win32::Foundation::HWND) -> Option<IRect> {
    let mut r = RECT::default();
    // SAFETY: r ist ein gültiger RECT-Puffer der angegebenen Größe.
    unsafe {
        if DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut RECT as *mut c_void, std::mem::size_of::<RECT>() as u32).is_ok() {
            return Some(rect_of(&r));
        }
        GetWindowRect(h, &mut r).ok()?;
    }
    Some(rect_of(&r))
}

unsafe extern "system" fn enum_windows(h: windows::Win32::Foundation::HWND, data: LPARAM) -> BOOL {
    // SAFETY: data zeigt auf den EnumState in `windows()`, der den synchronen Aufruf überlebt.
    let st = &mut *(data.0 as *mut EnumState);
    if !IsWindowVisible(h).as_bool() || IsIconic(h).as_bool() {
        return BOOL(1);
    }
    let mut cloaked = 0u32;
    if DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut c_void, 4).is_ok() && cloaked != 0 {
        return BOOL(1);
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(h, Some(&mut pid));
    if pid == st.own_pid {
        return BOOL(1);
    }
    let mut cls = [0u16; 128];
    let n = GetClassNameW(h, &mut cls).max(0) as usize;
    let class = String::from_utf16_lossy(&cls[..n.min(cls.len())]);
    if matches!(class.as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") {
        return BOOL(1);
    }
    let ex = GetWindowLongPtrW(h, GWL_EXSTYLE) as u32;
    // Werkzeugfenster ohne App-Fenster-Flag sind fast immer Hilfs-/Schwebefenster.
    if ex & WS_EX_TOOLWINDOW.0 != 0 && ex & WS_EX_APPWINDOW.0 == 0 {
        return BOOL(1);
    }
    if ex & WS_EX_LAYERED.0 != 0 {
        // Durchklickbare Überlagerungen und voll durchsichtige Fenster haben nichts zu fotografieren.
        if ex & WS_EX_TRANSPARENT.0 != 0 {
            return BOOL(1);
        }
        let (mut key, mut alpha, mut flags) = (Default::default(), 0u8, Default::default());
        if GetLayeredWindowAttributes(h, Some(&mut key), Some(&mut alpha), Some(&mut flags)).is_ok()
            && flags.0 & LWA_ALPHA.0 != 0
            && alpha == 0
        {
            return BOOL(1);
        }
    }
    let Some(rect) = frame_bounds(h) else { return BOOL(1) };
    if rect.width < 40 || rect.height < 40 {
        return BOOL(1);
    }
    let mut title = [0u16; 512];
    let tn = GetWindowTextW(h, &mut title).max(0) as usize;
    let owner = st.owners.entry(pid).or_insert_with(|| exe_name(pid)).clone();
    st.out.push(WindowInfo {
        hwnd: h.0 as isize,
        rect,
        title: String::from_utf16_lossy(&title[..tn.min(title.len())]),
        owner,
    });
    BOOL(1)
}

/// Sichtbare Fenster anderer Programme, von vorn nach hinten.
pub fn windows() -> Vec<WindowInfo> {
    // SAFETY: GetCurrentProcessId hat keine Voraussetzungen.
    let mut st = EnumState { own_pid: unsafe { GetCurrentProcessId() }, out: Vec::new(), owners: HashMap::new() };
    // SAFETY: Callback läuft synchron; `st` lebt über den Aufruf.
    unsafe {
        let _ = EnumWindows(Some(enum_windows), LPARAM(&mut st as *mut EnumState as isize));
    }
    st.out
}

// ---------------------------------------------------------------- Fensterbild

fn window_capture(handle: isize, expect: Option<IRect>) -> Result<RgbaImage> {
    init_com();
    let item = item_for_window(handle)?;
    let mut wgc = Wgc::start(&item)?;
    let (img, (cw, ch)) = wgc.grab(None, 1500, false)?.ok_or_else(|| anyhow!("Graphics Capture lieferte kein Bild"))?;
    drop(wgc);
    // Je nach Windows-Version enthält das Bild den unsichtbaren Resize-Rand (GetWindowRect) oder nur
    // den sichtbaren Rahmen. Im ersten Fall auf den sichtbaren Rahmen zuschneiden.
    let h = hwnd(handle);
    let mut wr = RECT::default();
    // SAFETY: wr ist gültig; ein totes Fenster liefert einen Fehler.
    let have_wr = unsafe { GetWindowRect(h, &mut wr).is_ok() };
    let fb = frame_bounds(h).or(expect);
    if let (true, Some(fb)) = (have_wr, fb) {
        let wr = rect_of(&wr);
        if wr != fb && cw == wr.width && ch == wr.height {
            let crop = IRect::new(fb.x - wr.x, fb.y - wr.y, fb.width, fb.height);
            if let Some(c) = knips_core::imageops::crop(&img, crop) {
                return Ok(c);
            }
        }
    }
    Ok(img)
}

/// Einzelnes Fenster freigestellt (auch verdeckte Teile), physische Pixel.
pub fn window_image(w: &WindowInfo) -> Result<RgbaImage> {
    window_capture(w.hwnd, Some(w.rect))
}

/// Eigenes Fenster fotografieren (Selbsttests). Darf nicht ausgeschlossen sein.
/// Rahmenlose, nicht aktivierbare Leisten (Karten, Menü, Einblendung …) lehnt Graphics Capture mit
/// E_INVALIDARG ab — die werden aus dem Bildschirmbild ausgeschnitten (sie liegen immer obenauf).
pub fn own_window_image(handle: isize) -> Result<RgbaImage> {
    window_capture(handle, None).or_else(|err| {
        log::debug!("Graphics Capture lehnt Fenster ab ({err:#}), schneide es aus dem Bildschirm aus");
        screen_cut(handle).map_err(|e| anyhow!("{err:#}; Bildschirmausschnitt: {e:#}"))
    })
}

fn screen_cut(handle: isize) -> Result<RgbaImage> {
    let r = frame_bounds(hwnd(handle)).ok_or_else(|| anyhow!("Fensterrahmen unbekannt"))?;
    let overlap = |m: &Monitor| m.rect.intersection(&r).map(|i| i.width as i64 * i.height as i64).unwrap_or(0);
    let m = crate::monitors::list().into_iter().max_by_key(overlap).ok_or_else(|| anyhow!("kein Bildschirm"))?;
    let local = r.offset(-m.rect.x, -m.rect.y);
    let shot = freeze_one(&m)?;
    knips_core::imageops::crop(&shot, local).ok_or_else(|| anyhow!("Fenster liegt außerhalb des Bildschirms"))
}

// ---------------------------------------------------------------- Bereichsaufnahme

enum Backend {
    Dda(Dda),
    Wgc(Wgc),
}

/// Wiederholte Aufnahme eines festen Bereichs (Scroll-Screenshot): eine Sitzung, viele Bilder.
pub struct RegionCapturer {
    rect: IRect,
    backend: Backend,
    last: Option<RgbaImage>,
}

impl RegionCapturer {
    /// `rect`: monitor-lokal, physische Pixel.
    pub fn new(monitor: &Monitor, rect: IRect) -> Result<Self> {
        init_com();
        let bounds = IRect::new(0, 0, monitor.rect.width, monitor.rect.height);
        let rect = rect.intersection(&bounds).ok_or_else(|| anyhow!("Bereich liegt außerhalb des Bildschirms"))?;
        let backend = match Dda::open(monitor) {
            Ok(d) => Backend::Dda(d),
            Err(e) => {
                log::debug!("Bereichsaufnahme: Desktop Duplication nicht möglich ({e:#}), nehme Graphics Capture");
                Backend::Wgc(Wgc::start(&item_for_monitor(monitor.id)?)?)
            }
        };
        let mut me = Self { rect, backend, last: None };
        // Erstes Bild gleich holen, damit `grab` nie leer zurückkommt.
        me.fetch(1500)?;
        if me.last.is_none() {
            bail!("Bereichsaufnahme lieferte kein erstes Bild");
        }
        Ok(me)
    }

    fn fetch(&mut self, timeout_ms: u64) -> Result<()> {
        let rect = Some(self.rect);
        let img = match &mut self.backend {
            Backend::Dda(d) => {
                let deadline = Instant::now() + Duration::from_millis(timeout_ms);
                loop {
                    let wait = (deadline.saturating_duration_since(Instant::now()).as_millis() as u32).clamp(1, 40);
                    if let Some(i) = d.grab(rect, wait)? {
                        break Some(i);
                    }
                    if Instant::now() >= deadline {
                        break None;
                    }
                }
            }
            Backend::Wgc(w) => w.grab(rect, timeout_ms, true)?.map(|(i, _)| i),
        };
        if let Some(i) = img {
            self.last = Some(i);
        }
        Ok(())
    }

    /// Aktuelles Bild des Bereichs (eigene Fenster ausgeschlossen, ohne Mauszeiger). Gab es seit dem
    /// letzten Aufruf kein neues Bild (Bildschirm unverändert), kommt das zuletzt gelieferte.
    pub fn grab(&mut self) -> Result<RgbaImage> {
        init_com();
        // Kurz warten: ein Bild pro ~150 ms wird ohnehin abgeholt, unveränderte Bildschirme melden
        // nichts und liefern dann das gemerkte Bild.
        self.fetch(30)?;
        self.last.clone().ok_or_else(|| anyhow!("kein Bild"))
    }
}

/// Erste Windows-Version, in der `WDA_EXCLUDEFROMCAPTURE` Fenster unsichtbar macht (Windows 10 2004).
const EXCLUDE_MIN_BUILD: u32 = 19041;

/// Kann Windows eigene Fenster aus Aufnahmen herausnehmen? Vor Windows 10 2004 wirkt
/// `WDA_EXCLUDEFROMCAPTURE` wie `WDA_MONITOR`: Das Fenster erscheint in jeder Aufnahme als schwarze
/// Fläche (beim Aufnahmerahmen wäre das ganze Video schwarz). Dann wird nichts gesetzt; die App blendet
/// eigene Fenster vor einem Standbild kurz aus (`hide_for_capture`).
pub fn exclusion_supported() -> bool {
    static R: OnceLock<bool> = OnceLock::new();
    *R.get_or_init(|| {
        #[cfg(feature = "dev")]
        if std::env::var_os("KNIPS_TEST_OLD_WINDOWS").is_some() {
            log::warn!("Windows vor 2004 simuliert (KNIPS_TEST_OLD_WINDOWS): eigene Fenster werden ausgeblendet");
            return false;
        }
        let build = super::system::build_number();
        // Unbekannt (0): lieber setzen — ab Windows 10 2004 ist das der Normalfall.
        let ok = build == 0 || build >= EXCLUDE_MIN_BUILD;
        if !ok {
            log::info!("Windows-Build {build} < {EXCLUDE_MIN_BUILD}: eigene Fenster werden vor Standbildern ausgeblendet");
        }
        ok
    })
}

/// `WDA_EXCLUDEFROMCAPTURE` setzen, wenn es wirkt (`exclusion_supported`). `false` = nicht gesetzt.
pub(crate) fn set_excluded(h: windows::Win32::Foundation::HWND, what: &str) -> bool {
    if !exclusion_supported() {
        return false;
    }
    // SAFETY: ungültige Handles ergeben nur einen Fehler.
    match unsafe { SetWindowDisplayAffinity(h, WDA_EXCLUDEFROMCAPTURE) } {
        Ok(()) => true,
        Err(e) => {
            log::warn!("{what}: aus Aufnahmen ausschließen fehlgeschlagen: {e}");
            false
        }
    }
}

/// Fenster aus allen Aufnahmen ausschließen (`WDA_EXCLUDEFROMCAPTURE`) bzw. wieder zulassen. Vor
/// Windows 10 2004 ohne Wirkung (siehe `exclusion_supported`).
pub fn exclude_from_capture(handle: isize, exclude: bool) {
    if exclude {
        set_excluded(hwnd(handle), "Fenster");
        return;
    }
    // SAFETY: ungültige Handles ergeben nur einen Fehler.
    if let Err(e) = unsafe { SetWindowDisplayAffinity(hwnd(handle), WDA_NONE) } {
        log::warn!("SetWindowDisplayAffinity fehlgeschlagen: {e}");
    }
}

/// Sichtbare unter `handles` ausblenden (für ein Standbild, wenn `exclusion_supported` nicht gilt)
/// und warten, bis der Bildschirm ohne sie gezeichnet ist. Liefert die ausgeblendeten Fenster.
pub fn hide_for_capture(handles: &[isize]) -> Vec<isize> {
    let mut hidden = Vec::new();
    for &h in handles {
        // SAFETY: ungültige Handles ergeben nur `false`.
        unsafe {
            if IsWindowVisible(hwnd(h)).as_bool() {
                let _ = ShowWindow(hwnd(h), SW_HIDE);
                hidden.push(h);
            }
        }
    }
    if !hidden.is_empty() {
        // Einige Bildwechsel abwarten, bis der Bildschirm ohne sie gezeichnet ist (DwmFlush kann bei
        // ruhendem Desktop warten, bis sich etwas ändert — deshalb feste Zeit).
        std::thread::sleep(Duration::from_millis(100));
    }
    hidden
}

/// Mit `hide_for_capture` ausgeblendete Fenster wieder zeigen, ohne sie zu aktivieren.
pub fn show_after_capture(handles: &[isize]) {
    for &h in handles {
        // SAFETY: ungültige Handles ergeben nur einen Fehler.
        unsafe {
            let _ = ShowWindow(hwnd(h), SW_SHOWNA);
        }
    }
}
