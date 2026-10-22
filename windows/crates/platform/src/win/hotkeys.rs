//! Globale Kürzel. Ein eigener Thread mit Nachrichtenschleife:
//!
//! - `RegisterHotKey(NULL, …)` wo möglich (WM_HOTKEY in der Schleife), auch für einzelne Tasten (Pos1, „A“):
//!   Windows gibt den Tastendruck dann nicht an die App im Vordergrund weiter, ein Hook ist dafür nicht nötig,
//! - ein `WH_KEYBOARD_LL`-Hook (derselbe Thread) für alles, was `RegisterHotKey` nicht kann:
//!   Win-Kombinationen, belegte Kürzel und Druck, solange Windows 11 die Taste dem Snipping Tool gibt.
//!   Der Hook verschluckt die Taste (Down und Up), damit weder Startmenü noch Snipping Tool reagieren.
//!   Tasten zum Tippen (`KeyCombo::is_typing_key`), die ein anderes Programm schon hat, nimmt Knips ihm nicht
//!   per Hook weg — das Kürzel gilt dann als nicht registriert und die Einstellungen zeigen es.
//!
//! Hook-Regeln: im Hook nur Atomics, keine Locks,
//! keine Allokation (sonst läuft er in `LowLevelHooksTimeout` und Windows entfernt ihn STILL);
//! die eigentliche Arbeit macht ein Worker-Thread; alle 30 s wird vorsorglich neu eingehängt;
//! Alt-/Win-Loslassen wird nur maskiert (Strg-Hülle), wenn die Taste an einem Kürzel beteiligt war.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{bail, Result};
use knips_core::settings::{KeyCombo, MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, VK_SNAPSHOT};
use parking_lot::Mutex;
use windows::core::w;
use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Diagnostics::Debug::MessageBeep;
use windows::Win32::System::Registry::{RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_DWORD, RRF_RT_REG_DWORD, RRF_RT_REG_SZ};
use windows::Win32::System::Threading::{GetCurrentThread, GetCurrentThreadId, SetThreadPriority, THREAD_PRIORITY_TIME_CRITICAL};
#[cfg(feature = "dev")]
use windows::Win32::UI::Input::KeyboardAndMouse::{LoadKeyboardLayoutW, UnloadKeyboardLayout, KEYEVENTF_UNICODE, KLF_NOTELLSHELL};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, GetKeyboardLayout, GetKeyboardLayoutList, MapVirtualKeyExW, RegisterHotKey, SendInput, ToUnicodeEx,
    UnregisterHotKey, HKL, HOT_KEY_MODIFIERS, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, MAPVK_VK_TO_CHAR, MAPVK_VK_TO_VSC, VIRTUAL_KEY, VK_BACK, VK_CONTROL,
    VK_ESCAPE, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_RCONTROL, VK_RMENU, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetMessageW, GetWindowThreadProcessId, PeekMessageW,
    PostThreadMessageW, SendMessageTimeoutW,
    SetTimer, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, HC_ACTION, HHOOK, HWND_BROADCAST,
    KBDLLHOOKSTRUCT, LLKHF_INJECTED, MB_OK, MSG, PM_NOREMOVE, SMTO_ABORTIFHUNG, WH_KEYBOARD_LL, WM_APP, WM_HOTKEY,
    WM_KEYDOWN, WM_KEYUP, WM_SETTINGCHANGE, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_TIMER,
};

pub enum RecordResult {
    Combo(KeyCombo),
    /// Rücktaste ohne Strg/Alt/Win: Kürzel entfernen.
    Remove,
    /// Esc.
    Cancel,
    /// Keine echte Taste (Zeichen per Unicode-Eingabe, Eingabemethode, siehe `KeyCombo::is_valid`): die Aufnahme
    /// läuft weiter.
    Invalid(KeyCombo),
}

// ---------------------------------------------------------------- Zustand für den Hook (nur Atomics)

const SLOTS: usize = 24;
#[allow(clippy::declare_interior_mutable_const)]
const ZERO32: AtomicU32 = AtomicU32::new(0);
#[allow(clippy::declare_interior_mutable_const)]
const ZERO64: AtomicU64 = AtomicU64::new(0);

/// Hook-Kürzel: Taste (0 = frei), Modifier-Bits (MOD_*), Kennung.
static SLOT_VK: [AtomicU32; SLOTS] = [ZERO32; SLOTS];
static SLOT_MODS: [AtomicU32; SLOTS] = [ZERO32; SLOTS];
static SLOT_ID: [AtomicU32; SLOTS] = [ZERO32; SLOTS];
/// Verschluckte Tasten (Down gesehen → Up und Wiederholungen ebenfalls schlucken), je Bit ein VK.
static SWALLOWED: [AtomicU64; 4] = [ZERO64; 4];
/// Alt-/Win-Tasten, die an einem ausgelösten Kürzel beteiligt waren: ihr Loslassen wird maskiert.
/// Bit 0 LWin, 1 RWin, 2 LAlt, 3 RAlt.
static CONSUMED: AtomicU32 = AtomicU32::new(0);
static RECORDING: AtomicBool = AtomicBool::new(false);
static HOOK: AtomicIsize = AtomicIsize::new(0);
/// Aufrufe des Hooks (HC_ACTION) — Selbsttest: Kommt eine Taste überhaupt noch an?
static HOOK_CALLS: AtomicU32 = AtomicU32::new(0);
static THREAD_ID: AtomicU32 = AtomicU32::new(0);

const WM_FIRE: u32 = WM_APP + 1;
const WM_CMD: u32 = WM_APP + 2;
const WM_RECORDED: u32 = WM_APP + 3;
const WM_INVALID: u32 = WM_APP + 4;

