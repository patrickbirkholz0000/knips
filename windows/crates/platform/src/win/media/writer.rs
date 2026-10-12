//! MP4-Schreiber (IMFSinkWriter): H.264 (High) oder HEVC, optional AAC-Tonspur.
//! Eingang ist NV12 im Arbeitsspeicher, Zeiten in 100 ns.

use std::path::Path;

use anyhow::{anyhow, Result};
use windows::core::GUID;
use windows::Win32::Media::MediaFoundation::*;

use super::pure;
use super::util::*;

#[derive(Clone, Debug)]
pub struct VideoSpec {
    pub w: u32,
    pub h: u32,
    pub fps: u32,
    pub hevc: bool,
    pub bitrate: u32,
    /// Hardware-Encoder zulassen (`MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`).
    pub hardware: bool,
}

pub struct Mp4Writer {
    sw: IMFSinkWriter,
    video: u32,
    audio: Option<u32>,
    done: bool,
}

// SAFETY: Der Schreiber wird nur hinter einem Mutex von mehreren Threads benutzt; die
// Media-Foundation-Objekte sind MTA-fähig.
unsafe impl Send for Mp4Writer {}

pub struct Created {
    pub writer: Mp4Writer,
    pub hevc: bool,
    pub audio: bool,
    pub hardware: bool,
}

impl Mp4Writer {
    /// Legt den Schreiber an. Reihenfolge der Ausweichstufen: gewünschter Codec mit Hardware →
    /// gleicher Codec ohne Hardware → H.264 mit Hardware → H.264 ohne Hardware. Schlägt nur die
    /// Tonspur fehl, wird ohne Ton geschrieben (`audio == false`).
    pub fn create_with_fallback(path: &Path, spec: &VideoSpec, audio_in: Option<&IMFMediaType>) -> Result<Created> {
        let mut tries: Vec<(bool, bool)> = Vec::new();
        for hevc in [spec.hevc, false] {
            for hw in [spec.hardware, false] {
                if !tries.contains(&(hevc, hw)) {
                    tries.push((hevc, hw));
                }
            }
        }
        let mut last = anyhow!("kein Encoder");
        for (hevc, hw) in tries {
            let mut s = spec.clone();
            if hevc != spec.hevc {
                // Andere Bitratenformel für den Ersatz-Codec.
                s.bitrate = pure::bitrate(s.w, s.h, s.fps, hevc);
            }
            s.hevc = hevc;
            s.hardware = hw;
            for with_audio in [audio_in.is_some(), false] {
                match Self::create(path, &s, if with_audio { audio_in } else { None }) {
                    Ok(writer) => {
                        return Ok(Created { writer, hevc, audio: with_audio, hardware: hw });
                    }
                    Err(e) => {
                        log::warn!("MP4-Schreiber (hevc={hevc}, hardware={hw}, ton={with_audio}): {e:#}");
                        last = e;
                    }
                }
                if audio_in.is_none() {
                    break;
                }
            }
        }
        Err(last)
    }

