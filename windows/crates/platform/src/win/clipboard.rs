//! Zwischenablage mit verzögertem Rendern (`LazyImageProvider` auf dem Mac): Ein eigener Thread mit
//! unsichtbarem Nachrichtenfenster besitzt die Zwischenablage. `set_image` kündigt PNG, DIBV5
//! (und JFIF) nur an; erst wenn jemand einfügt, kommt `WM_RENDERFORMAT` und das Bild wird kodiert.

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc::channel;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use knips_core::model::ImageFormat;
use knips_core::RgbaImage;
use parking_lot::Mutex;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{BITMAPV5HEADER, BI_BITFIELDS};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardOwner, IsClipboardFormatAvailable,
    OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW, SendMessageTimeoutW,
    SendMessageW, TranslateMessage, HWND_MESSAGE, MSG, SMTO_ABORTIFHUNG, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP,
    WM_DESTROYCLIPBOARD, WM_RENDERALLFORMATS, WM_RENDERFORMAT, WNDCLASSW,
};

use super::util::wide_path;

/// Bild, das erst beim Einfügen geliefert wird (Rendern/Kodieren läuft im Hintergrund).
/// Die Methoden dürfen blockieren, bis die Arbeit fertig ist.
pub trait ImageProvider: Send + Sync {
    fn format(&self) -> ImageFormat;
    /// Kodierte Daten im Format `format()`.
    fn encoded(&self) -> Option<Vec<u8>>;
    fn image(&self) -> Option<Arc<RgbaImage>>;
}

const CF_UNICODETEXT: u32 = 13;
const CF_DIB: u32 = 8;
const CF_DIBV5: u32 = 17;
const CF_HDROP: u32 = 15;

const WM_CALL: u32 = WM_APP + 1;
const WM_FLUSH: u32 = WM_APP + 2;

static DISABLED: AtomicBool = AtomicBool::new(false);
/// Das aktuell angekündigte Bild (nur der Clipboard-Thread schreibt; Besitz endet mit WM_DESTROYCLIPBOARD).
static CURRENT: Mutex<Option<Arc<dyn ImageProvider>>> = Mutex::new(None);
/// Bit 0 = PNG, 1 = DIBV5, 2 = JFIF: schon geliefert.
static RENDERED: AtomicU8 = AtomicU8::new(0);

struct Formats {
    png: u32,
    jfif: u32,
    drop_effect: u32,
}

fn formats() -> &'static Formats {
    static F: OnceLock<Formats> = OnceLock::new();
    F.get_or_init(|| unsafe {
        // SAFETY: Literale sind null-terminiert.
        Formats {
            png: RegisterClipboardFormatW(w!("PNG")),
            jfif: RegisterClipboardFormatW(w!("JFIF")),
            drop_effect: RegisterClipboardFormatW(w!("Preferred DropEffect")),
        }
    })
}

// ---------------------------------------------------------------- Öffnen/Schließen

struct Open;