const MOD_NOREPEAT: u32 = 0x4000;
const HEAL_INTERVAL_MS: u32 = 2_000;
const REHOOK_EVERY_TICKS: u32 = 15; // = 30 s

fn swallowed(vk: u32) -> bool {
    let vk = (vk & 0xFF) as usize;
    SWALLOWED[vk / 64].load(Ordering::Relaxed) & (1 << (vk % 64)) != 0
}

fn set_swallowed(vk: u32, on: bool) {
    let vk = (vk & 0xFF) as usize;
    let bit = 1u64 << (vk % 64);
    if on {
        SWALLOWED[vk / 64].fetch_or(bit, Ordering::Relaxed);
    } else {
        SWALLOWED[vk / 64].fetch_and(!bit, Ordering::Relaxed);
    }
}

fn is_modifier_vk(vk: u32) -> bool {
    matches!(vk, 0x10 | 0x11 | 0x12 | 0x5B | 0x5C | 0xA0..=0xA5)
}

/// Bit in `CONSUMED` für Alt-/Win-Tasten, sonst 0.
fn consumed_bit(vk: u32) -> u32 {
    match vk {
        0x5B => 1,
        0x5C => 2,
        0xA4 => 4,
        0xA5 => 8,
        _ => 0,
    }
}

fn key_down_now(vk: u16) -> bool {
    // SAFETY: reine Abfrage.
    unsafe { GetAsyncKeyState(vk as i32) as u16 & 0x8000 != 0 }
}

/// Aktuelle Modifier als MOD_*-Bits (Zustand vor dem gerade verarbeiteten Ereignis).
fn current_mods() -> u32 {
    let mut m = 0;
    if key_down_now(VK_SHIFT.0) {
        m |= MOD_SHIFT;
    }
    if key_down_now(VK_CONTROL.0) {
        m |= MOD_CONTROL;
    }
    if key_down_now(VK_MENU.0) {
        m |= MOD_ALT;
    }
    if key_down_now(VK_LWIN.0) || key_down_now(VK_RWIN.0) {
        m |= MOD_WIN;
    }
    m
}

/// Alle gerade gehaltenen Alt-/Win-Tasten als verbraucht merken.
fn mark_consumed() {
    let mut bits = 0;
    for (vk, bit) in [(VK_LWIN.0, 1), (VK_RWIN.0, 2), (VK_LMENU.0, 4), (VK_RMENU.0, 8)] {
        if key_down_now(vk) {
            bits |= bit;
        }
    }
    CONSUMED.fetch_or(bits, Ordering::SeqCst);
}

fn extended(vk: u16) -> bool {
    // Rechte Modifier, Win und der Block Einfg/Entf/Pos1/Ende/Bild↑↓/Pfeile (auf echten Tastaturen mit E0-Präfix).
    matches!(vk, v if v == VK_RMENU.0 || v == VK_RCONTROL.0 || v == VK_RWIN.0 || v == VK_LWIN.0) || matches!(vk, 0x21..=0x28 | 0x2D | 0x2E)
}

/// Kennung in `dwExtraInfo` für Tasten, die Knips selbst sendet — nur diese ignoriert der Hook.
/// Fremde simulierte Tasten (Stream Deck, AutoHotkey, Selbsttest) lösen Kürzel wie echte aus.
const OWN_INJECT: usize = 0x4B4E_5053;

fn key_input(vk: u16, up: bool) -> INPUT {
    key_input_with(vk, up, OWN_INJECT)
}

fn key_input_with(vk: u16, up: bool, extra: usize) -> INPUT {
    let mut flags = if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    if extended(vk) {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: 0, dwFlags: flags, time: 0, dwExtraInfo: extra } },
    }
}

/// Key-Up in eine Strg-Hülle packen (Strg↓, Taste↑, Strg↑): Windows sieht dann kein „sauberes“
/// Win-/Alt-Loslassen und öffnet weder Startmenü noch Menüleiste. Hält der Nutzer Strg, entfällt das
/// abschließende Strg↑. Der Hook ignoriert die eigenen injizierten Ereignisse, also keine Rekursion.
fn send_wrapped_key_up(vk: u32) {
    let ctrl_held = key_down_now(VK_CONTROL.0);
    let inputs = [key_input(VK_CONTROL.0, false), key_input(vk as u16, true), key_input(VK_CONTROL.0, true)];
    let n = if ctrl_held { 2 } else { 3 };
    // SAFETY: inputs ist ein gültiges Feld von n INPUT-Strukturen.
    unsafe {
        SendInput(&inputs[..n], std::mem::size_of::<INPUT>() as i32);
    }
}

fn post(msg: u32, wp: usize, lp: isize) {
    let tid = THREAD_ID.load(Ordering::Relaxed);
    if tid != 0 {
        // SAFETY: PostThreadMessageW allokiert nichts in unserem Code und blockiert nicht.
        unsafe {
            let _ = PostThreadMessageW(tid, msg, WPARAM(wp), LPARAM(lp));
        }
    }
}

