//! Bildschirme: EnumDisplayMonitors + GetMonitorInfoW + GetDpiForMonitor.

use std::ffi::c_void;

use windows::core::BOOL;
use windows::Win32::Foundation::{LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, MONITORINFOF_PRIMARY};

use super::util::from_wide;
use crate::types::{IRect, Monitor};

fn irect(r: &RECT) -> IRect {
    IRect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
}

unsafe extern "system" fn enum_proc(hmon: HMONITOR, _hdc: HDC, _rc: *mut RECT, data: LPARAM) -> BOOL {
    // SAFETY: `data` zeigt auf den Vec in `list()`, der den ganzen (synchronen) Aufruf überlebt.
    let out = &mut *(data.0 as *mut Vec<Monitor>);
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    if GetMonitorInfoW(hmon, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO).as_bool() {
        let (mut dx, mut dy) = (96u32, 96u32);
        let scale = match GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) {
            Ok(()) if dx > 0 => dx as f64 / 96.0,
            _ => 1.0,
        };
        out.push(Monitor {
            id: hmon.0 as isize,
            name: from_wide(&info.szDevice),
            rect: irect(&info.monitorInfo.rcMonitor),
            work: irect(&info.monitorInfo.rcWork),
            scale,
            primary: info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
        });
    }
    BOOL(1)
}

/// Alle angeschlossenen Bildschirme (Reihenfolge der Windows-Aufzählung).
pub fn list() -> Vec<Monitor> {
    let mut v: Vec<Monitor> = Vec::new();
    // SAFETY: Callback läuft synchron im Aufruf; `v` lebt länger.
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(enum_proc), LPARAM(&mut v as *mut Vec<Monitor> as *mut c_void as isize));
    }
    if v.is_empty() {
        // Sollte nie passieren (z. B. Sitzung getrennt) — ein plausibler Notbehelf statt Absturz.
        v.push(Monitor {
            id: 0,
            name: "DISPLAY".into(),
            rect: IRect::new(0, 0, 1920, 1080),
            work: IRect::new(0, 0, 1920, 1040),
            scale: 1.0,
            primary: true,
        });
    }
    v
}

/// Monitor unter einem globalen Punkt (sonst der primäre).
pub fn at_point(x: i32, y: i32) -> Monitor {
    list().into_iter().find(|m| m.rect.contains(x, y)).unwrap_or_else(primary)
}

pub fn at_cursor() -> Monitor {
    let (x, y) = cursor_pos();
    at_point(x, y)
}

pub fn primary() -> Monitor {
    let mut all = list();
    let i = all.iter().position(|m| m.primary).unwrap_or(0);
    all.swap_remove(i)
}

pub fn cursor_pos() -> (i32, i32) {
    let mut p = POINT::default();
    // SAFETY: p ist gültig; bei Fehler bleibt (0,0).
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    (p.x, p.y)
}
