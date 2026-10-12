//! Gemeinsame Media-Foundation-/COM-Helfer: Start, COM-Wächter, Attribute, Proben, Pufferzugriff.

use std::path::Path;
use std::sync::OnceLock;

use anyhow::{anyhow, bail, Result};
use windows::core::{Interface, GUID};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

use super::pure;

/// COM-Objekte der Media Foundation sind frei threadbar (MTA); dieser Mantel erlaubt es, sie
/// zwischen unseren eigenen Threads zu verschieben. Aufrufe geschehen jeweils nur auf einem Thread
/// gleichzeitig oder sind (Schreiber) durch einen `Mutex` geschützt.
pub struct SendCom<T>(pub T);
// SAFETY: siehe oben — nur MTA-fähige Media-Foundation-/D3D-/WinRT-Objekte werden verpackt.
unsafe impl<T> Send for SendCom<T> {}
unsafe impl<T> Sync for SendCom<T> {}

/// Hält COM für den aktuellen Thread initialisiert (MTA). Ist der Thread bereits anders
/// initialisiert (`RPC_E_CHANGED_MODE`), wird nichts geändert und nichts freigegeben.
pub struct Com(bool);

impl Drop for Com {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY: gehört zu einem erfolgreichen CoInitializeEx desselben Threads.
            unsafe { CoUninitialize() };
        }
    }
}

pub fn com_init() -> Com {
    // SAFETY: CoInitializeEx ist auf jedem Thread erlaubt; Rückgabe wird ausgewertet.
    let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    Com(hr.is_ok())
}

/// COM (MTA) für diesen Thread und `MFStartup` (einmal pro Prozess).
pub fn enter() -> Result<Com> {
    let com = com_init();
    static MF: OnceLock<std::result::Result<(), String>> = OnceLock::new();
    let r = MF.get_or_init(|| {
        // SAFETY: einmaliger Start; MFShutdown wird bewusst nie aufgerufen (Prozesslebensdauer).
        unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }.map_err(|e| e.message())
    });
    match r {
        Ok(()) => Ok(com),
        Err(m) => bail!("Media Foundation konnte nicht gestartet werden: {m}"),
    }
}

pub fn werr(ctx: &str, e: windows::core::Error) -> anyhow::Error {
    anyhow!("{ctx}: {} (0x{:08X})", e.message().trim(), e.code().0 as u32)
}

/// Fehler einer Windows-Funktion mit Kontext.
pub trait Ctx<T> {
    fn ctx(self, what: &str) -> Result<T>;
}

impl<T> Ctx<T> for windows::core::Result<T> {
    fn ctx(self, what: &str) -> Result<T> {
        self.map_err(|e| werr(what, e))
    }
}

pub fn wide(p: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    p.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}

/// Systemuhr (QPC) in 100-ns-Einheiten — gleiche Basis wie `SystemRelativeTime` der Bildschirmaufnahme.
pub fn qpc_100ns() -> i64 {
    let (mut c, mut f) = (0i64, 0i64);
    // SAFETY: gültige Zeiger auf lokale Variablen.
    unsafe {
        let _ = QueryPerformanceCounter(&mut c);
        let _ = QueryPerformanceFrequency(&mut f);
    }
    if f <= 0 {
        return 0;
    }
    (c as i128 * pure::TICKS as i128 / f as i128) as i64
}

pub fn new_attrs(n: u32) -> Result<IMFAttributes> {
    let mut a: Option<IMFAttributes> = None;
    // SAFETY: Ausgabezeiger zeigt auf lokale Option.
    unsafe { MFCreateAttributes(&mut a, n) }.ctx("MFCreateAttributes")?;
    a.ok_or_else(|| anyhow!("MFCreateAttributes lieferte nichts"))
}

pub fn new_type() -> Result<IMFMediaType> {
    // SAFETY: keine Vorbedingungen außer MFStartup (durch `enter` erfüllt).
    unsafe { MFCreateMediaType() }.ctx("MFCreateMediaType")
}

/// Videotyp mit Größe/Rate (gepackt als u64) — `MFSetAttributeSize` gibt es in der Bibliothek nicht.
pub fn video_type(subtype: &GUID, w: u32, h: u32, fps: u32) -> Result<IMFMediaType> {
    let t = new_type()?;
    // SAFETY: Attribut-Setter auf gültigem Objekt, Schlüssel sind statische GUIDs.
    unsafe {
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).ctx("MAJOR_TYPE")?;
        t.SetGUID(&MF_MT_SUBTYPE, subtype).ctx("SUBTYPE")?;
        t.SetUINT64(&MF_MT_FRAME_SIZE, pure::pack(w, h)).ctx("FRAME_SIZE")?;
        t.SetUINT64(&MF_MT_FRAME_RATE, pure::pack(fps.max(1), 1)).ctx("FRAME_RATE")?;
        t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pure::pack(1, 1)).ctx("PIXEL_ASPECT")?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).ctx("INTERLACE")?;
    }
    Ok(t)
}

/// BT.709, begrenzter Wertebereich (16–235) — wie die Mac-Aufnahme.
pub fn set_bt709(t: &IMFMediaType) -> Result<()> {
    // SAFETY: wie oben.
    unsafe {
        t.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32).ctx("PRIMARIES")?;
        t.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32).ctx("TRANSFER")?;
        t.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32).ctx("MATRIX")?;
        t.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32).ctx("RANGE")?;
    }
    Ok(())
}

pub fn get_size(t: &IMFMediaType) -> Option<(u32, u32)> {
    // SAFETY: Lesezugriff auf Attribut.
    let v = unsafe { t.GetUINT64(&MF_MT_FRAME_SIZE) }.ok()?;
    let (w, h) = pure::unpack(v);
    (w > 0 && h > 0).then_some((w, h))
}

