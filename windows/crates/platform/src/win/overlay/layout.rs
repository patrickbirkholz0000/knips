//! Reine Geometrie des Auswahl-Overlays (keine Windows-Typen, auf dem Mac testbar).
//!
//! Koordinaten: Ursprung oben links, y nach unten. „px“ = physische Pixel des Monitors,
//! „pt“ = DIPs (px / Skalierung) — die Mac-Werte (Abstände, Größen) sind Punkte.
//! Die Mac-Vorlage rechnet mit Ursprung unten links; alle Umrechnungen stehen kommentiert unten.

#![allow(dead_code)]

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct RectF {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl RectF {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }
    pub fn right(&self) -> f64 {
        self.x + self.w
    }
    pub fn bottom(&self) -> f64 {
        self.y + self.h
    }
    pub fn inset(&self, dx: f64, dy: f64) -> RectF {
        RectF::new(self.x + dx, self.y + dy, self.w - 2.0 * dx, self.h - 2.0 * dy)
    }
    pub fn scaled(&self, k: f64) -> RectF {
        RectF::new(self.x * k, self.y * k, self.w * k, self.h * k)
    }
    /// Schnittmenge; `None`, wenn leer.
    pub fn intersection(&self, o: &RectF) -> Option<RectF> {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let r = self.right().min(o.right());
        let b = self.bottom().min(o.bottom());
        if r > x && b > y {
            Some(RectF::new(x, y, r - x, b - y))
        } else {
            None
        }
    }
}

/// Punkt auf den Monitor [0, w] × [0, h] klemmen (`clamp` der Mac-Ansicht).
pub fn clamp_pt(p: (f64, f64), w: f64, h: f64) -> (f64, f64) {
    (p.0.max(0.0).min(w), p.1.max(0.0).min(h))
}

/// Ziehbereich von `start` nach `p`. Mit Umschalt quadratisch (Seite = längere Kante, in die
/// Richtung der Maus), danach auf den Monitor begrenzt. Beide Punkte bereits geklemmt.
pub fn drag_rect(start: (f64, f64), p: (f64, f64), square: bool, w: f64, h: f64) -> RectF {
    let r = RectF::new(start.0.min(p.0), start.1.min(p.1), (p.0 - start.0).abs(), (p.1 - start.1).abs());
    if !square {
        return r;
    }
    let side = r.w.max(r.h);
    let sq = RectF::new(
        if p.0 < start.0 { start.0 - side } else { start.0 },
        if p.1 < start.1 { start.1 - side } else { start.1 },
        side,
        side,
    );
    sq.intersection(&RectF::new(0.0, 0.0, w, h)).unwrap_or(RectF::new(start.0, start.1, 0.0, 0.0))
}

/// Mindestgröße einer Auswahl in px: 4 pt wie auf dem Mac.
pub fn min_selection_px(scale: f64) -> f64 {
    (4.0 * scale).round().max(1.0)
}

pub fn big_enough(r: &RectF, min: f64) -> bool {
    r.w >= min && r.h >= min
}

/// Auf ganze Pixel (nach außen gerundet, wie `CGRect.integral`): (x, y, Breite, Höhe).
pub fn integral(r: &RectF) -> (i32, i32, i32, i32) {
    let x = r.x.floor();
    let y = r.y.floor();
    let rr = r.right().ceil();
    let b = r.bottom().ceil();
    (x as i32, y as i32, (rr - x) as i32, (b - y) as i32)
}

/// Vorderstes Fenster unter dem globalen Punkt. `rects` = (x, y, Breite, Höhe), vorne zuerst.
pub fn hovered_window(rects: &[(i32, i32, i32, i32)], gx: i32, gy: i32) -> Option<usize> {
    rects.iter().position(|&(x, y, w, h)| gx >= x && gx < x + w && gy >= y && gy < y + h)
}

/// Loch für ein Fenster: globales Fensterrechteck → Monitor-lokal, auf den Monitor begrenzt.
pub fn window_hole(win: (i32, i32, i32, i32), mon_origin: (i32, i32), w: f64, h: f64) -> Option<RectF> {
    let r = RectF::new((win.0 - mon_origin.0) as f64, (win.1 - mon_origin.1) as f64, win.2 as f64, win.3 as f64);
    r.intersection(&RectF::new(0.0, 0.0, w, h))
}

