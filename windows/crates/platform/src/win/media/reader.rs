//! Video lesen: `probe`, `FrameReader`, `thumbnail`, Tonleser für den Export.

use std::path::Path;

use anyhow::{anyhow, bail, Result};
use knips_core::imageops;
use knips_core::RgbaImage;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;

use super::pure;
use super::util::*;
use super::VideoInfo;

const VIDEO: u32 = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;
const ALL: u32 = MF_SOURCE_READER_ALL_STREAMS.0 as u32;
const MEDIASOURCE: u32 = MF_SOURCE_READER_MEDIASOURCE.0 as u32;

/// Weniger als 0,5 ms Abweichung gilt als „gleiche Zeit“ (Rundung von k/fps).
const SLACK: i64 = 5_000;
/// Liegt die gewünschte Zeit weniger weit voraus, wird vorwärts dekodiert statt zu springen.
const FORWARD_LIMIT: i64 = 2 * pure::TICKS;

fn open_reader(path: &Path, video_processing: bool) -> Result<IMFSourceReader> {
    let url = wide(path);
    let attrs = new_attrs(2)?;
    // SAFETY: `url` ist nullterminiert und lebt über den Aufruf.
    unsafe {
        if video_processing {
            attrs.SetUINT32(&MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1).ctx("Videoverarbeitung")?;
        }
        MFCreateSourceReaderFromURL(windows::core::PCWSTR(url.as_ptr()), &attrs).ctx("Video öffnen")
    }
}

/// Videodaten des Readers: Größe, Bildrate, Codec.
struct VideoMeta {
    w: u32,
    h: u32,
    fps: f64,
    hevc: bool,
    has_audio: bool,
    duration: f64,
}

fn meta(reader: &IMFSourceReader) -> Result<VideoMeta> {
    // SAFETY: Lesezugriffe auf den gültigen Reader; PROPVARIANT wird beim Verlassen freigegeben.
    unsafe {
        let native = reader.GetNativeMediaType(VIDEO, 0).ctx("Kein Videostrom")?;
        let hevc = subtype(&native).map(|g| is_hevc(&g)).unwrap_or(false);
        let fps = get_fps(&native);
        let native_size = get_size(&native);
        let has_audio = reader.GetNativeMediaType(AUDIO, 0).is_ok();
        let duration = reader
            .GetPresentationAttribute(MEDIASOURCE, &MF_PD_DURATION)
            .ok()
            .and_then(|pv: PROPVARIANT| u64::try_from(&pv).ok())
            .map(|t| t as f64 / pure::TICKS as f64)
            .unwrap_or(0.0);
        let (w, h) = native_size.unwrap_or((0, 0));
        Ok(VideoMeta { w, h, fps, hevc, has_audio, duration })
    }
}

/// Reader mit RGB32-Ausgabe auf dem Videostrom (nur Video gewählt). Liefert Reader und echte Größe.
fn open_rgb(path: &Path) -> Result<(IMFSourceReader, VideoMeta)> {
    let reader = open_reader(path, true)?;
    let mut m = meta(&reader)?;
    // SAFETY: Typ-Objekte lokal; Reader gültig.
    unsafe {
        reader.SetStreamSelection(ALL, false).ctx("Ströme abwählen")?;
        reader.SetStreamSelection(VIDEO, true).ctx("Videostrom wählen")?;
        let t = new_type()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).ctx("Typ")?;
        t.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32).ctx("Typ")?;
        reader.SetCurrentMediaType(VIDEO, None, &t).ctx("RGB32 wählen")?;
        let cur = reader.GetCurrentMediaType(VIDEO).ctx("Videotyp")?;
        if let Some((w, h)) = get_size(&cur) {
            m.w = w;
            m.h = h;
        }
    }
    if m.w == 0 || m.h == 0 {
        bail!("Videogröße unbekannt");
    }
    Ok((reader, m))
}

fn current_stride(reader: &IMFSourceReader) -> Option<i32> {
    // SAFETY: Lesezugriff.
    unsafe {
        let cur = reader.GetCurrentMediaType(VIDEO).ok()?;
        cur.GetUINT32(&MF_MT_DEFAULT_STRIDE).ok().map(|v| v as i32)
    }
}