/// Aufnahme-Modus im Hook: nächste normale Taste ist das Ergebnis. `true` = schlucken.
fn record_key(vk: u32, down: bool) -> bool {
    if !down {
        if swallowed(vk) {
            set_swallowed(vk, false);
            return true;
        }
        return false;
    }
    if swallowed(vk) {
        return true;
    }
    let mods = current_mods();
    set_swallowed(vk, true);
    mark_consumed();
    if vk == VK_ESCAPE.0 as u32 {
        RECORDING.store(false, Ordering::SeqCst);
        post(WM_RECORDED, 2, 0);
    } else if vk == VK_BACK.0 as u32 && mods & (MOD_CONTROL | MOD_ALT | MOD_WIN) == 0 {
        RECORDING.store(false, Ordering::SeqCst);
        post(WM_RECORDED, 1, 0);
    } else if KeyCombo::new(vk, mods).is_valid() {
        RECORDING.store(false, Ordering::SeqCst);
        post(WM_RECORDED, 0, (vk | (mods << 16)) as isize);
    } else {
        post(WM_INVALID, 0, (vk | (mods << 16)) as isize); // ungültig: melden, weiter warten
    }
    true
}

/// Kern des Hooks. `true` = Ereignis schlucken.
fn on_key(vk: u32, down: bool) -> bool {
    if is_modifier_vk(vk) {
        if down {
            return false;
        }
        let bit = consumed_bit(vk);
        if bit != 0 {
            let was = CONSUMED.fetch_and(!bit, Ordering::SeqCst) & bit != 0;
            // Beim Aufnehmen immer maskieren: kein Startmenü / keine Menüleiste über den Einstellungen.
            if was || RECORDING.load(Ordering::SeqCst) {
                send_wrapped_key_up(vk);
                return true;
            }
        }
        return false;
    }
    if RECORDING.load(Ordering::SeqCst) {
        return record_key(vk, down);
    }
    if !down {
        if swallowed(vk) {
            set_swallowed(vk, false);
            return true;
        }
        return false;
    }
    if swallowed(vk) {
        return true; // Wiederholung eines verschluckten Tastendrucks
    }
    let mut mods = None;
    for i in 0..SLOTS {
        if SLOT_VK[i].load(Ordering::Relaxed) == vk {
            let m = *mods.get_or_insert_with(current_mods);
            if SLOT_MODS[i].load(Ordering::Relaxed) == m {
                set_swallowed(vk, true);
                mark_consumed();
                post(WM_FIRE, SLOT_ID[i].load(Ordering::Relaxed) as usize, 0);
                return true;
            }
        }
    }
    false
}

unsafe extern "system" fn hook_proc(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        HOOK_CALLS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: Bei HC_ACTION zeigt lParam auf eine gültige KBDLLHOOKSTRUCT.
        let kb = unsafe { &*(lp.0 as *const KBDLLHOOKSTRUCT) };
        // Eigene injizierte Ereignisse zählen nicht und werden nie geschluckt.
        let own = kb.flags.contains(LLKHF_INJECTED) && kb.dwExtraInfo == OWN_INJECT;
        if !own {
            let msg = wp.0 as u32;
            let down = matches!(msg, WM_KEYDOWN | WM_SYSKEYDOWN);
            let up = matches!(msg, WM_KEYUP | WM_SYSKEYUP);
            if (down || up) && on_key(kb.vkCode, down) {
                return LRESULT(1);
            }
        }
    }
    // SAFETY: Weiterreichen mit unveränderten Parametern.
    unsafe { CallNextHookEx(None, code, wp, lp) }
}

// ---------------------------------------------------------------- Thread-Zustand (nicht im Hook)

/// Rückruf der Aufnahme: beliebig oft `Invalid`, danach genau einmal das Ergebnis.
type RecordCb = Arc<dyn Fn(RecordResult) + Send + Sync>;

enum Cmd {
    Apply(Vec<(u32, KeyCombo)>, Sender<Vec<u32>>),
    Record(RecordCb),
    CancelRecord,
}

static CMDS: Mutex<VecDeque<Cmd>> = Mutex::new(VecDeque::new());
static FIRE_TX: OnceLock<Sender<u32>> = OnceLock::new();

struct State {
    bindings: Vec<(u32, KeyCombo)>,
    /// (Registrierungs-ID, Kennung)
    registered: Vec<(i32, u32)>,
    record_cb: Option<RecordCb>,
}

fn fire(id: u32) {
    if let Some(tx) = FIRE_TX.get() {
        let _ = tx.send(id);
    }
}

fn install_hook() -> bool {
    if HOOK.load(Ordering::SeqCst) != 0 {
        return true;
    }
    // SAFETY: Hook-Prozedur ist eine `extern "system"`-Funktion dieses Moduls; Thread-ID 0 = global.
    match unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), Some(HINSTANCE::default()), 0) } {
        Ok(h) => {
            HOOK.store(h.0 as isize, Ordering::SeqCst);
            true
        }
        Err(e) => {
            log::error!("Tastatur-Hook konnte nicht installiert werden: {e}");
            false
        }
    }
}

fn remove_hook() {
    let h = HOOK.swap(0, Ordering::SeqCst);
    if h != 0 {
        // SAFETY: h stammt aus SetWindowsHookExW dieses Threads.
        unsafe {
            let _ = UnhookWindowsHookEx(HHOOK(h as *mut std::ffi::c_void));
        }
    }
}

fn clear_slots() {
    for v in &SLOT_VK {
        v.store(0, Ordering::SeqCst);
    }
    for w in &SWALLOWED {
        w.store(0, Ordering::SeqCst);
    }
}

fn unregister_all(st: &mut State) {
    for (reg, _) in st.registered.drain(..) {
        // SAFETY: Registrierung stammt von diesem Thread.
        unsafe {
            let _ = UnregisterHotKey(None, reg);
        }
    }
}

