//! Auslöser-Geräusch: kurzes Kamera-Klicken, einmal im Speicher synthetisiert.

use std::sync::OnceLock;

use windows::core::PCWSTR;
use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};

const RATE: u32 = 44_100;

/// Gefiltertes Rauschen mit schnellem Abklingen: zwei Klicks (Spiegel hoch, Verschluss zu).
fn synth() -> Vec<u8> {
    let n = (RATE as f64 * 0.16) as usize;
    let mut seed: u32 = 0x1234_5678;
    let mut noise = move || {
        seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        ((seed >> 8) as f32 / (1u32 << 24) as f32) * 2.0 - 1.0
    };
    let mut samples = vec![0f32; n];
    // (Start in s, Abklingzeit in s, Pegel, Tiefpass-Faktor, Hochpass-Faktor)
    let bursts = [(0.0f64, 0.012f64, 0.9f32, 0.55f32, 0.92f32), (0.075, 0.020, 0.7, 0.35, 0.90)];
    for (start, tau, level, lp, hp) in bursts {
        let s0 = (start * RATE as f64) as usize;
        let (mut lp_state, mut hp_prev_in, mut hp_state) = (0f32, 0f32, 0f32);
        for i in s0..n {
            let t = (i - s0) as f64 / RATE as f64;
            let env = (-t / tau).exp() as f32;
            if env < 0.001 {
                break;
            }
            let x = noise();
            lp_state += lp * (x - lp_state);
            // einfacher Hochpass: entfernt das Dröhnen, übrig bleibt das „Klick“-Band
            hp_state = hp * (hp_state + lp_state - hp_prev_in);
            hp_prev_in = lp_state;
            // kurzer Tonanteil für den mechanischen Anschlag
            let tone = (2.0 * std::f64::consts::PI * 1800.0 * t).sin() as f32 * 0.25;
            samples[i] += (hp_state * 2.2 + tone * env) * env * level;
        }
    }
    let data: Vec<u8> = samples
        .iter()
        .flat_map(|&s| ((s.clamp(-1.0, 1.0) * 0.8 * i16::MAX as f32) as i16).to_le_bytes())
        .collect();
    let mut wav = Vec::with_capacity(44 + data.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&RATE.to_le_bytes());
    wav.extend_from_slice(&(RATE * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
    wav.extend_from_slice(&data);
    wav
}

static WAV: OnceLock<Vec<u8>> = OnceLock::new();

/// Auslöser-Geräusch (asynchron).
pub fn play_shutter() {
    let wav = WAV.get_or_init(synth);
    // SAFETY: Die Daten liegen in einer `static` und bleiben für die asynchrone Wiedergabe gültig.
    unsafe {
        let _ = PlaySoundW(PCWSTR(wav.as_ptr() as *const u16), None, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    }
}