/// Höchstens so viele Zeitstempel für die wirksame Bildrate (Bildschirmaufnahmen: nur Bilder mit
/// Änderungen, also selbst bei 60 fps mindestens 10 s Bewegung). Nur Entpacken, kein Dekodieren —
/// liest aber die Bilddaten von der Platte, deshalb begrenzt und je Datei gemerkt.
const FPS_SCAN: usize = 600;

/// Wirksame Bildrate je Datei (Pfad, Größe, Änderungszeit) — `probe` läuft beim Öffnen, für
/// Vorschaubilder, Erkennung und Export jeweils erneut.
fn effective_fps_cached(path: &Path, nominal: f64) -> f64 {
    use std::collections::HashMap;
    use std::sync::Mutex;
    type Key = (std::path::PathBuf, u64, Option<std::time::SystemTime>);
    static CACHE: Mutex<Option<HashMap<Key, f64>>> = Mutex::new(None);
    let key: Option<Key> = std::fs::metadata(path).ok().map(|m| (path.to_path_buf(), m.len(), m.modified().ok()));
    if let Some(k) = &key {
        if let Some(fps) = CACHE.lock().ok().and_then(|c| c.as_ref().and_then(|c| c.get(k).copied())) {
            return fps;
        }
    }
    let fps = match sample_times(path, FPS_SCAN) {
        Ok(times) => pure::effective_fps(nominal, &times),
        Err(e) => {
            log::debug!("Bildabstände nicht lesbar ({e:#}), nehme die Angabe {nominal:.2} fps");
            return nominal;
        }
    };
    if let (Some(k), Ok(mut c)) = (key, CACHE.lock()) {
        let c = c.get_or_insert_with(HashMap::new);
        if c.len() > 64 {
            c.clear();
        }
        c.insert(k, fps);
    }
    fps
}

/// Zeitstempel der ersten `limit` Videoproben (komprimiert gelesen, ohne Decoder; 100 ns).
fn sample_times(path: &Path, limit: usize) -> Result<Vec<i64>> {
    let reader = open_reader(path, false)?;
    let mut out = Vec::new();
    // SAFETY: Ausgabezeiger zeigen auf lokale Variablen; Reader ist gültig.
    unsafe {
        reader.SetStreamSelection(ALL, false).ctx("Ströme abwählen")?;
        reader.SetStreamSelection(VIDEO, true).ctx("Videostrom wählen")?;
        while out.len() < limit {
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut sample: Option<IMFSample> = None;
            reader.ReadSample(VIDEO, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut sample)).ctx("Probe lesen")?;
            if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
                bail!("Lesefehler im Video");
            }
            if sample.is_some() {
                out.push(ts);
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                break;
            }
        }
    }
    Ok(out)
}

/// `fps` ist die **wirksame** Bildrate (`pure::effective_fps`): Bildschirmaufnahmen haben variable
/// Bildrate, die Angabe im MP4 ist nur der Durchschnitt.
pub fn probe(path: &Path) -> Result<VideoInfo> {
    let _com = enter()?;
    let (_r, m) = open_rgb(path)?;
    let fps = effective_fps_cached(path, m.fps);
    Ok(VideoInfo { duration: m.duration, width: m.w, height: m.h, fps, hevc: m.hevc, has_audio: m.has_audio })
}

struct Cur {
    ts: i64,
    sample: IMFSample,
    img: Option<RgbaImage>,
}

/// Bilder aus einem Video lesen, optional verkleinert (längste Kante ≤ `max_size`).
pub struct FrameReader {
    reader: IMFSourceReader,
    w: u32,
    h: u32,
    max_size: Option<u32>,
    cur: Option<Cur>,
    ahead: Option<(i64, IMFSample)>,
    eos: bool,
    /// Zeitstempel des ersten Bildes. Ohne Edit-Liste (B-Bilder) beginnt ein Video bei 1/fps statt 0;
    /// wie AVFoundation auf dem Mac zählt das erste Bild als 0.
    base: i64,
}

/// Größter Versatz des ersten Bildes, der als Umordnung gilt (später beginnende Spuren bleiben).
const MAX_BASE: i64 = pure::TICKS / 2;

// SAFETY: Reader ist MTA-fähig; `FrameReader` wird nur über `&mut self` benutzt.
unsafe impl Send for FrameReader {}