/// Setzt `bindings` neu. Liefert die Kennungen, die gar nicht funktionieren.
fn apply_bindings(st: &mut State, bindings: Vec<(u32, KeyCombo)>) -> Vec<u32> {
    unregister_all(st);
    clear_slots();
    let snip = snipping_key_enabled();
    let mut failed = Vec::new();
    let mut hook_ids = Vec::new();
    let mut next_reg = 1;
    let mut slot = 0;
    for (id, combo) in &bindings {
        if combo.vk == 0 || combo.vk > 0xFF {
            failed.push(*id);
            continue;
        }
        let hook_only = combo.needs_hook() || (combo.vk == VK_SNAPSHOT && snip);
        if !hook_only {
            // SAFETY: Registrierung für diesen Thread (hwnd = NULL → WM_HOTKEY in unserer Schleife).
            let ok = unsafe { RegisterHotKey(None, next_reg, HOT_KEY_MODIFIERS(combo.mods | MOD_NOREPEAT), combo.vk) }.is_ok();
            if ok {
                st.registered.push((next_reg, *id));
                next_reg += 1;
                continue;
            }
            if combo.is_typing_key() {
                // Pos1, „A“ … hat ein anderes Programm: Der Hook würde die Taste ihm und jeder App wegnehmen.
                failed.push(*id);
                continue;
            }
        }
        // Hook-Kürzel (Win-Kombination, Druck, oder von einem anderen Programm belegt).
        if slot < SLOTS {
            SLOT_MODS[slot].store(combo.mods, Ordering::SeqCst);
            SLOT_ID[slot].store(*id, Ordering::SeqCst);
            SLOT_VK[slot].store(combo.vk, Ordering::SeqCst);
            slot += 1;
            hook_ids.push(*id);
        } else {
            failed.push(*id);
        }
    }
    if !hook_ids.is_empty() {
        if !install_hook() {
            // Ohne Hook funktionieren genau diese nicht.
            clear_slots();
            failed.extend(hook_ids);
        }
    } else if !RECORDING.load(Ordering::SeqCst) {
        remove_hook();
    }
    st.bindings = bindings;
    failed
}

fn combo_of(lp: isize) -> KeyCombo {
    KeyCombo::new((lp & 0xFFFF) as u32, ((lp >> 16) & 0xF) as u32)
}

fn finish_record(st: &mut State, kind: usize, lp: isize) {
    let Some(cb) = st.record_cb.take() else { return };
    let result = match kind {
        0 => RecordResult::Combo(combo_of(lp)),
        1 => RecordResult::Remove,
        _ => RecordResult::Cancel,
    };
    let b = st.bindings.clone();
    apply_bindings(st, b);
    std::thread::spawn(move || cb(result));
}

fn stop_record(st: &mut State) {
    RECORDING.store(false, Ordering::SeqCst);
    st.record_cb = None;
    let b = st.bindings.clone();
    apply_bindings(st, b);
}

fn run_commands(st: &mut State) {
    loop {
        let Some(cmd) = CMDS.lock().pop_front() else { break };
        match cmd {
            Cmd::Apply(b, reply) => {
                if RECORDING.load(Ordering::SeqCst) {
                    // Während der Aufnahme ruhen die Kürzel; die neue Belegung gilt danach.
                    st.bindings = b;
                    let _ = reply.send(vec![]);
                } else {
                    let _ = reply.send(apply_bindings(st, b));
                }
            }
            Cmd::Record(cb) => {
                if st.record_cb.is_some() {
                    // Eine laufende Aufnahme wird ohne Rückruf ersetzt (wie auf dem Mac).
                    st.record_cb = None;
                }
                unregister_all(st);
                clear_slots();
                // Frisch einhängen: Einen Hook, den Windows nach einer Zeitüberschreitung still entfernt hat,
                // hält `HOOK` noch für aktiv — die Aufnahme bekäme dann keine einzige Taste.
                remove_hook();
                if install_hook() {
                    st.record_cb = Some(cb);
                    RECORDING.store(true, Ordering::SeqCst);
                } else {
                    let b = st.bindings.clone();
                    apply_bindings(st, b);
                    std::thread::spawn(move || cb(RecordResult::Cancel));
                }
            }
            Cmd::CancelRecord => {
                if st.record_cb.is_some() || RECORDING.load(Ordering::SeqCst) {
                    stop_record(st);
                }
            }
        }
    }
}

/// UAC, Sperrbildschirm und Strg+Alt+Entf laufen auf dem sicheren Desktop; dort verlorene Key-Ups
/// würden Markierungen hängen lassen. Abgleich mit dem echten Tastenzustand.
fn heal() {
    let c = CONSUMED.load(Ordering::SeqCst);
    if c == 0 {
        return;
    }
    let mut stale = 0;
    for (vk, bit) in [(VK_LWIN.0, 1), (VK_RWIN.0, 2), (VK_LMENU.0, 4), (VK_RMENU.0, 8)] {
        if c & bit != 0 && !key_down_now(vk) {
            stale |= bit;
        }
    }
    if stale != 0 {
        CONSUMED.fetch_and(!stale, Ordering::SeqCst);
    }
}

/// Windows entfernt Low-Level-Hooks nach einer Zeitüberschreitung still. Vorsorglich neu einhängen,
/// aber nur, wenn gerade keine Modifier gehalten werden (kein Ereignis fällt in die Lücke).
fn rehook() {
    if HOOK.load(Ordering::SeqCst) == 0 && !RECORDING.load(Ordering::SeqCst) {
        return;
    }
    let held = [VK_SHIFT.0, VK_CONTROL.0, VK_MENU.0, VK_LWIN.0, VK_RWIN.0].into_iter().any(key_down_now);
    if held || CONSUMED.load(Ordering::SeqCst) != 0 {
        return;
    }
    remove_hook();
    if !install_hook() {
        log::error!("Tastatur-Hook nach Neu-Installation nicht aktiv — nächster Versuch beim nächsten Abgleich");
    }
}

