//! Gemeinsame Helfer der Windows-Schicht: COM-Initialisierung pro Thread, Wide-Strings, Handles.

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

struct ComGuard(bool);

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.0 {
            // Paarig zu einem erfolgreichen CoInitializeEx dieses Threads.
            unsafe { CoUninitialize() };
        }
    }
}

thread_local! {
    static COM: ComGuard = {
        // MTA. Ist der Thread schon als STA initialisiert (RPC_E_CHANGED_MODE), bleibt es dabei:
        // dann ist `ok()` falsch und wir deinitialisieren nichts, was uns nicht gehört.
        let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        ComGuard(hr.is_ok())
    };
}

/// COM/WinRT auf dem aktuellen Thread bereitstellen (einmal pro Thread, räumt beim Thread-Ende auf).
pub fn init_com() {
    COM.with(|_| {});
}

/// UTF-16, null-terminiert.
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Pfad als UTF-16, null-terminiert, mit Backslashes.
pub fn wide_path(p: &Path) -> Vec<u16> {
    p.as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .chain(std::iter::once(0))
        .collect()
}

pub fn hwnd(h: isize) -> HWND {
    HWND(h as *mut c_void)
}

/// UTF-16-Puffer (fester Platz) bis zur ersten Null als String.
pub fn from_wide(buf: &[u16]) -> String {
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..n])
}
