//! Explorer, Standardprogramme, Papierkorb, Fenster nach vorn.

use std::os::windows::process::CommandExt;
use std::path::Path;

use anyhow::{bail, Result};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    keybd_event, KEYEVENTF_KEYUP, VK_MENU,
};
use windows::Win32::UI::Shell::{
    ILCreateFromPathW, ILFree, SHFileOperationW, SHOpenFolderAndSelectItems, ShellExecuteW, FOF_ALLOWUNDO,
    FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AllowSetForegroundWindow, BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsIconic,
    IsWindow, SetForegroundWindow, ShowWindow, ASFW_ANY, MB_OK, SW_RESTORE, SW_SHOWNORMAL,
};
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::System::Threading::AttachThreadInput;

use super::util::{hwnd, init_com, wide, wide_path};

fn shell_execute(file: &[u16]) -> Result<()> {
    // SAFETY: `file` ist null-terminiert und lebt über den Aufruf.
    let r = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(file.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    // Rückgabe > 32 = Erfolg (alte Win16-Konvention).
    if r.0 as isize > 32 {
        Ok(())
    } else {
        bail!("ShellExecute fehlgeschlagen ({})", r.0 as isize)
    }
}

/// Datei/Ordner mit der Standard-App öffnen.
pub fn open_path(path: &Path) -> Result<()> {
    shell_execute(&wide_path(path))
}

pub fn open_url(url: &str) -> Result<()> {
    shell_execute(&wide(url))
}

/// Im Explorer zeigen und markieren.
pub fn reveal(path: &Path) -> Result<()> {
    init_com();
    let wp = wide_path(path);
    // SAFETY: wp ist null-terminiert; das PIDL wird mit ILFree freigegeben.
    let ok = unsafe {
        let pidl = ILCreateFromPathW(PCWSTR(wp.as_ptr()));
        if pidl.is_null() {
            false
        } else {
            let r = SHOpenFolderAndSelectItems(pidl, None, 0);
            ILFree(Some(pidl));
            r.is_ok()
        }
    };
    if ok {
        return Ok(());
    }
    // Rückfall: explorer /select,"Pfad" (Anführungszeichen selbst setzen, nicht von Rust quoten lassen).
    let p = path.to_string_lossy().replace('/', "\\");
    std::process::Command::new("explorer.exe").raw_arg(format!("/select,\"{p}\"")).spawn()?;
    Ok(())
}

/// In den Papierkorb.
pub fn trash(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    // pFrom: Liste, doppelt null-terminiert. Der Pfad muss absolut sein, sonst kein Papierkorb.
    let abs = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir()?.join(path) };
    let mut from = wide_path(&abs);
    from.push(0);
    let mut op = SHFILEOPSTRUCTW {
        hwnd: HWND::default(),
        wFunc: FO_DELETE,
        pFrom: PCWSTR(from.as_ptr()),
        pTo: PCWSTR::null(),
        fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI).0 as u16,
        ..Default::default()
    };
    // SAFETY: `op` und `from` leben über den Aufruf.
    let r = unsafe { SHFileOperationW(&mut op) };
    if r != 0 || op.fAnyOperationsAborted.as_bool() {
        bail!("Papierkorb fehlgeschlagen (Code {r:#x})");
    }
    Ok(())
}

/// Fenster nach vorn holen (auch wenn Knips gerade nicht im Vordergrund ist).
pub fn activate(h: isize) {
    let w = hwnd(h);
    // SAFETY: reine Win32-Aufrufe mit Handles, die ungültig sein dürfen (dann tun sie nichts).
    unsafe {
        if !IsWindow(Some(w)).as_bool() {
            return;
        }
        if IsIconic(w).as_bool() {
            let _ = ShowWindow(w, SW_RESTORE);
        }
        let _ = AllowSetForegroundWindow(ASFW_ANY);
        if SetForegroundWindow(w).as_bool() && GetForegroundWindow() == w {
            return;
        }
        // Windows verweigert den Wechsel, wenn wir nicht im Vordergrund sind. Eingabewarteschlange
        // des Vordergrund-Threads an unsere hängen, dann darf SetForegroundWindow durch.
        let fg = GetForegroundWindow();
        let fg_thread = if fg.0.is_null() { 0 } else { GetWindowThreadProcessId(fg, None) };
        let me = GetCurrentThreadId();
        let attached = fg_thread != 0 && fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool();
        let _ = BringWindowToTop(w);
        let _ = SetForegroundWindow(w);
        if attached {
            let _ = AttachThreadInput(me, fg_thread, false);
        }
        if GetForegroundWindow() != w {
            // Letzter Ausweg: eine Alt-Taste „antippen“ — danach gilt der Prozess als Eingabe-Empfänger.
            keybd_event(VK_MENU.0 as u8, 0, Default::default(), 0);
            keybd_event(VK_MENU.0 as u8, 0, KEYEVENTF_KEYUP, 0);
            let _ = SetForegroundWindow(w);
        }
    }
}

/// Aktuelles Vordergrundfenster (um den Fokus nach dem Overlay zurückzugeben).
pub fn foreground() -> isize {
    // SAFETY: keine Parameter.
    unsafe { GetForegroundWindow().0 as isize }
}

pub fn beep() {
    // SAFETY: keine Zeiger.
    unsafe {
        let _ = MessageBeep(MB_OK);
    }
}
