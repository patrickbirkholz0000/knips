//! Auswahl-Overlay (Port von `SelectionOverlay.swift`) und Rahmenfenster.
//!
//! Aufbau:
//! - `layout.rs`: reine Geometrie (auf dem Mac getestet).
//! - `brand.rs`: Farben, Schriften, Strichstärken (Werte aus tokens.css, docs/design.md).
//! - `gfx.rs`: Direct2D/DirectWrite-Zeichnen, geteilt zwischen Fenster und Offscreen-Test.
//! - `frame.rs`: gestrichelter Rahmen (`FrameWindow`).
//! - hier: öffentliche Schnittstelle, Overlay-Thread, Fensterprozedur, Eingabe.
//!
//! Threading: `present` startet einen eigenen UI-Thread (Per-Monitor-V2). Dort liegt der gesamte
//! Zustand in einem `thread_local` (`OV`); die Fensterprozedur greift per `try_borrow_mut` zu und
//! ruft nie etwas auf, das synchron Nachrichten zurückschickt, während der Zustand geborgt ist
//! (Beenden, Vordergrund, Capture laufen immer außerhalb). Ergebnis → `PostQuitMessage`; nach der
//! Schleife: Fenster zerstören, Vordergrund zurück, dann `on_done` genau einmal.

mod brand;
mod frame;
mod gfx;
mod layout;

use std::cell::RefCell;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Once;

use anyhow::{anyhow, Result};
use knips_core::RgbaImage;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::{BeginPaint, EndPaint, InvalidateRect, PAINTSTRUCT};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::HiDpi::{SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::types::{Frozen, IRect, Monitor, WindowInfo};
use gfx::{Factories, Scene, Target};
use layout::{Kind, RectF};

pub use frame::FrameWindow;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    Screenshot,
    Recording,
    Text,
    Scroll,
}

#[derive(Clone, Debug)]
pub enum Selection {
    /// Rechteck monitor-lokal, physische Pixel.
    Area { monitor: Monitor, rect: IRect },
    Window { window: WindowInfo, monitor: Monitor },
    FullScreen { monitor: Monitor },
    Cancelled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameColor {
    /// Aufnahme-Rot (#E8523F) — Bildschirmaufnahme.
    Recording,
    /// Königsblau hell (#9AA6FF) — Scroll-Screenshot.
    Scroll,
}

fn kind_of(p: Purpose) -> Kind {
    match p {
        Purpose::Screenshot => Kind::Screenshot,
        Purpose::Recording => Kind::Recording,
        Purpose::Text => Kind::Text,
        Purpose::Scroll => Kind::Scroll,
    }
}

// ---------------------------------------------------------------------------------------------
// Öffentliche Schnittstelle
// ---------------------------------------------------------------------------------------------

static ACTIVE: AtomicBool = AtomicBool::new(false);
static CANCEL_REQ: AtomicBool = AtomicBool::new(false);
static THREAD_ID: AtomicU32 = AtomicU32::new(0);

/// Eigene Thread-Nachricht (ohne Fenster) für `cancel()`.
const WM_KNIPS_CANCEL: u32 = WM_APP + 1;

/// Auswahl-Overlay über allen Monitoren mit Standbild. Kehrt sofort zurück; `on_done` kommt
/// genau einmal aus dem Overlay-Thread. Ziehen = Bereich (Umschalt = Quadrat), Leertaste =
/// Fenstermodus, Eingabe = ganzer Bildschirm, Esc/Rechtsklick = Abbruch.
pub fn present(
    frozen: Vec<Frozen>,
    windows: Vec<WindowInfo>,
    purpose: Purpose,
    window_mode: bool,
    on_done: Box<dyn FnOnce(Selection) + Send>,
) -> Result<()> {
    if frozen.is_empty() {
        return Err(anyhow!("kein Bildschirm"));
    }
    if ACTIVE.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
        return Err(anyhow!("Auswahl läuft bereits"));
    }
    CANCEL_REQ.store(false, Ordering::Release);
    let spawned = std::thread::Builder::new().name("knips-overlay".into()).spawn(move || {
        overlay_thread(frozen, windows, purpose, window_mode, on_done);
    });
    if let Err(e) = spawned {
        ACTIVE.store(false, Ordering::Release);
        return Err(anyhow!("Overlay-Thread: {e}"));
    }
    Ok(())
}

pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