fn thread_main(ready: Sender<()>) {
    // SAFETY: Thread-Einstellungen und Nachrichtenschleife gehören diesem Thread.
    unsafe {
        // Wie AutoHotkey: Der Hook-Thread darf nie hinter anderer Arbeit anstehen.
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
        let mut msg = MSG::default();
        // Nachrichtenwarteschlange anlegen, bevor andere Threads Nachrichten schicken.
        let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
        THREAD_ID.store(GetCurrentThreadId(), Ordering::SeqCst);
        SetTimer(None, 0, HEAL_INTERVAL_MS, None);
        let _ = ready.send(());
        let mut st = State { bindings: Vec::new(), registered: Vec::new(), record_cb: None };
        let mut ticks = 0u32;
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            match msg.message {
                WM_HOTKEY => {
                    let reg = msg.wParam.0 as i32;
                    if let Some((_, id)) = st.registered.iter().find(|(r, _)| *r == reg) {
                        fire(*id);
                    }
                }
                WM_FIRE => fire(msg.wParam.0 as u32),
                WM_CMD => run_commands(&mut st),
                WM_RECORDED => finish_record(&mut st, msg.wParam.0, msg.lParam.0),
                WM_INVALID => {
                    // Signalton und Rückmeldung nie in diesem Thread: `MessageBeep` kann hängen (Audio-Gerät wacht
                    // auf, keins da). Solange der Thread steht, laufen die Hook-Aufrufe in die Zeitüberschreitung,
                    // und Windows hängt den Hook still aus — danach käme keine Taste mehr an.
                    let cb = st.record_cb.clone();
                    let combo = combo_of(msg.lParam.0);
                    std::thread::spawn(move || {
                        let t = std::time::Instant::now();
                        let _ = MessageBeep(MB_OK);
                        let ms = t.elapsed().as_millis();
                        if ms > 100 {
                            log::info!("Signalton brauchte {ms} ms");
                        }
                        // Nur während der Aufnahme (eine schon beendete meldet nichts mehr nach).
                        if let Some(cb) = cb {
                            cb(RecordResult::Invalid(combo));
                        }
                    });
                }
                WM_TIMER => {
                    heal();
                    ticks += 1;
                    // Während der Aufnahme öfter: Ein still ausgehängter Hook ließe sie sonst keine Taste mehr sehen.
                    if ticks.is_multiple_of(REHOOK_EVERY_TICKS) || RECORDING.load(Ordering::SeqCst) {
                        rehook();
                    }
                }
                _ => {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Öffentliche Schnittstelle

/// Startet den Kürzel-Thread. `on_fire(id)` kommt aus einem eigenen Worker-Thread (nie aus dem Hook).
pub fn start(on_fire: Box<dyn Fn(u32) + Send + Sync>) {
    static STARTED: OnceLock<()> = OnceLock::new();
    if STARTED.set(()).is_err() {
        return;
    }
    let on_fire: Arc<dyn Fn(u32) + Send + Sync> = Arc::from(on_fire);
    let (tx, rx) = channel::<u32>();
    let _ = FIRE_TX.set(tx);
    let spawned = std::thread::Builder::new().name("hotkey-worker".into()).spawn(move || {
        while let Ok(id) = rx.recv() {
            // Ein Absturz im Rückruf darf den Worker nicht beenden.
            let f = on_fire.clone();
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || f(id)));
        }
    });
    if spawned.is_err() {
        log::error!("Hotkey-Worker konnte nicht starten");
        return;
    }
    let (ready_tx, ready_rx) = channel();
    if std::thread::Builder::new().name("hotkey-hook".into()).spawn(move || thread_main(ready_tx)).is_err() {
        log::error!("Hotkey-Thread konnte nicht starten");
        return;
    }
    let _ = ready_rx.recv_timeout(Duration::from_secs(3));
}

fn send_cmd(cmd: Cmd) -> bool {
    let tid = THREAD_ID.load(Ordering::SeqCst);
    if tid == 0 {
        return false;
    }
    CMDS.lock().push_back(cmd);
    // SAFETY: Thread existiert und hat eine Warteschlange (siehe thread_main).
    unsafe { PostThreadMessageW(tid, WM_CMD, WPARAM(0), LPARAM(0)) }.is_ok()
}

/// Ersetzt alle Kürzel. `RegisterHotKey`, wo möglich; Win-Kombinationen, belegte Kürzel (außer Tasten zum
/// Tippen) und Druck (solange Windows sie dem Bildschirmausschnitt gibt) über den Tastatur-Hook, der die
/// Taste dann verschluckt. Liefert die IDs, die gar nicht funktionieren.
pub fn apply(bindings: &[(u32, KeyCombo)]) -> Vec<u32> {
    let all: Vec<u32> = bindings.iter().map(|(id, _)| *id).collect();
    let (tx, rx) = channel();
    if !send_cmd(Cmd::Apply(bindings.to_vec(), tx)) {
        return all;
    }
    rx.recv_timeout(Duration::from_secs(3)).unwrap_or_default()
}

/// Nächste Tastenkombination aufnehmen (Einstellungen). Solange ruhen alle Kürzel; die Tasten
/// werden verschluckt (auch Druck und Win-Kombinationen). Ungültige Kombination → Signalton und
/// `RecordResult::Invalid`, weiter warten. `on_result` kommt aus einem eigenen Thread, nie aus dem Hook.
pub fn record(on_result: Box<dyn Fn(RecordResult) + Send + Sync>) {
    let on_result: RecordCb = Arc::from(on_result);
    // Ohne laufenden Thread kann nicht aufgenommen werden — dann sofort „abgebrochen“ melden.
    let tid = THREAD_ID.load(Ordering::SeqCst);
    if tid == 0 {
        std::thread::spawn(move || on_result(RecordResult::Cancel));
        return;
    }
    CMDS.lock().push_back(Cmd::Record(on_result));
    // SAFETY: wie in send_cmd.
    unsafe {
        let _ = PostThreadMessageW(tid, WM_CMD, WPARAM(0), LPARAM(0));
    }
}

/// Bricht die Aufnahme ab (ohne Rückruf) und stellt die Kürzel wieder her.
pub fn cancel_record() {
    send_cmd(Cmd::CancelRecord);
}

/// Wartet der Hook gerade auf die nächste Kombination?
pub fn is_recording() -> bool {
    RECORDING.load(Ordering::SeqCst)
}

/// Bisherige Aufrufe des Tastatur-Hooks.
pub fn hook_calls() -> u32 {
    HOOK_CALLS.load(Ordering::Relaxed)
}

/// Ist der Tastatur-Hook eingehängt?
pub fn hook_installed() -> bool {
    HOOK.load(Ordering::SeqCst) != 0
}

const KEYBOARD_KEY: windows::core::PCWSTR = w!("Control Panel\\Keyboard");
const SNIP_VALUE: windows::core::PCWSTR = w!("PrintScreenKeyForSnippingEnabled");

fn windows_build() -> u32 {
    let mut buf = [0u16; 16];
    let mut len = (buf.len() * 2) as u32;
    // SAFETY: Puffer und Länge (in Bytes) passen zusammen.
    let err = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"),
            w!("CurrentBuildNumber"),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut _),
            Some(&mut len),
        )
    };
    if err.0 != 0 {
        return 0;
    }
    super::util::from_wide(&buf).trim().parse().unwrap_or(0)
}

