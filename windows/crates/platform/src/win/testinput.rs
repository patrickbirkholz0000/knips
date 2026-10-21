//! Simulierte Maus und Tastatur für Selbsttests (wie von der Hardware). Signaturen wie `mock::testinput`.

use std::sync::Once;
use std::time::Duration;

use anyhow::{bail, Result};
use knips_core::settings::KeyCombo;
use windows::core::w;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{BeginPaint, CreateSolidBrush, DeleteObject, EndPaint, FillRect, PAINTSTRUCT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEINPUT, MOUSE_EVENT_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetClientRect, GetMessageW, PostMessageW, PostQuitMessage,
    RegisterClassExW, SetCursorPos, SetWindowPos, HWND_TOPMOST, MA_NOACTIVATE, MSG, SWP_NOACTIVATE, SWP_SHOWWINDOW,
    WM_CLOSE, WM_DESTROY, WM_ERASEBKGND, WM_MOUSEACTIVATE, WM_PAINT, WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP,
};

use crate::types::IRect;

fn mouse(flags: MOUSE_EVENT_FLAGS) {
    let input = INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: 0, dwFlags: flags, time: 0, dwExtraInfo: 0 } } };
    // SAFETY: ein gültiges INPUT.
    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
}

pub fn move_to(x: i32, y: i32) {
    // SAFETY: einfacher Systemaufruf; erzeugt WM_MOUSEMOVE wie eine echte Bewegung.
    unsafe {
        let _ = SetCursorPos(x, y);
    }
}

/// Linke Maustaste von `from` nach `to` ziehen (globale physische Pixel), in Schritten.
pub fn drag(from: (i32, i32), to: (i32, i32), shift: bool) {
    move_to(from.0, from.1);
    std::thread::sleep(Duration::from_millis(80));
    if shift {
        crate::win::hotkeys::press_modifier(true);
    }
    mouse(MOUSEEVENTF_LEFTDOWN);
    for i in 1..=12 {
        std::thread::sleep(Duration::from_millis(25));
        move_to(from.0 + (to.0 - from.0) * i / 12, from.1 + (to.1 - from.1) * i / 12);
    }
    std::thread::sleep(Duration::from_millis(60));
    mouse(MOUSEEVENTF_LEFTUP);
    if shift {
        crate::win::hotkeys::press_modifier(false);
    }
}

pub fn click(x: i32, y: i32) {
    move_to(x, y);
    std::thread::sleep(Duration::from_millis(80));
    mouse(MOUSEEVENTF_LEFTDOWN);
    std::thread::sleep(Duration::from_millis(40));
    mouse(MOUSEEVENTF_LEFTUP);
}

/// Taste (Virtual-Key) mit Modifier-Bits drücken und loslassen.
pub fn key(vk: u32, mods: u32) {
    crate::win::hotkeys::simulate(KeyCombo::new(vk, mods));
}

// ---------------------------------------------------------------- Testfläche

/// Farben der Balken der Testfläche (`show_pattern`), von links nach rechts.
pub const PATTERN_COLORS: [[u8; 3]; 8] = [
    [235, 235, 235],
    [235, 235, 16],
    [16, 235, 235],
    [16, 235, 16],
    [235, 16, 235],
    [235, 16, 16],
    [16, 16, 235],
    [128, 128, 128],
];

/// Schwebende Testfläche mit Farbbalken (nur GDI — kein Direct3D im Prozess). Schließt beim Drop.
pub struct Pattern {
    hwnd: isize,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Pattern {
    pub fn hwnd(&self) -> isize {
        self.hwnd
    }
}

impl Drop for Pattern {
    fn drop(&mut self) {
        // SAFETY: ein totes Fenster ergibt nur einen Fehler; der Thread endet dann ohnehin.
        unsafe {
            let _ = PostMessageW(Some(HWND(self.hwnd as *mut std::ffi::c_void)), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

unsafe extern "system" fn pattern_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // SAFETY: Standard-Fensterprozedur; GDI-Objekte werden nach Gebrauch gelöscht.
    unsafe {
        match msg {
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let dc = BeginPaint(hwnd, &mut ps);
                let mut rc = RECT::default();
                let _ = GetClientRect(hwnd, &mut rc);
                let n = PATTERN_COLORS.len() as i32;
                for (i, c) in PATTERN_COLORS.iter().enumerate() {
                    let i = i as i32;
                    let bar = RECT { left: rc.right * i / n, top: 0, right: rc.right * (i + 1) / n, bottom: rc.bottom };
                    let brush = CreateSolidBrush(COLORREF(c[0] as u32 | (c[1] as u32) << 8 | (c[2] as u32) << 16));
                    FillRect(dc, &bar, brush);
                    let _ = DeleteObject(brush.into());
                }
                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            WM_ERASEBKGND => LRESULT(1),
            WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
}

/// Testfläche über `rect` (global, physische Pixel) zeigen, ohne den Fokus zu nehmen.
pub fn show_pattern(rect: IRect) -> Result<Pattern> {
    static CLASS: Once = Once::new();
    let (tx, rx) = std::sync::mpsc::channel::<std::result::Result<isize, String>>();
    let thread = std::thread::Builder::new().name("knips-testflaeche".into()).spawn(move || {
        // SAFETY: Fenster wird auf diesem Thread angelegt, bedient und zerstört.
        unsafe {
            let _ = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            let hinst = GetModuleHandleW(None).map(|h| HINSTANCE(h.0)).unwrap_or_default();
            CLASS.call_once(|| {
                let wc = WNDCLASSEXW {
                    cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                    lpfnWndProc: Some(pattern_proc),
                    hInstance: hinst,
                    lpszClassName: w!("KnipsTestflaeche"),
                    ..Default::default()
                };
                RegisterClassExW(&wc);
            });
            let hwnd = match CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                w!("KnipsTestflaeche"),
                w!("Knips Testfläche"),
                WS_POPUP,
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                None,
                None,
                Some(hinst),
                None,
            ) {
                Ok(h) => h,
                Err(e) => {
                    let _ = tx.send(Err(e.to_string()));
                    return;
                }
            };
            let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), rect.x, rect.y, rect.width, rect.height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            let _ = tx.send(Ok(hwnd.0 as isize));
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                DispatchMessageW(&msg);
            }
        }
    })?;
    match rx.recv() {
        Ok(Ok(hwnd)) => Ok(Pattern { hwnd, thread: Some(thread) }),
        Ok(Err(e)) => {
            let _ = thread.join();
            bail!("Testfläche: {e}")
        }
        Err(_) => {
            let _ = thread.join();
            bail!("Testfläche: Thread beendet")
        }
    }
}