impl Drop for Open {
    fn drop(&mut self) {
        // SAFETY: gepaart mit dem erfolgreichen OpenClipboard in `open`.
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

/// Öffnen mit Wiederholung: ein anderes Programm kann sie gerade halten.
fn open(owner: Option<HWND>) -> Result<Open> {
    for i in 0..12 {
        // SAFETY: owner ist None oder unser Fenster.
        if unsafe { OpenClipboard(owner) }.is_ok() {
            return Ok(Open);
        }
        std::thread::sleep(Duration::from_millis(10 + i * 4));
    }
    bail!("Zwischenablage ist belegt")
}

// ---------------------------------------------------------------- Globaler Speicher

fn alloc_global(bytes: &[u8]) -> Result<HGLOBAL> {
    // SAFETY: Block wird nach dem Kopieren entsperrt; bei Fehler freigegeben.
    unsafe {
        let h = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1))?;
        let p = GlobalLock(h);
        if p.is_null() {
            let _ = GlobalFree(Some(h));
            bail!("GlobalLock fehlgeschlagen");
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = GlobalUnlock(h);
        Ok(h)
    }
}

/// Daten in die (geöffnete) Zwischenablage legen. Bei Erfolg gehört der Speicher dem System.
fn put(format: u32, bytes: &[u8]) -> Result<()> {
    let h = alloc_global(bytes)?;
    // SAFETY: h ist ein gültiger beweglicher Block, die Zwischenablage ist geöffnet.
    unsafe {
        if SetClipboardData(format, Some(HANDLE(h.0))).is_err() {
            let _ = GlobalFree(Some(h));
            bail!("SetClipboardData fehlgeschlagen");
        }
    }
    Ok(())
}

/// Daten eines Formats kopieren (Zwischenablage muss geöffnet sein).
fn get(format: u32) -> Option<Vec<u8>> {
    // SAFETY: Das Handle gehört der Zwischenablage; wir sperren, kopieren und entsperren es.
    unsafe {
        IsClipboardFormatAvailable(format).ok()?;
        let h = GetClipboardData(format).ok()?;
        let g = HGLOBAL(h.0);
        let size = GlobalSize(g);
        let p = GlobalLock(g);
        if p.is_null() || size == 0 {
            return None;
        }
        let v = std::slice::from_raw_parts(p as *const u8, size).to_vec();
        let _ = GlobalUnlock(g);
        Some(v)
    }
}

// ---------------------------------------------------------------- Bildformate

/// Zeilen RGBA → BGRA, von unten nach oben (klassisches DIB), mit V5-Kopf und Alpha-Maske.
fn build_dibv5(img: &RgbaImage) -> Vec<u8> {
    let (w, h) = (img.width() as usize, img.height() as usize);
    let header = BITMAPV5HEADER {
        bV5Size: std::mem::size_of::<BITMAPV5HEADER>() as u32,
        bV5Width: w as i32,
        bV5Height: h as i32,
        bV5Planes: 1,
        bV5BitCount: 32,
        bV5Compression: BI_BITFIELDS,
        bV5SizeImage: (w * h * 4) as u32,
        bV5RedMask: 0x00FF_0000,
        bV5GreenMask: 0x0000_FF00,
        bV5BlueMask: 0x0000_00FF,
        bV5AlphaMask: 0xFF00_0000,
        bV5CSType: 0x7352_4742, // LCS_sRGB
        bV5Intent: 4,           // LCS_GM_IMAGES
        ..Default::default()
    };
    let hs = std::mem::size_of::<BITMAPV5HEADER>();
    let mut out = vec![0u8; hs + w * h * 4];
    // SAFETY: out ist mindestens hs Bytes groß; BITMAPV5HEADER ist ein reines Datenfeld ohne Padding-Pflichten.
    unsafe { std::ptr::copy_nonoverlapping(&header as *const BITMAPV5HEADER as *const u8, out.as_mut_ptr(), hs) };
    let raw = img.as_raw();
    for y in 0..h {
        let src = &raw[(h - 1 - y) * w * 4..(h - y) * w * 4];
        let dst = &mut out[hs + y * w * 4..hs + (y + 1) * w * 4];
        for (d, s) in dst.chunks_exact_mut(4).zip(src.chunks_exact(4)) {
            d[0] = s[2];
            d[1] = s[1];
            d[2] = s[0];
            d[3] = s[3];
        }
    }
    out
}

fn mask_shift(mask: u32) -> Option<(u32, u32)> {
    if mask == 0 {
        return None;
    }
    let shift = mask.trailing_zeros();
    let bits = (mask >> shift).trailing_ones();
    Some((shift, bits))
}

fn extract(px: u32, ms: Option<(u32, u32)>, default: u8) -> u8 {
    match ms {
        None => default,
        Some((shift, bits)) => {
            let v = (px >> shift) & ((1u64 << bits) - 1) as u32;
            if bits >= 8 {
                (v >> (bits - 8)) as u8
            } else {
                (v * 255 / ((1u32 << bits) - 1)) as u8
            }
        }
    }
}

/// CF_DIB/CF_DIBV5 (24/32 Bit, unten-oben oder oben-unten, BI_RGB/BI_BITFIELDS) → RGBA.
fn parse_dib(d: &[u8]) -> Option<RgbaImage> {
    let u32_at = |o: usize| d.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    let header = u32_at(0)? as usize;
    if header < 40 {
        return None;
    }
    let width = u32_at(4)? as i32;
    let height = u32_at(8)? as i32;
    let bpp = u16::from_le_bytes([*d.get(14)?, *d.get(15)?]) as u32;
    let compression = u32_at(16)?;
    let clr_used = u32_at(32)? as usize;
    if width <= 0 || height == 0 || !(bpp == 24 || bpp == 32) || !(compression == 0 || compression == 3) {
        return None;
    }
    let top_down = height < 0;
    let (w, h) = (width as usize, height.unsigned_abs() as usize);
    let mut off = header;
    // Masken: bei V4/V5 im Kopf, bei 40-Byte-Kopf und BITFIELDS dahinter.
    let (mut rm, mut gm, mut bm, mut am) = (0x00FF_0000u32, 0x0000_FF00u32, 0x0000_00FFu32, 0u32);
    if compression == 3 {
        if header >= 56 {
            rm = u32_at(40)?;
            gm = u32_at(44)?;
            bm = u32_at(48)?;
            am = u32_at(52)?;
        } else {
            rm = u32_at(40)?;
            gm = u32_at(44)?;
            bm = u32_at(48)?;
            off += 12;
        }
    }
    off += clr_used * 4;
    let stride = (w * bpp as usize).div_ceil(32) * 4;
    if d.len() < off + stride * (h - 1) + w * (bpp as usize / 8) {
        return None;
    }
    let (rs, gs, bs, as_) = (mask_shift(rm), mask_shift(gm), mask_shift(bm), mask_shift(am));
    let mut out = vec![0u8; w * h * 4];
    let mut any_alpha = false;
    for y in 0..h {
        let sy = if top_down { y } else { h - 1 - y };
        let row = &d[off + sy * stride..];
        for x in 0..w {
            let o = (y * w + x) * 4;
            if bpp == 24 {
                let p = &row[x * 3..x * 3 + 3];
                out[o] = p[2];
                out[o + 1] = p[1];
                out[o + 2] = p[0];
                out[o + 3] = 255;
            } else {
                let p = &row[x * 4..x * 4 + 4];
                let px = u32::from_le_bytes([p[0], p[1], p[2], p[3]]);
                out[o] = extract(px, rs, 0);
                out[o + 1] = extract(px, gs, 0);
                out[o + 2] = extract(px, bs, 0);
                let a = extract(px, as_, 255);
                any_alpha |= a != 0;
                out[o + 3] = a;
            }
        }
    }
    if bpp == 32 && !any_alpha {
        // Viele Programme lassen das vierte Byte leer: dann ist das Bild opak.
        for p in out.chunks_exact_mut(4) {
            p[3] = 255;
        }
    }
    RgbaImage::from_raw(w as u32, h as u32, out)
}

/// Erste Datei aus CF_HDROP.
fn first_drop_file(d: &[u8]) -> Option<PathBuf> {
    let off = u32::from_le_bytes(d.get(0..4)?.try_into().ok()?) as usize;
    let wide = u32::from_le_bytes(d.get(16..20)?.try_into().ok()?) != 0;
    let rest = d.get(off..)?;
    if wide {
        let units: Vec<u16> = rest.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        let end = units.iter().position(|&c| c == 0)?;
        if end == 0 {
            return None;
        }
        Some(PathBuf::from(String::from_utf16_lossy(&units[..end])))
    } else {
        let end = rest.iter().position(|&c| c == 0)?;
        if end == 0 {
            return None;
        }
        Some(PathBuf::from(String::from_utf8_lossy(&rest[..end]).into_owned()))
    }
}

fn is_image_file(p: &Path) -> bool {
    matches!(
        p.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(),
        Some("png" | "jpg" | "jpeg" | "gif" | "bmp")
    )
}

// ---------------------------------------------------------------- Clipboard-Thread

enum Req {
    Image(Arc<dyn ImageProvider>),
    Text(String),
    Files(Vec<PathBuf>),
}

struct Call {
    req: Req,
    result: Result<()>,
}

fn render_png(p: &dyn ImageProvider) -> Option<Vec<u8>> {
    if p.format() == ImageFormat::Png {
        if let Some(b) = p.encoded() {
            return Some(b);
        }
    }
    knips_core::imageops::encode(&*p.image()?, ImageFormat::Png).ok()
}

/// Ein verzögertes Format liefern. Die Zwischenablage ist dabei vom Anfragenden geöffnet.
fn render(format: u32) {
    let Some(p) = CURRENT.lock().clone() else { return };
    let f = formats();
    let (bit, bytes) = if format == f.png {
        (1u8, render_png(&*p))
    } else if format == CF_DIBV5 {
        (2u8, p.image().map(|i| build_dibv5(&i)))
    } else if format == f.jfif {
        (4u8, if p.format() == ImageFormat::Jpeg { p.encoded() } else { None })
    } else {
        return;
    };
    if let Some(b) = bytes {
        if put(format, &b).is_ok() {
            RENDERED.fetch_or(bit, Ordering::SeqCst);
        }
    }
}

/// Alles Ausstehende liefern (Programmende): Zwischenablage selbst öffnen, nichts leeren.
fn render_all(hwnd: HWND) {
    if CURRENT.lock().is_none() {
        return;
    }
    let Ok(_open) = open(Some(hwnd)) else { return };
    let f = formats();
    let done = RENDERED.load(Ordering::SeqCst);
    let jpeg = CURRENT.lock().as_ref().is_some_and(|p| p.format() == ImageFormat::Jpeg);
    if done & 1 == 0 {
        render(f.png);
    }
    if done & 2 == 0 {
        render(CF_DIBV5);
    }
    if jpeg && done & 4 == 0 {
        render(f.jfif);
    }
}

fn handle(hwnd: HWND, req: &Req) -> Result<()> {
    let f = formats();
    let _open = open(Some(hwnd))?;
    // Löst für den alten Inhalt WM_DESTROYCLIPBOARD aus — daher erst leeren, dann merken.
    // SAFETY: Zwischenablage ist geöffnet, wir sind Besitzer-Fenster.
    unsafe { EmptyClipboard() }?;
    match req {
        Req::Image(p) => {
            RENDERED.store(0, Ordering::SeqCst);
            *CURRENT.lock() = Some(p.clone());
            // NULL = „später liefern“. Der Rückgabewert ist dafür NULL und kein Fehler.
            // SAFETY: Ansage ohne Speicher.
            unsafe {
                let _ = SetClipboardData(f.png, None);
                let _ = SetClipboardData(CF_DIBV5, None);
                if p.format() == ImageFormat::Jpeg {
                    let _ = SetClipboardData(f.jfif, None);
                }
            }
        }
        Req::Text(t) => {
            let bytes: Vec<u8> = t.encode_utf16().chain(std::iter::once(0)).flat_map(|c| c.to_le_bytes()).collect();
            put(CF_UNICODETEXT, &bytes)?;
        }
        Req::Files(paths) => {
            // DROPFILES: pFiles = 20, pt = (0,0), fNC = 0, fWide = 1; danach Pfade, je null-terminiert, am Ende eine Null.
            let mut v: Vec<u8> = Vec::new();
            v.extend_from_slice(&20u32.to_le_bytes());
            v.extend_from_slice(&[0u8; 12]);
            v.extend_from_slice(&1u32.to_le_bytes());
            for p in paths {
                let abs = if p.is_absolute() { p.clone() } else { std::env::current_dir()?.join(p) };
                for c in wide_path(&abs) {
                    v.extend_from_slice(&c.to_le_bytes());
                }
            }
            v.extend_from_slice(&0u16.to_le_bytes());
            put(CF_HDROP, &v)?;
            put(f.drop_effect, &1u32.to_le_bytes())?; // DROPEFFECT_COPY
        }
    }
    Ok(())
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    // Panics dürfen nicht durch die Windows-Grenze laufen.
    let r = std::panic::catch_unwind(|| match msg {
        WM_CALL => {
            // SAFETY: lp zeigt auf ein `Call` im blockierenden SendMessageW des Aufrufers.
            let call = unsafe { &mut *(lp.0 as *mut Call) };
            call.result = handle(hwnd, &call.req);
            Some(LRESULT(1))
        }
        WM_FLUSH => {
            // SAFETY: nur Abfrage.
            if unsafe { GetClipboardOwner() }.ok() == Some(hwnd) {
                render_all(hwnd);
            }
            Some(LRESULT(0))
        }
        WM_RENDERFORMAT => {
            render(wp.0 as u32);
            Some(LRESULT(0))
        }
        WM_RENDERALLFORMATS => {
            render_all(hwnd);
            Some(LRESULT(0))
        }
        WM_DESTROYCLIPBOARD => {
            *CURRENT.lock() = None;
            Some(LRESULT(0))
        }
        _ => None,
    });
    match r {
        Ok(Some(l)) => l,
        // SAFETY: Standardbehandlung mit unveränderten Parametern.
        Ok(None) => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
        Err(_) => LRESULT(0),
    }
}

static OWNER: OnceLock<std::result::Result<isize, String>> = OnceLock::new();

extern "C" {
    fn atexit(cb: extern "C" fn()) -> i32;
}

/// Beim normalen Programmende angekündigte Formate noch ausliefern, damit „Kopieren, dann beenden“ geht.
extern "C" fn flush_at_exit() {
    if let Some(Ok(h)) = OWNER.get() {
        if CURRENT.try_lock().is_some_and(|c| c.is_some()) {
            // SAFETY: Fenster gehört dem Clipboard-Thread; mit Zeitlimit, damit das Beenden nie hängt.
            unsafe {
                let _ = SendMessageTimeoutW(HWND(*h as *mut c_void), WM_FLUSH, WPARAM(0), LPARAM(0), SMTO_ABORTIFHUNG, 3000, None);
            }
        }
    }
}

fn run_thread(tx: std::sync::mpsc::Sender<std::result::Result<isize, String>>) {
    // SAFETY: Fensterklasse und -fenster gehören diesem Thread, der die Nachrichten auch verarbeitet.
    unsafe {
        let hinst = match GetModuleHandleW(PCWSTR::null()) {
            Ok(h) => HINSTANCE(h.0),
            Err(e) => {
                let _ = tx.send(Err(e.to_string()));
                return;
            }
        };
        let class = w!("KnipsClipboardOwner");
        let wc = WNDCLASSW { lpfnWndProc: Some(wnd_proc), hInstance: hinst, lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc); // 0 = „gibt es schon“ ist unkritisch
        let hwnd = match CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("Knips Zwischenablage"),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
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
        let _ = tx.send(Ok(hwnd.0 as isize));
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

fn owner() -> Result<HWND> {
    let r = OWNER.get_or_init(|| {
        let (tx, rx) = channel();
        if let Err(e) = std::thread::Builder::new().name("clipboard".into()).spawn(move || run_thread(tx)) {
            return Err(e.to_string());
        }
        let r = rx.recv_timeout(Duration::from_secs(5)).map_err(|e| e.to_string()).and_then(|r| r);
        if r.is_ok() {
            // SAFETY: Funktion mit passender Signatur, läuft einmal beim Prozessende.
            unsafe {
                atexit(flush_at_exit);
            }
        }
        r
    });
    match r {
        Ok(h) => Ok(HWND(*h as *mut c_void)),
        Err(e) => Err(anyhow!("Zwischenablage-Thread: {e}")),
    }
}

fn call(req: Req) -> Result<()> {
    if DISABLED.load(Ordering::SeqCst) {
        return Ok(());
    }
    let hwnd = owner()?;
    let mut c = Call { req, result: Err(anyhow!("nicht verarbeitet")) };
    // SAFETY: SendMessageW blockiert, bis der Clipboard-Thread fertig ist; `c` lebt so lange.
    unsafe {
        SendMessageW(hwnd, WM_CALL, None, Some(LPARAM(&mut c as *mut Call as isize)));
    }
    c.result
}

// ---------------------------------------------------------------- Öffentliche Schnittstelle

/// Sofort zurück; PNG, DIBV5 (und JFIF bei JPEG) werden erst bei Anfrage erzeugt
/// (verzögertes Rendern, `WM_RENDERFORMAT`). Bleibt auch nach Programmende gültig
/// (`WM_RENDERALLFORMATS`).
pub fn set_image(provider: Arc<dyn ImageProvider>) -> Result<()> {
    call(Req::Image(provider))
}

pub fn set_text(text: &str) -> Result<()> {
    call(Req::Text(text.to_string()))
}

/// Dateien zum Einfügen (CF_HDROP, „Kopieren“).
pub fn set_files(paths: &[PathBuf]) -> Result<()> {
    call(Req::Files(paths.to_vec()))
}

/// Bild aus der Zwischenablage: PNG, sonst DIB(V5), sonst erste Bilddatei aus CF_HDROP.
pub fn get_image() -> Option<RgbaImage> {
    if DISABLED.load(Ordering::SeqCst) {
        return None;
    }
    let f = formats();
    // Daten bei geöffneter Zwischenablage kopieren, danach (ohne Sperre) dekodieren.
    let (png, dib, drop) = {
        let _open = open(None).ok()?;
        (get(f.png), get(CF_DIBV5).or_else(|| get(CF_DIB)), get(CF_HDROP))
    };
    if let Some(img) = png.and_then(|b| knips_core::imageops::decode(&b).ok()) {
        return Some(img);
    }
    if let Some(img) = dib.and_then(|b| parse_dib(&b)) {
        return Some(img);
    }
    let path = first_drop_file(&drop?)?;
    if !is_image_file(&path) {
        return None;
    }
    knips_core::imageops::load(&path).ok()
}

/// Selbsttests: Zwischenablage nie anfassen.
pub fn set_disabled(disabled: bool) {
    DISABLED.store(disabled, Ordering::SeqCst);
}
