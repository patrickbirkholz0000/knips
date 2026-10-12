//! Mitlaufende Zensurbalken (`VideoRedactor.track`). Auf dem Mac verfolgt Vision
//! (`VNTrackObjectRequest`) den Bildinhalt; hier übernimmt das ein eigener Verfolger
//! (Vorlagenvergleich auf Graustufen), mit derselben Schnittstelle und derselben Nachbearbeitung.

use std::sync::atomic::AtomicBool;

use anyhow::Result;

use crate::geometry::Rect;
use crate::model::TrackPoint;
use crate::RgbaImage;

pub struct TrackParams<'a> {
    /// Balken in Videopixeln zum Zeitpunkt `t0`.
    pub rect: Rect,
    pub t0: f64,
    pub start: f64,
    pub end: f64,
    /// Bildrate des Videos; Schrittweite = 1 / clamp(fps, 15, 60).
    pub fps: f64,
    pub video_width: f64,
    pub video_height: f64,
    pub cancel: &'a AtomicBool,
}

/// Verfolgt den Inhalt unter `rect` vorwärts bis `end` und rückwärts bis `start`. Größe bleibt fest,
/// nur die Position folgt; verloren → an der letzten sicheren Stelle stehen bleiben. Danach in
/// Bewegungsrichtung um das Sechsfache der Geschwindigkeit pro Bild vergrößern (wie auf dem Mac).
/// `frame_at(t)` darf verkleinerte Bilder liefern (≤ 1280 px); Koordinaten werden umgerechnet.
pub fn track(
    params: &TrackParams,
    frame_at: &mut dyn FnMut(f64) -> Option<RgbaImage>,
    progress: &mut dyn FnMut(f64),
) -> Result<Vec<TrackPoint>> {
    let _ = (params, frame_at, progress);
    todo!("knips-core: tracker::track")
}