/// Aufteilung der Abdunklung um ein Loch: bis zu vier Streifen (oben, unten, links, rechts) —
/// entspricht der Even-Odd-Fläche. Ohne Loch: der ganze Monitor.
pub fn dim_strips(w: f64, h: f64, hole: Option<RectF>) -> Vec<RectF> {
    let Some(hole) = hole else {
        return vec![RectF::new(0.0, 0.0, w, h)];
    };
    let mut v = Vec::with_capacity(4);
    let top = hole.y.max(0.0);
    let bottom = hole.bottom().min(h);
    let left = hole.x.max(0.0);
    let right = hole.right().min(w);
    if top > 0.0 {
        v.push(RectF::new(0.0, 0.0, w, top));
    }
    if bottom < h {
        v.push(RectF::new(0.0, bottom, w, h - bottom));
    }
    if left > 0.0 {
        v.push(RectF::new(0.0, top, left, bottom - top));
    }
    if right < w {
        v.push(RectF::new(right, top, w - right, bottom - top));
    }
    v
}

/// Position des Größenschilds (pt, oben links). Mac (unten links): `y = sel.minY - h - 8`
/// → unter der Auswahl; passt es nicht (`y < 4`), `y = sel.minY + 8` → innerhalb am unteren Rand.
/// Hier (oben links): unter der Auswahl `sel.bottom + 8`, sonst `sel.bottom - 8 - h`.
pub fn size_label_origin(sel: RectF, lw: f64, lh: f64, bw: f64, bh: f64) -> (f64, f64) {
    let mut x = sel.right() - lw;
    let mut y = sel.bottom() + 8.0;
    if y + lh > bh - 4.0 {
        y = sel.bottom() - 8.0 - lh;
    }
    x = x.min(bw - lw - 4.0).max(4.0);
    (x, y)
}

pub const LOUPE_SIZE: f64 = 132.0;
pub const LOUPE_PIXELS: i32 = 13;

/// Lupenausschnitt: Region (13×13) um das Pixel (px, py), auf das Bild begrenzt.
/// Rückgabe: (Region x, Region y, Ausschnitt x, y, Breite, Höhe) in Bildpixeln; `None`, wenn leer.
pub type LoupeSource = ((i32, i32), (i32, i32, i32, i32));

pub fn loupe_source(px: i32, py: i32, img_w: i32, img_h: i32) -> Option<LoupeSource> {
    let half = LOUPE_PIXELS / 2;
    let (rx, ry) = (px - half, py - half);
    let x0 = rx.max(0);
    let y0 = ry.max(0);
    let x1 = (rx + LOUPE_PIXELS).min(img_w);
    let y1 = (ry + LOUPE_PIXELS).min(img_h);
    if x1 > x0 && y1 > y0 {
        Some(((rx, ry), (x0, y0, x1 - x0, y1 - y0)))
    } else {
        None
    }
}

/// Position der Lupe (pt, oben links). Mac (unten links): `x = lx + 26`, `y = ly - size - 26`;
/// rechts raus (`x + size > W - 4`) → links vom Zeiger; unten raus (`y < 24`) → über dem Zeiger.
/// Hier (oben links): unter dem Zeiger `ly + 26`; „y < 24“ unten links heißt
/// `ly + 26 + size > H - 24`; dann über dem Zeiger: `ly - 26 - size`.
pub fn loupe_origin(local: (f64, f64), bw: f64, bh: f64) -> (f64, f64) {
    let size = LOUPE_SIZE;
    let mut x = local.0 + 26.0;
    let mut y = local.1 + 26.0;
    if x + size > bw - 4.0 {
        x = local.0 - size - 26.0;
    }
    if y + size > bh - 24.0 {
        y = local.1 - 26.0 - size;
    }
    (x, y)
}

/// Koordinatenschild unter der Lupe (Mac: 84 × 16, 20 unter der Unterkante des Rahmens
/// gerechnet ab Lupen-Unterkante, also 4 Abstand).
pub fn loupe_text_rect(origin: (f64, f64)) -> RectF {
    RectF::new(origin.0 + LOUPE_SIZE / 2.0 - 42.0, origin.1 + LOUPE_SIZE + 4.0, 84.0, 16.0)
}

/// Hinweisschild oben mittig. Mac: unter der Menüleiste + 18; hier: 18 unter dem oberen Rand
/// des Arbeitsbereichs (`work_top` in pt, relativ zum Monitor).
pub fn hint_origin(bw: f64, pw: f64, work_top: f64) -> (f64, f64) {
    (((bw - pw) / 2.0), work_top + 18.0)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Screenshot,
    Recording,
    Text,
    Scroll,
}

pub fn hint_text(kind: Kind, window_mode: bool) -> String {
    let prefix = match kind {
        Kind::Recording => "Aufnahme  ·  ",
        Kind::Text => "Text erfassen  ·  ",
        Kind::Scroll => "Scroll-Screenshot: sichtbaren Bereich wählen  ·  ",
        Kind::Screenshot => "",
    };
    let rest = if window_mode {
        "Fenster anklicken  ·  Leertaste: Bereich  ·  Eingabe: ganzer Bildschirm  ·  Esc: Abbrechen"
    } else {
        "Bereich ziehen  ·  Leertaste: Fenster  ·  Eingabe: ganzer Bildschirm  ·  Esc: Abbrechen"
    };
    format!("{prefix}{rest}")
}