impl FrameReader {
    pub fn open(path: &Path, max_size: Option<u32>) -> Result<Self> {
        let _com = enter()?;
        let (reader, m) = open_rgb(path)?;
        let mut me = Self { reader, w: m.w, h: m.h, max_size, cur: None, ahead: None, eos: false, base: 0 };
        match me.read_next()? {
            Some((ts, sample)) => {
                if ts > 0 && ts <= MAX_BASE {
                    me.base = ts;
                }
                me.ahead = Some((ts - me.base, sample));
            }
            None => me.eos = true,
        }
        Ok(me)
    }

    pub(super) fn size(&self) -> (u32, u32) {
        (self.w, self.h)
    }

    /// Nächste Probe des Videostroms: `None` am Ende. Proben ohne Inhalt (Lücken) werden übersprungen.
    fn read_next(&mut self) -> Result<Option<(i64, IMFSample)>> {
        loop {
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut sample: Option<IMFSample> = None;
            // SAFETY: Ausgabezeiger zeigen auf lokale Variablen.
            unsafe { self.reader.ReadSample(VIDEO, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut sample)) }.ctx("Bild lesen")?;
            if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
                bail!("Lesefehler im Video");
            }
            if flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED.0 as u32 != 0 {
                // SAFETY: Lesezugriff.
                if let Some((w, h)) = unsafe { self.reader.GetCurrentMediaType(VIDEO) }.ok().and_then(|t| get_size(&t)) {
                    self.w = w;
                    self.h = h;
                }
            }
            if let Some(s) = sample {
                return Ok(Some((ts - self.base, s)));
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                return Ok(None);
            }
        }
    }

    fn seek(&mut self, ticks: i64) -> Result<()> {
        self.cur = None;
        self.ahead = None;
        self.eos = false;
        let pv = PROPVARIANT::from(ticks.max(0) + self.base);
        // SAFETY: GUID_NULL = Zeitformat 100 ns; `pv` lebt über den Aufruf.
        unsafe { self.reader.SetCurrentPosition(&windows::core::GUID::zeroed(), &pv) }.ctx("Springen im Video")
    }

    /// Bild, das zum Zeitpunkt `t` (Sekunden) zu sehen ist — genau, nicht das nächste Schlüsselbild.
    pub fn frame_at(&mut self, t: f64) -> Result<Option<RgbaImage>> {
        let _com = com_init();
        let want = pure::secs_to_ticks(t.max(0.0));
        let cached = match (&self.cur, &self.ahead) {
            (Some(c), Some((a, _))) => want >= c.ts - SLACK && *a > want + SLACK,
            (Some(c), None) => self.eos && want >= c.ts - SLACK,
            _ => false,
        };
        if !cached {
            let pos = self.ahead.as_ref().map(|a| a.0).or(self.cur.as_ref().map(|c| c.ts));
            let backwards = self.cur.as_ref().is_some_and(|c| want < c.ts - SLACK);
            let far = pos.is_some_and(|p| want - p > FORWARD_LIMIT);
            // Am Anfang (noch nichts gelesen) wird bei nahen Zeiten einfach vorwärts gelesen.
            let far_from_start = pos.is_none() && want > FORWARD_LIMIT;
            if backwards || far || far_from_start {
                self.seek(want)?;
            }
            self.advance_to(want)?;
        }
        let Some(cur) = self.cur.as_mut() else { return Ok(None) };
        if cur.img.is_none() {
            let (w, h) = (self.w as usize, self.h as usize);
            let stride = current_stride(&self.reader);
            let bgra = sample_to_bgra(&cur.sample, w, h, stride)?;
            cur.img = Some(imageops::from_bgra(self.w, self.h, w * 4, &bgra, true));
        }
        let img = cur.img.as_ref().ok_or_else(|| anyhow!("Bild fehlt"))?;
        Ok(Some(match self.max_size {
            Some(m) if img.width().max(img.height()) > m => imageops::downscale(img, m),
            _ => img.clone(),
        }))
    }

    /// Liest vorwärts, bis die nächste Probe nach `want` liegt; die davor ist das gesuchte Bild.
    fn advance_to(&mut self, want: i64) -> Result<()> {
        loop {
            let next = match self.ahead.take() {
                Some(a) => Some(a),
                None => {
                    if self.eos {
                        None
                    } else {
                        self.read_next()?
                    }
                }
            };
            match next {
                None => {
                    self.eos = true;
                    return Ok(());
                }
                Some((ts, s)) => {
                    if ts > want + SLACK && self.cur.is_some() {
                        self.ahead = Some((ts, s));
                        return Ok(());
                    }
                    self.cur = Some(Cur { ts, sample: s, img: None });
                }
            }
        }
    }
}