#[cfg(feature = "dev")]
static TEST_CAPTURABLE: AtomicBool = AtomicBool::new(false);

/// Selbsttests: Overlay nicht aus Aufnahmen ausschließen, damit ein Test fotografieren kann, was auf dem
/// Bildschirm erscheint.
#[cfg(feature = "dev")]
pub fn set_capturable_for_tests(on: bool) {
    TEST_CAPTURABLE.store(on, Ordering::Release);
}

fn capturable_for_tests() -> bool {
    #[cfg(feature = "dev")]
    {
        TEST_CAPTURABLE.load(Ordering::Acquire)
    }
    #[cfg(not(feature = "dev"))]
    {
        false
    }
}

/// Bricht eine laufende Auswahl ab (`on_done(Cancelled)`). Thread-sicher.
pub fn cancel() {
    if !is_active() {
        return;
    }
    CANCEL_REQ.store(true, Ordering::Release);
    let tid = THREAD_ID.load(Ordering::Acquire);
    if tid != 0 {
        // Schlägt fehl, wenn der Thread gerade endet — dann ist ohnehin alles vorbei.
        unsafe {
            let _ = PostThreadMessageW(tid, WM_KNIPS_CANCEL, WPARAM(0), LPARAM(0));
        }
    }
}

/// Overlay eines Monitors in ein Bild rendern (Selbsttest `selection`). `mouse` monitor-lokal.
pub fn render_offscreen(
    frozen: &Frozen,
    windows: &[WindowInfo],
    purpose: Purpose,
    window_mode: bool,
    mouse: (i32, i32),
    selection: Option<IRect>,
) -> Result<RgbaImage> {
    let m = &frozen.monitor;
    let global = (m.rect.x + mouse.0, m.rect.y + mouse.1);
    let sel = selection.map(|r| RectF::new(r.x as f64, r.y as f64, r.width as f64, r.height as f64));
    let rects = window_rects(windows);
    let scene = build_scene(m, (frozen.image.width() as i32, frozen.image.height() as i32), &rects, kind_of(purpose), window_mode, Some(global), sel);
    // Eigener Thread: COM sauber initialisieren/freigeben, ohne den Aufrufer zu berühren.
    std::thread::scope(|s| {
        s.spawn(|| -> Result<RgbaImage> {
            let _com = ComScope::new();
            let f = Factories::new().map_err(|e| anyhow!("Direct2D: {e}"))?;
            gfx::render_to_image(&f, &frozen.image, &scene).map_err(|e| anyhow!("Rendern: {e}"))
        })
        .join()
        .map_err(|_| anyhow!("Rendern abgestürzt"))?
    })
}

/// Aufnahmerahmen in ein Bild rendern (Selbsttest `selection`): Fenster um einen Bereich von `area`
/// Pixeln bei Skalierung `scale`, transparent bis auf den Rahmen — dieselbe Zeichnung wie `FrameWindow`.
pub fn render_frame_offscreen(area: (i32, i32), scale: f64, color: FrameColor) -> Result<RgbaImage> {
    std::thread::scope(|s| {
        s.spawn(|| -> Result<RgbaImage> {
            let _com = ComScope::new();
            frame::render_offscreen(area, scale, color)
        })
        .join()
        .map_err(|_| anyhow!("Rendern abgestürzt"))?
    })
}

struct ComScope(bool);

