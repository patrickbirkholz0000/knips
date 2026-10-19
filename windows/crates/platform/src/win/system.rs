//! Angaben für die Nutzungsstatistik: Windows-Version und Anzeigesprache.

use windows::core::{w, PCWSTR};
use windows::Win32::Globalization::{GetUserDefaultUILanguage, LCIDToLocaleName};
use windows::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD, RRF_RT_REG_SZ};

const CURRENT_VERSION: PCWSTR = w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");

fn dword(name: PCWSTR) -> Option<u32> {
    let mut data = 0u32;
    let mut len = 4u32;
    // SAFETY: data/len gültig, DWORD-Wert.
    let err = unsafe {
        RegGetValueW(HKEY_LOCAL_MACHINE, CURRENT_VERSION, name, RRF_RT_REG_DWORD, None, Some(&mut data as *mut u32 as *mut _), Some(&mut len))
    };
    (err.0 == 0).then_some(data)
}

fn string(name: PCWSTR) -> Option<String> {
    let mut buf = [0u16; 64];
    let mut len = (buf.len() * 2) as u32;
    // SAFETY: Puffer und Länge (in Bytes) passen zusammen.
    let err = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, CURRENT_VERSION, name, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut len)) };
    (err.0 == 0).then(|| super::util::from_wide(&buf).trim().to_string())
}

/// Windows-Version wie „10.0.26100“ (Haupt.Neben.Build). Aus der Registry, weil `GetVersionEx`
/// ohne passendes Manifest eine ältere Version meldet.
pub fn os_version() -> String {
    let major = dword(w!("CurrentMajorVersionNumber")).unwrap_or(10);
    let minor = dword(w!("CurrentMinorVersionNumber")).unwrap_or(0);
    let build = string(w!("CurrentBuildNumber")).and_then(|b| b.parse::<u32>().ok()).unwrap_or(0);
    format!("{major}.{minor}.{build}")
}

/// Anzeigesprache des Benutzers, z. B. „de-DE“.
pub fn ui_language() -> String {
    let mut buf = [0u16; 85];
    // SAFETY: Puffer gültig; die Funktion schreibt höchstens seine Länge.
    let n = unsafe { LCIDToLocaleName(GetUserDefaultUILanguage() as u32, Some(&mut buf), 0) };
    if n > 0 {
        super::util::from_wide(&buf)
    } else {
        String::new()
    }
}