/// „Druck-Taste zum Öffnen der Bildschirmausschnitterstellung verwenden“ (Windows 11).
pub fn snipping_key_enabled() -> bool {
    let mut data = 0u32;
    let mut len = 4u32;
    // SAFETY: data/len gültig, DWORD-Wert.
    let err = unsafe {
        RegGetValueW(HKEY_CURRENT_USER, KEYBOARD_KEY, SNIP_VALUE, RRF_RT_REG_DWORD, None, Some(&mut data as *mut u32 as *mut _), Some(&mut len))
    };
    if err.0 == 0 {
        data != 0
    } else {
        // Wert fehlt: Windows 11 (ab Build 22000) gibt Druck standardmäßig dem Snipping Tool.
        windows_build() >= 22000
    }
}

const KNIPS_KEY: windows::core::PCWSTR = w!("Software\\Knips");
const TAKEN_VALUE: windows::core::PCWSTR = w!("PrintScreenKeyTaken");
const ORIGINAL_VALUE: windows::core::PCWSTR = w!("PrintScreenKeyOriginal");

fn hkcu_dword(key: windows::core::PCWSTR, value: windows::core::PCWSTR) -> Option<u32> {
    let mut data = 0u32;
    let mut len = 4u32;
    // SAFETY: data/len gültig, DWORD-Wert.
    let err = unsafe { RegGetValueW(HKEY_CURRENT_USER, key, value, RRF_RT_REG_DWORD, None, Some(&mut data as *mut u32 as *mut _), Some(&mut len)) };
    (err.0 == 0).then_some(data)
}

/// Übernahme der Druck-Taste für das Deinstallationsprogramm vermerken (`HKCU\Software\Knips`):
/// `PrintScreenKeyTaken` = 1 und der Wert davor in `PrintScreenKeyOriginal` (fehlt, wenn es keinen
/// gab). `installer-hooks.nsh` stellt ihn beim Deinstallieren wieder her. Zurückgeben löscht den Vermerk.
fn note_takeover(taken: bool) {
    use windows::Win32::System::Registry::RegDeleteKeyValueW;
    // SAFETY: konstante, null-terminierte Namen; DWORD-Daten mit Länge 4.
    unsafe {
        if !taken {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, KNIPS_KEY, TAKEN_VALUE);
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, KNIPS_KEY, ORIGINAL_VALUE);
            return;
        }
        // Schon vermerkt: der Wert von vor der ersten Übernahme bleibt maßgeblich.
        if hkcu_dword(KNIPS_KEY, TAKEN_VALUE) == Some(1) {
            return;
        }
        match hkcu_dword(KEYBOARD_KEY, SNIP_VALUE) {
            Some(v) => {
                let _ = RegSetKeyValueW(HKEY_CURRENT_USER, KNIPS_KEY, ORIGINAL_VALUE, REG_DWORD.0, Some(&v as *const u32 as *const _), 4);
            }
            None => {
                let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, KNIPS_KEY, ORIGINAL_VALUE);
            }
        }
        let one = 1u32;
        let _ = RegSetKeyValueW(HKEY_CURRENT_USER, KNIPS_KEY, TAKEN_VALUE, REG_DWORD.0, Some(&one as *const u32 as *const _), 4);
    }
}

/// Vermerk der Übernahme (Selbsttest `storage`): `None` = nicht übernommen, sonst der Wert von davor
/// (`Some(None)`: es gab keinen).
pub fn snipping_takeover_marker() -> Option<Option<u32>> {
    (hkcu_dword(KNIPS_KEY, TAKEN_VALUE) == Some(1)).then(|| hkcu_dword(KNIPS_KEY, ORIGINAL_VALUE))
}