impl ComScope {
    fn new() -> Self {
        // Paarig zu einem erfolgreichen CoInitializeEx; bei RPC_E_CHANGED_MODE nichts freigeben.
        ComScope(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok())
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() };
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Gemeinsame Szene (Fenster und Offscreen)
// ---------------------------------------------------------------------------------------------

type WinRect = (i32, i32, i32, i32);

fn window_rects(windows: &[WindowInfo]) -> Vec<WinRect> {
    windows.iter().map(|w| (w.rect.x, w.rect.y, w.rect.width, w.rect.height)).collect()
}

/// Was ein Monitor gerade zeigt. `mouse` global; Auswahl und Loch in px.
fn build_scene(
    monitor: &Monitor,
    size: (i32, i32),
    rects: &[WinRect],
    kind: Kind,
    window_mode: bool,
    mouse: Option<(i32, i32)>,
    selection: Option<RectF>,
) -> Scene {
    let mouse_local = mouse.filter(|&(x, y)| monitor.rect.contains(x, y)).map(|(x, y)| (x - monitor.rect.x, y - monitor.rect.y));
    // Loch: Auswahl, sonst im Fenstermodus das Fenster unter dem Zeiger (auch von anderen Monitoren).
    let hole = selection.or_else(|| {
        if !window_mode {
            return None;
        }
        let (gx, gy) = mouse?;
        let i = layout::hovered_window(rects, gx, gy)?;
        layout::window_hole(rects[i], (monitor.rect.x, monitor.rect.y), size.0 as f64, size.1 as f64)
    });
    Scene {
        kind,
        window_mode,
        scale: monitor.scale,
        w_px: size.0,
        h_px: size.1,
        mouse: mouse_local,
        hole,
        selection,
        work_bottom_pt: (monitor.work.bottom() - monitor.rect.y) as f64 / monitor.scale,
    }
}

// ---------------------------------------------------------------------------------------------
// Zustand des laufenden Overlays (nur auf dem Overlay-Thread)
// ---------------------------------------------------------------------------------------------

struct MonWin {
    hwnd: HWND,
    frozen: Frozen,
    /// Wird bei Geräteverlust verworfen und beim nächsten Zeichnen neu gebaut.
    target: Option<Target>,
    /// Zuletzt gezeichnete bzw. angeforderte Szene; Änderung → Neuzeichnen.
    scene: Option<Scene>,
    size: (i32, i32),
    dpi: f32,
    drag_start: Option<(f64, f64)>,
    selection: Option<RectF>,
}

impl Drop for MonWin {
    fn drop(&mut self) {
        // Renderziel vor dem Fenster freigeben; Zerstören nur auf dem Besitzer-Thread (hier immer).
        self.target = None;
        unsafe {
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

struct Overlay {
    facs: Factories,
    mons: Vec<MonWin>,
    windows: Vec<WindowInfo>,
    rects: Vec<WinRect>,
    purpose: Purpose,
    window_mode: bool,
    dragging: bool,
    /// Zeiger, global, px.
    mouse: (i32, i32),
    result: Option<Selection>,
}

thread_local! {
    static OV: RefCell<Option<Overlay>> = const { RefCell::new(None) };
}

/// Zugriff auf den Zustand; `None`, wenn keiner da ist oder er gerade geborgt ist (Wiedereintritt).
fn with_ov<R>(f: impl FnOnce(&mut Overlay) -> R) -> Option<R> {
    OV.with(|c| match c.try_borrow_mut() {
        Ok(mut g) => g.as_mut().map(f),
        Err(_) => None,
    })
}

impl Overlay {
    fn index(&self, hwnd: HWND) -> Option<usize> {
        self.mons.iter().position(|m| m.hwnd == hwnd)
    }

    fn scene_for(&self, i: usize) -> Scene {
        let m = &self.mons[i];
        build_scene(&m.frozen.monitor, m.size, &self.rects, kind_of(self.purpose), self.window_mode, Some(self.mouse), m.selection)
    }

    /// Nur neu zeichnen lassen, wenn sich für den Monitor etwas geändert hat.
    fn refresh_all(&mut self) {
        for i in 0..self.mons.len() {
            let sc = self.scene_for(i);
            let m = &mut self.mons[i];
            if m.scene.as_ref() != Some(&sc) {
                m.scene = Some(sc);
                unsafe {
                    let _ = InvalidateRect(Some(m.hwnd), None, false);
                }
            }
        }
    }

    fn paint(&mut self, i: usize) {
        let facs = &self.facs;
        let m = &mut self.mons[i];
        if m.target.is_none() {
            match Target::for_hwnd(facs, m.hwnd, m.size.0, m.size.1, m.dpi, &m.frozen.image) {
                Ok(t) => m.target = Some(t),
                Err(e) => {
                    log::error!("Overlay: Renderziel: {e}");
                    return;
                }
            }
        }
        let Some(scene) = m.scene.clone() else { return };
        if let Some(t) = &m.target {
            if let Err(e) = t.render(facs, &scene) {
                if e.code() == gfx::RECREATE_TARGET {
                    m.target = None;
                    unsafe {
                        let _ = InvalidateRect(Some(m.hwnd), None, false);
                    }
                } else {
                    log::error!("Overlay: Zeichnen: {e}");
                }
            }
        }
    }

    fn on_move(&mut self, i: usize, x: i32, y: i32, shift: bool) {
        let r = self.mons[i].frozen.monitor.rect;
        self.mouse = (r.x + x, r.y + y);
        let m = &mut self.mons[i];
        if let Some(start) = m.drag_start {
            let (w, h) = (m.size.0 as f64, m.size.1 as f64);
            let p = layout::clamp_pt((x as f64, y as f64), w, h);
            m.selection = Some(layout::drag_rect(start, p, shift, w, h));
        }
        self.refresh_all();
    }

    fn on_down(&mut self, i: usize, x: i32, y: i32) {
        let r = self.mons[i].frozen.monitor.rect;
        self.mouse = (r.x + x, r.y + y);
        let m = &mut self.mons[i];
        m.drag_start = Some(layout::clamp_pt((x as f64, y as f64), m.size.0 as f64, m.size.1 as f64));
        m.selection = None;
        self.dragging = true;
        self.refresh_all();
    }

    /// Loslassen. `Some` = Auswahl fertig.
    fn on_up(&mut self, i: usize, x: i32, y: i32) -> Option<Selection> {
        let r = self.mons[i].frozen.monitor.rect;
        self.mouse = (r.x + x, r.y + y);
        self.dragging = false;
        let m = &mut self.mons[i];
        m.drag_start.take()?; // Loslassen ohne Drücken auf diesem Fenster ignorieren
        let min = layout::min_selection_px(m.frozen.monitor.scale);
        if let Some(sel) = m.selection {
            if layout::big_enough(&sel, min) {
                let (ix, iy, iw, ih) = layout::integral(&sel);
                return Some(Selection::Area { monitor: m.frozen.monitor.clone(), rect: IRect::new(ix, iy, iw, ih) });
            }
        }
        m.selection = None;
        if self.window_mode {
            if let Some(wi) = layout::hovered_window(&self.rects, self.mouse.0, self.mouse.1) {
                return Some(Selection::Window { window: self.windows[wi].clone(), monitor: self.mons[i].frozen.monitor.clone() });
            }
        }
        self.refresh_all();
        None
    }

    /// Ziehen abbrechen (Capture verloren).
    fn abort_drag(&mut self) {
        if !self.dragging {
            return;
        }
        self.dragging = false;
        for m in &mut self.mons {
            m.drag_start = None;
            m.selection = None;
        }
        self.refresh_all();
    }

    fn on_key(&mut self, vk: u16, repeat: bool, cursor: (i32, i32)) -> Option<Selection> {
        if vk == VK_ESCAPE.0 {
            return Some(Selection::Cancelled);
        }
        if vk == VK_SPACE.0 {
            if !repeat && !self.dragging {
                self.window_mode = !self.window_mode;
                self.refresh_all();
            }
            return None;
        }
        if vk == VK_RETURN.0 {
            // Enter und Num-Enter: ganzer Bildschirm unter dem Zeiger
            self.mouse = cursor;
            let m = self
                .mons
                .iter()
                .find(|m| m.frozen.monitor.rect.contains(cursor.0, cursor.1))
                .or_else(|| self.mons.first())?;
            return Some(Selection::FullScreen { monitor: m.frozen.monitor.clone() });
        }
        None
    }
}

// ---------------------------------------------------------------------------------------------
// Overlay-Thread
// ---------------------------------------------------------------------------------------------

/// Gibt `ACTIVE`/`THREAD_ID` frei — normal per `release` vor `on_done`, sonst beim Abwickeln eines
/// Panics. Ohne ihn bliebe `ACTIVE` nach einem Absturz stehen und jede weitere Auswahl würde mit
/// „Auswahl läuft bereits“ abgelehnt.
struct ActiveGuard(bool);

impl ActiveGuard {
    fn release(mut self) {
        self.0 = false;
        THREAD_ID.store(0, Ordering::Release);
        ACTIVE.store(false, Ordering::Release);
    }
}

impl Drop for ActiveGuard {
    fn drop(&mut self) {
        if self.0 {
            log::error!("Overlay-Thread abgestürzt — Auswahl freigegeben");
            THREAD_ID.store(0, Ordering::Release);
            ACTIVE.store(false, Ordering::Release);
        }
    }
}

fn overlay_thread(frozen: Vec<Frozen>, windows: Vec<WindowInfo>, purpose: Purpose, window_mode: bool, on_done: Box<dyn FnOnce(Selection) + Send>) {
    let guard = ActiveGuard(true);
    unsafe {
        let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        // Nachrichtenwarteschlange anlegen, bevor die Thread-ID veröffentlicht wird (PostThreadMessage).
        let mut msg = MSG::default();
        let _ = PeekMessageW(&mut msg, None, WM_USER, WM_USER, PM_NOREMOVE);
    }
    let prev_fg = unsafe { GetForegroundWindow() };

    match unsafe { create_overlay(frozen, windows, purpose, window_mode) } {
        Err(e) => {
            log::error!("Overlay: {e}");
            guard.release();
            on_done(Selection::Cancelled);
            return;
        }
        Ok(ov) => OV.with(|c| *c.borrow_mut() = Some(ov)),
    }
    unsafe {
        THREAD_ID.store(GetCurrentThreadId(), Ordering::Release);
        activate_under_cursor();
        if CANCEL_REQ.load(Ordering::Acquire) {
            finish(Selection::Cancelled);
        }

        let mut msg = MSG::default();
        loop {
            let r = GetMessageW(&mut msg, None, 0, 0);
            if r.0 <= 0 {
                break; // WM_QUIT (0) oder Fehler (-1)
            }
            if msg.hwnd.0.is_null() && msg.message == WM_KNIPS_CANCEL {
                finish(Selection::Cancelled);
                continue;
            }
            DispatchMessageW(&msg);
        }
    }

    // Aufräumen: Zustand herausnehmen (außerhalb des Borrows), Fenster zerstören, Vordergrund zurück.
    let ov = OV.with(|c| c.borrow_mut().take());
    let result = ov.as_ref().and_then(|o| o.result.clone()).unwrap_or(Selection::Cancelled);
    drop(ov);
    unsafe {
        if !prev_fg.0.is_null() && IsWindow(Some(prev_fg)).as_bool() {
            force_foreground(prev_fg);
        }
    }
    guard.release();
    on_done(result);
}

static CLASS_ONCE: Once = Once::new();
const CLASS_NAME: PCWSTR = w!("KnipsSelectionOverlay");

fn instance() -> HINSTANCE {
    unsafe { GetModuleHandleW(None) }.map(|h| HINSTANCE(h.0)).unwrap_or_default()
}

fn ensure_class() {
    CLASS_ONCE.call_once(|| unsafe {
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: instance(),
            hCursor: LoadCursorW(None, IDC_CROSS).unwrap_or_default(),
            lpszClassName: CLASS_NAME,
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            log::error!("Overlay: Fensterklasse nicht registrierbar");
        }
    });
}

unsafe fn cursor_pos() -> (i32, i32) {
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    (p.x, p.y)
}

/// Fenster pro Monitor anlegen, erstes Bild zeichnen, dann anzeigen.
unsafe fn create_overlay(frozen: Vec<Frozen>, windows: Vec<WindowInfo>, purpose: Purpose, window_mode: bool) -> Result<Overlay> {
    unsafe {
        ensure_class();
        let facs = Factories::new().map_err(|e| anyhow!("Direct2D: {e}"))?;
        let rects = window_rects(&windows);
        let mouse = cursor_pos();
        let hinst = instance();
        let mut ov = Overlay { facs, mons: Vec::new(), windows, rects, purpose, window_mode, dragging: false, mouse, result: None };

        for f in frozen {
            let r = f.monitor.rect;
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                CLASS_NAME,
                w!("Knips Auswahl"),
                WS_POPUP,
                r.x,
                r.y,
                r.width,
                r.height,
                None,
                None,
                Some(hinst),
                None,
            )
            .map_err(|e| anyhow!("Fenster: {e}"))?;
            // Ab hier gehört das Fenster der MonWin (Drop zerstört es, auch im Fehlerfall).
            // Vor Windows 10 2004 nicht gesetzt (wäre schwarz statt unsichtbar); das Standbild
            // ist dann ohnehin schon aufgenommen.
            if !capturable_for_tests() {
                crate::win::capture::set_excluded(hwnd, "Overlay");
            }
            let size = (f.image.width() as i32, f.image.height() as i32);
            let dpi = (f.monitor.scale * 96.0) as f32;
            let mut mon = MonWin { hwnd, frozen: f, target: None, scene: None, size, dpi, drag_start: None, selection: None };
            mon.target = Some(
                Target::for_hwnd(&ov.facs, hwnd, r.width, r.height, dpi, &mon.frozen.image).map_err(|e| anyhow!("Renderziel: {e}"))?,
            );
            ov.mons.push(mon);
        }

        // erstes Bild vor dem Anzeigen, damit nie ein leeres Fenster aufblitzt
        for i in 0..ov.mons.len() {
            let sc = ov.scene_for(i);
            ov.mons[i].scene = Some(sc);
            ov.paint(i);
        }
        for m in &ov.mons {
            let r = m.frozen.monitor.rect;
            let _ = SetWindowPos(m.hwnd, Some(HWND_TOPMOST), r.x, r.y, r.width, r.height, SWP_SHOWWINDOW | SWP_NOACTIVATE);
        }
        Ok(ov)
    }
}

/// Fenster unter dem Zeiger (sonst das erste) in den Vordergrund holen, damit es Tasten bekommt.
unsafe fn activate_under_cursor() {
    unsafe {
        let cur = cursor_pos();
        let target = with_ov(|ov| {
            ov.mons.iter().find(|m| m.frozen.monitor.rect.contains(cur.0, cur.1)).or_else(|| ov.mons.first()).map(|m| m.hwnd)
        })
        .flatten();
        if let Some(h) = target {
            force_foreground(h);
            SetCursor(LoadCursorW(None, IDC_CROSS).ok());
        }
    }
}

/// Fenster robust in den Vordergrund holen: Eingabewarteschlange des Vordergrundthreads anhängen,
/// notfalls mit einem Alt-Tipp (hebt die Vordergrundsperre auf).
unsafe fn force_foreground(hwnd: HWND) {
    unsafe { force_foreground_ex(hwnd, true) }
}

/// Mausbewegung über einem Fenster, das nicht Vordergrund ist: höchstens alle 250 ms versuchen,
/// nie mit Alt-Tipp (sonst würde ein dauerhaft scheiternder Versuch bei jeder Bewegung Tasten senden).
unsafe fn foreground_on_hover(hwnd: HWND) {
    thread_local! {
        static LAST: std::cell::Cell<Option<std::time::Instant>> = const { std::cell::Cell::new(None) };
    }
    let now = std::time::Instant::now();
    let due = LAST.with(|l| match l.get() {
        Some(t) if now.duration_since(t) < std::time::Duration::from_millis(250) => false,
        _ => {
            l.set(Some(now));
            true
        }
    });
    if due {
        unsafe { force_foreground_ex(hwnd, false) }
    }
}

unsafe fn force_foreground_ex(hwnd: HWND, alt_tap: bool) {
    unsafe {
        if GetForegroundWindow() == hwnd {
            return;
        }
        let me = GetCurrentThreadId();
        let fg = GetForegroundWindow();
        let fg_tid = if fg.0.is_null() { 0 } else { GetWindowThreadProcessId(fg, None) };
        let attached = fg_tid != 0 && fg_tid != me && AttachThreadInput(me, fg_tid, true).as_bool();
        let _ = BringWindowToTop(hwnd);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus(Some(hwnd));
        if attached {
            let _ = AttachThreadInput(me, fg_tid, false);
        }
        if alt_tap && GetForegroundWindow() != hwnd {
            let key = |flags: KEYBD_EVENT_FLAGS| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VK_MENU, wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
            };
            let inputs = [key(KEYBD_EVENT_FLAGS(0)), key(KEYEVENTF_KEYUP)];
            SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(Some(hwnd));
        }
    }
}

/// Auswahl beenden: Ergebnis merken (das erste gewinnt), Fenster sofort ausblenden, Schleife verlassen.
/// Nie aus einem `with_ov`-Aufruf heraus rufen.
unsafe fn finish(sel: Selection) {
    let hwnds = with_ov(|ov| {
        if ov.result.is_some() {
            return None;
        }
        ov.result = Some(sel);
        Some(ov.mons.iter().map(|m| m.hwnd).collect::<Vec<_>>())
    })
    .flatten();
    if let Some(list) = hwnds {
        unsafe {
            for h in list {
                let _ = ShowWindow(h, SW_HIDE);
            }
            PostQuitMessage(0);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Fensterprozedur
// ---------------------------------------------------------------------------------------------

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // Kein Panic über die FFI-Grenze: bei einem Fehler Auswahl beenden.
    match catch_unwind(AssertUnwindSafe(|| unsafe { handle(hwnd, msg, wp, lp) })) {
        Ok(Some(r)) => r,
        Ok(None) => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
        Err(_) => {
            log::error!("Overlay: Panic in der Fensterprozedur");
            unsafe {
                PostQuitMessage(1);
                DefWindowProcW(hwnd, msg, wp, lp)
            }
        }
    }
}

fn lp_xy(lp: LPARAM) -> (i32, i32) {
    // Vorzeichenbehaftet: bei SetCapture sind Koordinaten außerhalb des Fensters negativ.
    ((lp.0 & 0xFFFF) as u16 as i16 as i32, ((lp.0 >> 16) & 0xFFFF) as u16 as i16 as i32)
}

unsafe fn handle(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> Option<LRESULT> {
    unsafe {
        match msg {
            WM_ERASEBKGND => Some(LRESULT(1)),
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                BeginPaint(hwnd, &mut ps);
                with_ov(|ov| {
                    if let Some(i) = ov.index(hwnd) {
                        ov.paint(i);
                    }
                });
                let _ = EndPaint(hwnd, &ps);
                Some(LRESULT(0))
            }
            WM_SIZE => {
                let mut rc = windows::Win32::Foundation::RECT::default();
                if GetClientRect(hwnd, &mut rc).is_ok() {
                    with_ov(|ov| {
                        if let Some(i) = ov.index(hwnd) {
                            if let Some(t) = &ov.mons[i].target {
                                t.resize(rc.right - rc.left, rc.bottom - rc.top);
                            }
                        }
                    });
                }
                Some(LRESULT(0))
            }
            WM_MOUSEACTIVATE => Some(LRESULT(MA_ACTIVATE as isize)),
            WM_SETCURSOR => {
                if (lp.0 & 0xFFFF) as u32 == HTCLIENT {
                    SetCursor(LoadCursorW(None, IDC_CROSS).ok());
                    Some(LRESULT(1))
                } else {
                    None
                }
            }
            WM_MOUSEMOVE => {
                let (x, y) = lp_xy(lp);
                let shift = wp.0 & 0x0004 != 0; // MK_SHIFT
                let idle = with_ov(|ov| {
                    let i = ov.index(hwnd)?;
                    ov.on_move(i, x, y, shift);
                    Some(!ov.dragging)
                })
                .flatten();
                // Wie auf dem Mac: das Fenster unter dem Zeiger wird Schlüsselfenster.
                if idle == Some(true) && GetForegroundWindow() != hwnd {
                    foreground_on_hover(hwnd);
                }
                Some(LRESULT(0))
            }
            WM_LBUTTONDOWN => {
                let (x, y) = lp_xy(lp);
                with_ov(|ov| {
                    if let Some(i) = ov.index(hwnd) {
                        ov.on_down(i, x, y);
                    }
                });
                SetCapture(hwnd);
                Some(LRESULT(0))
            }
            WM_LBUTTONUP => {
                let (x, y) = lp_xy(lp);
                let done = with_ov(|ov| {
                    let i = ov.index(hwnd)?;
                    ov.on_up(i, x, y)
                })
                .flatten();
                let _ = ReleaseCapture();
                if let Some(sel) = done {
                    finish(sel);
                }
                Some(LRESULT(0))
            }
            WM_RBUTTONDOWN => {
                finish(Selection::Cancelled);
                Some(LRESULT(0))
            }
            WM_KEYDOWN => {
                let repeat = (lp.0 >> 30) & 1 != 0;
                let cur = cursor_pos();
                let done = with_ov(|ov| ov.on_key(wp.0 as u16, repeat, cur)).flatten();
                if let Some(sel) = done {
                    finish(sel);
                }
                Some(LRESULT(0))
            }
            WM_CAPTURECHANGED => {
                // Capture an ein fremdes Fenster verloren (z. B. Alt+Tab): Ziehen verwerfen.
                if lp.0 != hwnd.0 as isize {
                    with_ov(|ov| ov.abort_drag());
                }
                Some(LRESULT(0))
            }
            WM_CLOSE | WM_KNIPS_CANCEL => {
                finish(Selection::Cancelled);
                Some(LRESULT(0))
            }
            // Feste Größe: Skalierungswechsel während der Auswahl nicht nachziehen.
            WM_DPICHANGED => Some(LRESULT(0)),
            _ => None,
        }
    }
}
