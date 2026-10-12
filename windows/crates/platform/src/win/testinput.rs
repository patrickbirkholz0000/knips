//! Simulierte Maus und Tastatur für Selbsttests (wie von der Hardware). Signaturen wie `mock::testinput`.

use std::time::Duration;

use knips_core::settings::KeyCombo;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEINPUT, MOUSE_EVENT_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;

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