/// Schreibt `HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled` und vermerkt eine Übernahme
/// für das Deinstallationsprogramm (`note_takeover`).
pub fn set_snipping_key(enabled: bool) -> Result<()> {
    note_takeover(!enabled);
    let data = enabled as u32;
    // SAFETY: data ist ein gültiges DWORD; Unterschlüssel wird bei Bedarf angelegt.
    let err = unsafe {
        RegSetKeyValueW(HKEY_CURRENT_USER, KEYBOARD_KEY, SNIP_VALUE, REG_DWORD.0, Some(&data as *const u32 as *const _), 4)
    };
    if err.0 != 0 {
        bail!("Registry-Schreiben fehlgeschlagen (Fehler {})", err.0);
    }
    // Der Explorer liest die Einstellung bei WM_SETTINGCHANGE neu.
    let area = super::util::wide("Control Panel\\Keyboard");
    // SAFETY: area lebt über den Aufruf; mit Zeitlimit, damit hängende Fenster nicht blockieren.
    unsafe {
        SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, WPARAM(0), LPARAM(area.as_ptr() as isize), SMTO_ABORTIFHUNG, 1000, None);
    }
    Ok(())
}

// ---------------------------------------------------------------- Tastaturlayout: Namen und AltGr

/// Tasten, deren Zeichen vom Layout abhängt (OEM-Tasten: Umlaute, Satzzeichen, `<>`). Buchstaben und
/// Ziffern heißen wie ihr Virtual-Key (der folgt schon dem Layout), Sondertasten bleiben deutsch.
fn layout_dependent(vk: u32) -> bool {
    matches!(vk, 0xBA..=0xC0 | 0xDB..=0xDF | 0xE2)
}

/// Layout, in dem gerade getippt wird (Thread des Vordergrundfensters), sonst das des eigenen Threads.
fn current_layout() -> HKL {
    // SAFETY: reine Abfragen; ein ungültiges Fenster liefert Thread 0.
    unsafe {
        let fg = GetForegroundWindow();
        let thread = if fg.0.is_null() { 0 } else { GetWindowThreadProcessId(fg, None) };
        let hkl = GetKeyboardLayout(thread);
        if hkl.0.is_null() {
            GetKeyboardLayout(0)
        } else {
            hkl
        }
    }
}

/// Alle Layouts, zwischen denen der Nutzer umschalten kann.
fn installed_layouts() -> Vec<HKL> {
    // SAFETY: erst die Anzahl, dann ein passend großes Feld.
    unsafe {
        let n = GetKeyboardLayoutList(None);
        if n <= 0 {
            return vec![];
        }
        let mut list = vec![HKL(std::ptr::null_mut()); n as usize];
        let got = GetKeyboardLayoutList(Some(&mut list));
        list.truncate(got.max(0) as usize);
        list
    }
}

fn key_name_in(vk: u32, hkl: HKL) -> String {
    if layout_dependent(vk) {
        // SAFETY: reine Abfrage. Bit 31 kennzeichnet Tottasten (´, ^), das Zeichen steht im unteren Wort.
        let mapped = unsafe { MapVirtualKeyExW(vk, MAPVK_VK_TO_CHAR, Some(hkl)) };
        if let Some(c) = char::from_u32(mapped & 0xFFFF).filter(|c| *c != '\0' && !c.is_control() && !c.is_whitespace()) {
            let mut upper = c.to_uppercase();
            return match (upper.next(), upper.next()) {
                (Some(u), None) => u.to_string(),
                _ => c.to_string(), // „ß“ bleibt „ß“ (nicht „SS“)
            };
        }
    }
    knips_core::settings::key_name(vk)
}

/// Name der Taste `vk` für Anzeigen wie „Strg+Umschalt+Ü“: Zeichentasten so, wie sie auf dem aktuellen
/// Layout beschriftet sind (US: „;“ statt „Ü“), alles andere mit den deutschen Namen aus knips-core.
pub fn key_name(vk: u32) -> String {
    key_name_in(vk, current_layout())
}

fn altgr_char_in(combo: KeyCombo, hkl: HKL) -> Option<String> {
    // AltGr meldet Windows als Strg+Alt; mit Win gedrückt tippt niemand ein Zeichen.
    if combo.mods & (MOD_CONTROL | MOD_ALT) != (MOD_CONTROL | MOD_ALT) || combo.mods & MOD_WIN != 0 || combo.vk > 0xFF {
        return None;
    }
    let mut state = [0u8; 256];
    for vk in [VK_CONTROL, VK_LCONTROL, VK_MENU, VK_RMENU] {
        state[vk.0 as usize] = 0x80;
    }
    if combo.mods & MOD_SHIFT != 0 {
        state[VK_SHIFT.0 as usize] = 0x80;
        state[VK_LSHIFT.0 as usize] = 0x80;
    }
    let mut buf = [0u16; 8];
    // SAFETY: Puffer und Tastenzustand gehören uns. Flag 4: Zustand des Tastaturtreibers nicht ändern
    // (sonst bliebe eine Tottaste „hängen“), ab Windows 10 1607.
    let n = unsafe {
        let scan = MapVirtualKeyExW(combo.vk, MAPVK_VK_TO_VSC, Some(hkl));
        ToUnicodeEx(combo.vk, scan, &state, &mut buf, 0x4, Some(hkl))
    };
    // < 0: Tottaste (das Zeichen steht trotzdem im Puffer), 0: kein Zeichen.
    let len = (n.unsigned_abs() as usize).min(buf.len());
    let text: String = String::from_utf16_lossy(&buf[..len]).chars().filter(|c| !c.is_control()).collect();
    (!text.trim().is_empty()).then_some(text)
}