    pub fn create(path: &Path, spec: &VideoSpec, audio_in: Option<&IMFMediaType>) -> Result<Self> {
        let url = wide(path);
        let attrs = new_attrs(4)?;
        // SAFETY: Alle Zeiger stammen von lokalen, lebenden Objekten; `url` ist nullterminiert und
        // lebt über den Aufruf hinaus.
        unsafe {
            attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, spec.hardware as u32).ctx("Hardware-Schalter")?;
            // Nicht ausbremsen: Bild und Ton kommen von verschiedenen Threads.
            attrs.SetUINT32(&MF_SINK_WRITER_DISABLE_THROTTLING, 1).ctx("Throttling")?;
            attrs.SetGUID(&MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4).ctx("Container")?;
            let sw = MFCreateSinkWriterFromURL(windows::core::PCWSTR(url.as_ptr()), None, &attrs).ctx("MP4 anlegen")?;

            // Ausgangstyp (kodiert).
            let codec: GUID = if spec.hevc { MFVideoFormat_HEVC } else { MFVideoFormat_H264 };
            let out = video_type(&codec, spec.w, spec.h, spec.fps)?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, spec.bitrate).ctx("Bitrate")?;
            if !spec.hevc {
                out.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High.0 as u32).ctx("Profil")?;
            }
            set_bt709(&out)?;
            let video = sw.AddStream(&out).ctx("Videospur")?;

            // Eingangstyp NV12; Encoder-Parameter (GOP, Bitrate, keine B-Bilder). Manche Hardware-Encoder
            // lehnen einzelne Parameter ab → zweiter Versuch ohne. B-Bilder ausdrücklich aus: der
            // MPEG-4-Schreiber legt sonst keine Edit-Liste an, alle Zeitstempel rutschen um ein Bild nach
            // hinten (erstes Bild bei 1/fps statt 0, Bild ein Bild später als der Ton).
            let inp = video_type(&MFVideoFormat_NV12, spec.w, spec.h, spec.fps)?;
            inp.SetUINT32(&MF_MT_DEFAULT_STRIDE, spec.w).ctx("Stride")?;
            set_bt709(&inp)?;
            let params = new_attrs(5)?;
            params.SetUINT32(&CODECAPI_AVEncMPVGOPSize, pure::gop(spec.fps)).ctx("GOP")?;
            params.SetUINT32(&CODECAPI_AVEncMPVDefaultBPictureCount, 0).ctx("B-Bilder")?;
            params.SetUINT32(&CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_UnconstrainedVBR.0 as u32).ctx("Ratenregelung")?;
            params.SetUINT32(&CODECAPI_AVEncCommonMeanBitRate, spec.bitrate).ctx("Mittlere Bitrate")?;
            if let Err(e) = sw.SetInputMediaType(video, &inp, &params) {
                log::warn!("Encoder-Parameter abgelehnt ({e}), neuer Versuch ohne");
                let params2 = new_attrs(2)?;
                params2.SetUINT32(&CODECAPI_AVEncMPVGOPSize, pure::gop(spec.fps)).ctx("GOP")?;
                params2.SetUINT32(&CODECAPI_AVEncMPVDefaultBPictureCount, 0).ctx("B-Bilder")?;
                if sw.SetInputMediaType(video, &inp, &params2).is_err() {
                    sw.SetInputMediaType(video, &inp, None::<&IMFAttributes>).ctx("Videoeingang")?;
                }
            }

            let audio = match audio_in {
                Some(pcm) => Some(add_aac(&sw, pcm)?),
                None => None,
            };
            sw.BeginWriting().ctx("Schreiben starten")?;
            Ok(Self { sw, video, audio, done: false })
        }
    }

    /// Ein NV12-Bild mit Zeit und Dauer (100 ns).
    pub fn write_video(&self, nv12: &[u8], pts: i64, dur: i64) -> Result<()> {
        let s = make_sample(nv12, pts, dur)?;
        // SAFETY: gültiger Strom-Index und Probe.
        unsafe { self.sw.WriteSample(self.video, &s) }.ctx("Bild schreiben")
    }

    /// Tonprobe (PCM, Zeit bereits auf Videozeit abgebildet).
    pub fn write_audio(&self, sample: &IMFSample) -> Result<()> {
        let Some(idx) = self.audio else { return Ok(()) };
        // SAFETY: gültiger Strom-Index und Probe.
        unsafe { self.sw.WriteSample(idx, sample) }.ctx("Ton schreiben")
    }

    /// Schließt die MP4-Datei ab (Index schreiben).
    pub fn finalize(mut self) -> Result<()> {
        self.done = true;
        // SAFETY: Schreiber ist gültig; nach Finalize wird er nur noch freigegeben.
        unsafe { self.sw.Finalize() }.ctx("MP4 abschließen")
    }
}

/// AAC-Ausgangstyp aus dem PCM-Eingang (Rate/Kanäle übernehmen), Strom hinzufügen.
unsafe fn add_aac(sw: &IMFSinkWriter, pcm: &IMFMediaType) -> Result<u32> {
    // SAFETY (gesamte Funktion): nur Attribut-Lese-/Schreibzugriffe auf gültigen Objekten.
    unsafe {
        let rate = pcm.GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND).ctx("Abtastrate")?;
        let ch = pcm.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS).ctx("Kanäle")?;
        let out = new_type()?;
        out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio).ctx("Audio-Typ")?;
        out.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC).ctx("AAC")?;
        out.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16).ctx("Bits")?;
        out.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate).ctx("Rate")?;
        out.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, ch).ctx("Kanäle")?;
        // 128 kbit/s (Mono) bzw. 192 kbit/s (Stereo) — erlaubte AAC-Stufen, in Bytes pro Sekunde.
        out.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, if ch >= 2 { 24_000 } else { 16_000 }).ctx("Audio-Bitrate")?;
        out.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 1).ctx("Blockgröße")?;
        out.SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0).ctx("AAC-Nutzlast")?;
        out.SetUINT32(&MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29).ctx("AAC-Profil")?;
        let idx = sw.AddStream(&out).ctx("Tonspur")?;
        sw.SetInputMediaType(idx, pcm, None::<&IMFAttributes>).ctx("Toneingang")?;
        Ok(idx)
    }
}

/// Gibt es mindestens einen HEVC-Encoder (Hardware oder Software)?
pub fn hevc_encoder_available() -> bool {
    use std::sync::OnceLock;
    static R: OnceLock<bool> = OnceLock::new();
    *R.get_or_init(|| {
        let Ok(_com) = enter() else { return false };
        let out = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_HEVC };
        let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0u32;
        let flags = MFT_ENUM_FLAG(MFT_ENUM_FLAG_SYNCMFT.0 | MFT_ENUM_FLAG_ASYNCMFT.0 | MFT_ENUM_FLAG_HARDWARE.0 | MFT_ENUM_FLAG_SORTANDFILTER.0);
        // SAFETY: MFTEnumEx legt ein CoTaskMem-Feld aus `count` Aktivierern an. Jeder Eintrag wird
        // einmal herausgelesen und damit freigegeben, danach das Feld mit CoTaskMemFree.
        unsafe {
            if MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, None, Some(&out), &mut list, &mut count).is_err() {
                return false;
            }
            if !list.is_null() {
                for i in 0..count as usize {
                    drop(std::ptr::read(list.add(i)));
                }
                windows::Win32::System::Com::CoTaskMemFree(Some(list as *const _));
            }
        }
        count > 0
    })
}