/// Fadenkreuz-Linie: ein Streifen aus ganzen Gerätepixeln um das Zeigerpixel.
/// Rückgabe (Start, Dicke) in px; Dicke = 1 pt auf ganze Pixel gerundet.
pub fn cross_line(cursor_px: i32, scale: f64) -> (i32, i32) {
    let t = scale.round().max(1.0) as i32;
    (cursor_px - (t - 1) / 2, t)
}

/// Rahmenfenster: Außenrechteck = aufgenommener Bereich + 3 pt Rand (px, ganzzahlig).
/// Rückgabe: (Fenster x, y, Breite, Höhe, Randbreite px).
pub fn frame_window_rect(rect: (i32, i32, i32, i32), scale: f64) -> (i32, i32, i32, i32, i32) {
    let o = (3.0 * scale).round().max(1.0) as i32;
    (rect.0 - o, rect.1 - o, rect.2 + 2 * o, rect.3 + 2 * o, o)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drag_normal_and_reverse() {
        let r = drag_rect((100.0, 100.0), (40.0, 160.0), false, 1000.0, 800.0);
        assert_eq!(r, RectF::new(40.0, 100.0, 60.0, 60.0));
    }

    #[test]
    fn drag_square_directions() {
        // nach rechts unten: längere Kante gewinnt
        let r = drag_rect((100.0, 100.0), (150.0, 130.0), true, 1000.0, 800.0);
        assert_eq!(r, RectF::new(100.0, 100.0, 50.0, 50.0));
        // nach links oben
        let r = drag_rect((100.0, 100.0), (60.0, 20.0), true, 1000.0, 800.0);
        assert_eq!(r, RectF::new(20.0, 20.0, 80.0, 80.0));
        // am Rand begrenzt
        let r = drag_rect((900.0, 700.0), (1000.0, 800.0), true, 1000.0, 800.0);
        assert_eq!(r, RectF::new(900.0, 700.0, 100.0, 100.0));
        let r = drag_rect((50.0, 700.0), (0.0, 800.0), true, 1000.0, 800.0);
        // wie auf dem Mac: das Quadrat wird nur abgeschnitten, nicht verschoben
        assert_eq!(r, RectF::new(0.0, 700.0, 50.0, 100.0));
    }

    #[test]
    fn clamp_and_min() {
        assert_eq!(clamp_pt((-5.0, 900.0), 100.0, 800.0), (0.0, 800.0));
        assert_eq!(min_selection_px(1.0), 4.0);
        assert_eq!(min_selection_px(2.0), 8.0);
        assert!(big_enough(&RectF::new(0.0, 0.0, 4.0, 4.0), 4.0));
        assert!(!big_enough(&RectF::new(0.0, 0.0, 4.0, 3.0), 4.0));
        assert_eq!(integral(&RectF::new(1.5, 2.2, 3.0, 3.0)), (1, 2, 4, 4));
    }

    #[test]
    fn window_hit_front_to_back() {
        let rects = [(100, 100, 200, 200), (0, 0, 1000, 1000)];
        assert_eq!(hovered_window(&rects, 150, 150), Some(0));
        assert_eq!(hovered_window(&rects, 300, 300), Some(1));
        assert_eq!(hovered_window(&rects, 1000, 1000), None);
    }

    #[test]
    fn hole_for_window_clipped() {
        // Fenster ragt links über den Monitor (Monitor beginnt bei x=1920)
        let h = window_hole((1800, 100, 400, 300), (1920, 0), 1920.0, 1080.0).unwrap();
        assert_eq!(h, RectF::new(0.0, 100.0, 280.0, 300.0));
        // Fenster ganz auf anderem Monitor
        assert!(window_hole((0, 0, 500, 500), (1920, 0), 1920.0, 1080.0).is_none());
    }

    #[test]
    fn strips_cover_everything_but_hole() {
        let (w, h) = (1000.0, 800.0);
        let hole = RectF::new(100.0, 50.0, 300.0, 200.0);
        let strips = dim_strips(w, h, Some(hole));
        let area: f64 = strips.iter().map(|s| s.w * s.h).sum();
        assert_eq!(area, w * h - hole.w * hole.h);
        assert_eq!(dim_strips(w, h, None), vec![RectF::new(0.0, 0.0, w, h)]);
        // Loch am Rand → weniger Streifen
        let edge = dim_strips(w, h, Some(RectF::new(0.0, 0.0, w, h)));
        assert!(edge.is_empty());
        let left = dim_strips(w, h, Some(RectF::new(0.0, 0.0, 500.0, 800.0)));
        assert_eq!(left, vec![RectF::new(500.0, 0.0, 500.0, 800.0)]);
    }

    #[test]
    fn size_label_below_right_and_flips() {
        let sel = RectF::new(200.0, 100.0, 300.0, 200.0);
        let (x, y) = size_label_origin(sel, 80.0, 24.0, 1000.0, 800.0);
        assert_eq!((x, y), (420.0, 308.0)); // rechtsbündig, 8 unter der Auswahl
        // unten kein Platz → innen am unteren Rand
        let sel = RectF::new(200.0, 500.0, 300.0, 290.0);
        let (_, y) = size_label_origin(sel, 80.0, 24.0, 1000.0, 800.0);
        assert_eq!(y, 790.0 - 8.0 - 24.0);
        // links raus → x = 4
        let sel = RectF::new(0.0, 100.0, 30.0, 30.0);
        let (x, _) = size_label_origin(sel, 80.0, 24.0, 1000.0, 800.0);
        assert_eq!(x, 4.0);
        // rechts raus
        let sel = RectF::new(900.0, 100.0, 100.0, 30.0);
        let (x, _) = size_label_origin(sel, 80.0, 24.0, 1000.0, 800.0);
        assert_eq!(x, 916.0); // 4 Rand rechts
    }

    #[test]
    fn mac_equivalence_size_label() {
        // Mac (unten links, H=800): sel = (200, 500, 300, 200) → y_bl = 500 - 24 - 8 = 468 → oben-links-Oberkante:
        // H - (y_bl + h) = 800 - 492 = 308. Gleiches Ergebnis wie size_label_origin.
        let sel_tl = RectF::new(200.0, 100.0, 300.0, 200.0); // y_tl = 800 - 500 - 200 = 100
        let (_, y) = size_label_origin(sel_tl, 80.0, 24.0, 1000.0, 800.0);
        assert_eq!(y, 308.0);
    }

    #[test]
    fn loupe_placement() {
        let (x, y) = loupe_origin((500.0, 300.0), 1920.0, 1080.0);
        assert_eq!((x, y), (526.0, 326.0));
        // rechts raus → links vom Zeiger
        let (x, _) = loupe_origin((1900.0, 300.0), 1920.0, 1080.0);
        assert_eq!(x, 1900.0 - 132.0 - 26.0);
        // unten raus → über dem Zeiger
        let (_, y) = loupe_origin((500.0, 1000.0), 1920.0, 1080.0);
        assert_eq!(y, 1000.0 - 26.0 - 132.0);
        // Grenzfall: y + size == H - 24 bleibt unten
        let (_, y) = loupe_origin((500.0, 1080.0 - 24.0 - 132.0 - 26.0), 1920.0, 1080.0);
        assert_eq!(y, 1080.0 - 24.0 - 132.0);
        let t = loupe_text_rect((526.0, 326.0));
        assert_eq!(t, RectF::new(526.0 + 66.0 - 42.0, 326.0 + 136.0, 84.0, 16.0));
    }

    #[test]
    fn loupe_source_clipping() {
        let ((rx, ry), (x, y, w, h)) = loupe_source(100, 100, 1920, 1080).unwrap();
        assert_eq!((rx, ry, x, y, w, h), (94, 94, 94, 94, 13, 13));
        let (_, (x, y, w, h)) = loupe_source(2, 1078, 1920, 1080).unwrap();
        assert_eq!((x, y, w, h), (0, 1072, 9, 8));
        assert!(loupe_source(-20, 10, 1920, 1080).is_none());
    }

    #[test]
    fn hint_and_frame() {
        assert!(hint_text(Kind::Recording, false).starts_with("Aufnahme  ·  Bereich ziehen"));
        assert!(hint_text(Kind::Screenshot, true).starts_with("Fenster anklicken"));
        assert!(hint_text(Kind::Scroll, false).starts_with("Scroll-Screenshot: sichtbaren Bereich wählen  ·  Bereich"));
        assert!(hint_text(Kind::Text, true).starts_with("Text erfassen  ·  Fenster"));
        assert_eq!(hint_origin(1000.0, 400.0, 0.0), (300.0, 18.0));
        assert_eq!(cross_line(100, 1.0), (100, 1));
        assert_eq!(cross_line(100, 2.0), (100, 2));
        assert_eq!(cross_line(100, 3.0), (99, 3));
        assert_eq!(frame_window_rect((100, 100, 800, 600), 2.0), (94, 94, 812, 612, 6));
    }
}