/// Ergibt `combo` beim Tippen ein Zeichen, weil Strg+Alt dasselbe ist wie AltGr (deutsch: Strg+Alt+Q = „@“,
/// Strg+Alt+E = „€“)? Dann dieses Zeichen — als Kürzel würde es das Tippen verhindern. Geprüft werden das
/// aktuelle und alle anderen installierten Layouts.
pub fn altgr_char(combo: KeyCombo) -> Option<String> {
    let mut layouts = vec![current_layout()];
    for hkl in installed_layouts() {
        if !layouts.contains(&hkl) {
            layouts.push(hkl);
        }
    }
    layouts.into_iter().filter(|h| !h.0.is_null()).find_map(|h| altgr_char_in(combo, h))
}

/// Selbsttest: Tastennamen und AltGr-Zeichen auf dem Layout `klid` (z. B. „00000407“ = Deutsch,
/// „00000409“ = US). Lädt das Layout dafür kurz, ohne es zu aktivieren.
#[cfg(feature = "dev")]
pub fn probe_layout(klid: &str, vks: &[u32], combos: &[KeyCombo]) -> Result<(Vec<String>, Vec<Option<String>>)> {
    let before = installed_layouts();
    let id = super::util::wide(klid);
    // SAFETY: `id` ist null-terminiert und lebt über den Aufruf.
    let hkl = unsafe { LoadKeyboardLayoutW(windows::core::PCWSTR(id.as_ptr()), KLF_NOTELLSHELL) }?;
    let names = vks.iter().map(|vk| key_name_in(*vk, hkl)).collect();
    let chars = combos.iter().map(|c| altgr_char_in(*c, hkl)).collect();
    if !before.contains(&hkl) {
        // SAFETY: nur das eben selbst geladene Layout wieder entfernen.
        let _ = unsafe { UnloadKeyboardLayout(hkl) };
    }
    Ok((names, chars))
}

/// Tastenkombination simulieren wie von der Tastatur (Selbsttest `hotkeys`).
pub fn simulate(combo: KeyCombo) {
    let mods: Vec<u16> = [(MOD_WIN, VK_LWIN.0), (MOD_CONTROL, VK_CONTROL.0), (MOD_ALT, VK_MENU.0), (MOD_SHIFT, VK_SHIFT.0)]
        .into_iter()
        .filter(|(m, _)| combo.mods & m != 0)
        .map(|(_, vk)| vk)
        .collect();
    let mut inputs: Vec<INPUT> = mods.iter().map(|vk| key_input_with(*vk, false, 0)).collect();
    inputs.push(key_input_with(combo.vk as u16, false, 0));
    inputs.push(key_input_with(combo.vk as u16, true, 0));
    inputs.extend(mods.iter().rev().map(|vk| key_input_with(*vk, true, 0)));
    // SAFETY: inputs ist ein gültiges Feld von INPUT-Strukturen.
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

/// Ein Zeichen per Unicode-Eingabe senden, wie Bildschirmtastatur oder Passwortmanager (Selbsttest
/// `hotkeyrecord`): Der Hook sieht dabei VK_PACKET statt einer Taste.
#[cfg(feature = "dev")]
pub fn simulate_char(c: char) {
    let mut buf = [0u16; 2];
    let inputs: Vec<INPUT> = c
        .encode_utf16(&mut buf)
        .iter()
        .flat_map(|unit| {
            [false, true].map(|up| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VIRTUAL_KEY(0),
                        wScan: *unit,
                        dwFlags: if up { KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } else { KEYEVENTF_UNICODE },
                        time: 0,
                        dwExtraInfo: 0,
                    },
                },
            })
        })
        .collect();
    // SAFETY: inputs ist ein gültiges Feld von INPUT-Strukturen.
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

/// Selbsttest: `combo` belegen wie ein anderes Programm (`RegisterHotKey` in einem eigenen Thread), solange der
/// Rückgabewert lebt. `None`, wenn die Kombination schon jemand hat.
#[cfg(feature = "dev")]
pub fn occupy(combo: KeyCombo) -> Option<Occupied> {
    let (ready_tx, ready_rx) = channel();
    let (stop_tx, stop_rx) = channel::<()>();
    let thread = std::thread::spawn(move || {
        // SAFETY: Registrierung für diesen Thread (hwnd = NULL); er hält sie, bis `Occupied` fällt.
        let ok = unsafe { RegisterHotKey(None, 1, HOT_KEY_MODIFIERS(combo.mods | MOD_NOREPEAT), combo.vk) }.is_ok();
        let _ = ready_tx.send(ok);
        if ok {
            let _ = stop_rx.recv();
            // SAFETY: Registrierung stammt von diesem Thread.
            unsafe {
                let _ = UnregisterHotKey(None, 1);
            }
        }
    });
    if ready_rx.recv_timeout(Duration::from_secs(3)).unwrap_or(false) {
        Some(Occupied { stop: stop_tx, thread: Some(thread) })
    } else {
        None
    }
}

/// Von `occupy` belegtes Kürzel; wird beim Fallenlassen wieder frei.
#[cfg(feature = "dev")]
pub struct Occupied {
    stop: Sender<()>,
    thread: Option<std::thread::JoinHandle<()>>,
}

#[cfg(feature = "dev")]
impl Drop for Occupied {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Umschalt drücken/loslassen wie von der Tastatur (Selbsttest: Quadrat beim Ziehen).
#[cfg(feature = "dev")]
pub(crate) fn press_modifier(down: bool) {
    let input = key_input_with(VK_SHIFT.0, !down, 0);
    // SAFETY: ein gültiges INPUT.
    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
}