pub fn get_fps(t: &IMFMediaType) -> f64 {
    // SAFETY: Lesezugriff auf Attribut.
    match unsafe { t.GetUINT64(&MF_MT_FRAME_RATE) } {
        Ok(v) => {
            let (n, d) = pure::unpack(v);
            if d == 0 {
                0.0
            } else {
                n as f64 / d as f64
            }
        }
        Err(_) => 0.0,
    }
}

pub fn subtype(t: &IMFMediaType) -> Option<GUID> {
    // SAFETY: Lesezugriff auf Attribut.
    unsafe { t.GetGUID(&MF_MT_SUBTYPE) }.ok()
}

pub fn is_hevc(g: &GUID) -> bool {
    // 'HEVC' und 'HVC1' (Media Foundation kennt je nach Quelle beide).
    g.data1 == 0x4356_4548 || g.data1 == 0x3143_5648
}

/// Gesperrter Medienpuffer; `Unlock` geschieht garantiert beim Verlassen.
pub struct Locked<'a> {
    buf: &'a IMFMediaBuffer,
    ptr: *mut u8,
    len: usize,
}

impl<'a> Locked<'a> {
    pub fn new(buf: &'a IMFMediaBuffer) -> Result<Self> {
        let mut p: *mut u8 = std::ptr::null_mut();
        let mut cur = 0u32;
        // SAFETY: Zeiger zeigen auf lokale Variablen; Unlock folgt in Drop.
        unsafe { buf.Lock(&mut p, None, Some(&mut cur)) }.ctx("Puffer sperren")?;
        Ok(Self { buf, ptr: p, len: cur as usize })
    }
    pub fn bytes(&self) -> &[u8] {
        if self.ptr.is_null() {
            return &[];
        }
        // SAFETY: Lock lieferte `len` gültige Bytes, solange der Puffer gesperrt ist (= solange `self` lebt).
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for Locked<'_> {
    fn drop(&mut self) {
        // SAFETY: Gegenstück zu dem Lock in `new`.
        unsafe {
            let _ = self.buf.Unlock();
        }
    }
}

/// Probe mit Kopie von `data`, Zeit und Dauer in 100 ns.
pub fn make_sample(data: &[u8], pts: i64, dur: i64) -> Result<IMFSample> {
    // SAFETY: Puffer wird in voller Länge angelegt, gesperrt, beschrieben, entsperrt und erst dann
    // der Probe hinzugefügt.
    unsafe {
        let buf = MFCreateMemoryBuffer(data.len() as u32).ctx("MFCreateMemoryBuffer")?;
        let mut p: *mut u8 = std::ptr::null_mut();
        let mut max = 0u32;
        buf.Lock(&mut p, Some(&mut max), None).ctx("Puffer sperren")?;
        if p.is_null() || (max as usize) < data.len() {
            let _ = buf.Unlock();
            bail!("Puffer zu klein");
        }
        std::ptr::copy_nonoverlapping(data.as_ptr(), p, data.len());
        buf.Unlock().ctx("Puffer entsperren")?;
        buf.SetCurrentLength(data.len() as u32).ctx("Puffer-Länge")?;
        let s = MFCreateSample().ctx("MFCreateSample")?;
        s.AddBuffer(&buf).ctx("AddBuffer")?;
        s.SetSampleTime(pts).ctx("SampleTime")?;
        s.SetSampleDuration(dur).ctx("SampleDuration")?;
        Ok(s)
    }
}

/// Dichtes BGRA (oben → unten) aus einer RGB32-Probe des Source Readers. Bevorzugt `IMF2DBuffer`
/// (liefert Zeile 0 = oben und Schrittweite mit Vorzeichen), sonst flacher Puffer + Standard-Stride.
pub fn sample_to_bgra(sample: &IMFSample, w: usize, h: usize, default_stride: Option<i32>) -> Result<Vec<u8>> {
    // SAFETY: Alle Zeigerzugriffe bleiben innerhalb der von Lock2D/Lock gemeldeten Zeilen: Zeile y
    // liegt bei scan0 + y·pitch und hat w·4 gültige Bytes; Unlock folgt in jedem Fall.
    unsafe {
        let buf = sample.ConvertToContiguousBuffer().ctx("ConvertToContiguousBuffer")?;
        if let Ok(b2) = buf.cast::<IMF2DBuffer>() {
            let mut scan0: *mut u8 = std::ptr::null_mut();
            let mut pitch = 0i32;
            if b2.Lock2D(&mut scan0, &mut pitch).is_ok() {
                let mut out = Vec::with_capacity(w * h * 4);
                if !scan0.is_null() {
                    for y in 0..h {
                        let row = scan0.offset(y as isize * pitch as isize);
                        out.extend_from_slice(std::slice::from_raw_parts(row, w * 4));
                    }
                }
                let _ = b2.Unlock2D();
                if out.len() == w * h * 4 {
                    return Ok(out);
                }
                bail!("Videobild leer");
            }
        }
        let lock = Locked::new(&buf)?;
        let data = lock.bytes();
        // Ohne Angabe ist RGB32 unten-nach-oben (negativer Stride).
        let stride = default_stride.map(|s| s as i64).unwrap_or(-(w as i64 * 4));
        if data.len() < stride.unsigned_abs() as usize * (h - 1) + w * 4 {
            bail!("Videobild unvollständig");
        }
        let mut out = Vec::new();
        pure::rows_to_top_down(data, stride, w, h, &mut out);
        Ok(out)
    }
}