/// Erstes Bild, auf `max_pixel` (längste Kante) verkleinert.
pub fn thumbnail(path: &Path, max_pixel: u32) -> Result<RgbaImage> {
    let mut r = FrameReader::open(path, Some(max_pixel))?;
    r.frame_at(0.0)?.ok_or_else(|| anyhow!("Das Video enthält kein Bild."))
}

// ───────────────────────── Ton für den Export ─────────────────────────

pub(super) struct AudioReader {
    reader: IMFSourceReader,
    /// PCM-Typ (16 Bit), wie er aus dem Reader kommt — Eingangstyp für den Schreiber.
    pub pcm: IMFMediaType,
    pub rate: u32,
    pub block: u32,
}

// SAFETY: wie `FrameReader`.
unsafe impl Send for AudioReader {}

impl AudioReader {
    /// `None`, wenn das Video keinen Ton hat oder er sich nicht als PCM lesen lässt.
    pub fn open(path: &Path) -> Option<Self> {
        match Self::try_open(path) {
            Ok(a) => a,
            Err(e) => {
                log::warn!("Ton der Quelle nicht lesbar, Export ohne Ton: {e:#}");
                None
            }
        }
    }

    fn try_open(path: &Path) -> Result<Option<Self>> {
        let reader = open_reader(path, false)?;
        // SAFETY: Lese-/Schreibzugriffe auf gültige Objekte.
        unsafe {
            let Ok(native) = reader.GetNativeMediaType(AUDIO, 0) else { return Ok(None) };
            let rate = native.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND).unwrap_or(48_000);
            let ch = native.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS).unwrap_or(1).clamp(1, 2);
            reader.SetStreamSelection(ALL, false).ctx("Ströme abwählen")?;
            reader.SetStreamSelection(AUDIO, true).ctx("Tonstrom wählen")?;
            let t = new_type()?;
            t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio).ctx("Typ")?;
            t.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM).ctx("Typ")?;
            t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16).ctx("Typ")?;
            t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate).ctx("Typ")?;
            t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, ch).ctx("Typ")?;
            t.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, ch * 2).ctx("Typ")?;
            t.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * ch * 2).ctx("Typ")?;
            reader.SetCurrentMediaType(AUDIO, None, &t).ctx("PCM wählen")?;
            let pcm = reader.GetCurrentMediaType(AUDIO).ctx("Tontyp")?;
            let rate = pcm.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND).unwrap_or(rate);
            let block = pcm.GetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT).unwrap_or(ch * 2).max(1);
            Ok(Some(Self { reader, pcm, rate, block }))
        }
    }

    pub fn seek(&self, ticks: i64) -> Result<()> {
        let pv = PROPVARIANT::from(ticks.max(0));
        // SAFETY: wie `FrameReader::seek`.
        unsafe { self.reader.SetCurrentPosition(&windows::core::GUID::zeroed(), &pv) }.ctx("Springen im Ton")
    }

    /// Nächster Tonblock (Zeit in Quellzeit, Dauer berechnet aus der Länge). `None` am Ende.
    pub fn next(&self) -> Result<Option<(i64, i64, IMFSample)>> {
        loop {
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut sample: Option<IMFSample> = None;
            // SAFETY: Ausgabezeiger zeigen auf lokale Variablen.
            unsafe { self.reader.ReadSample(AUDIO, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut sample)) }.ctx("Ton lesen")?;
            if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
                bail!("Lesefehler im Ton");
            }
            if let Some(s) = sample {
                // SAFETY: Lesezugriff.
                let bytes = unsafe { s.GetTotalLength() }.unwrap_or(0) as i64;
                let dur = bytes / self.block as i64 * pure::TICKS / self.rate.max(1) as i64;
                return Ok(Some((ts, dur, s)));
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                return Ok(None);
            }
        }
    }
}
