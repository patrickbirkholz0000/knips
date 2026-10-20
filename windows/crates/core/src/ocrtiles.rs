//! Texterkennung auf hohen oder breiten Bildern in Kacheln. Bildschirmfotos werden wie auf dem Mac
//! als Ganzes auf ≤ `OCR_MAX_PIXEL` verkleinert (4K: Faktor 0,53). Ein Scroll-Screenshot mit
//! 1280×10 000 px würde dabei auf ein Fünftel schrumpfen — die Schrift wäre unlesbar und die
//! Auto-Zensur fände nichts. Solche Bilder werden deshalb in überlappende Kacheln zerlegt, die
//! höchstens auf die Hälfte verkleinert werden; die Treffer kommen danach wieder zusammen.
//!
//! Ablauf: `plan` → je Kachel ausschneiden, verkleinern, erkennen, auf Bildpixel zurückrechnen →
//! `merge`.

use crate::geometry::{IRect, Rect};
use crate::model::{TextLine, TextWord};
use crate::textlayout::sort_reading_order;

/// Stärkste Verkleinerung einer Kachel (darunter wird Bildschirmschrift unlesbar).
pub const MIN_SCALE: f64 = 0.5;

/// Überlappung benachbarter Kacheln in Erkennungspixeln: mehr als eine Zeile (vertikal) und mehr
/// als ein langes Wort wie ein API-Schlüssel (horizontal).
pub const OVERLAP: f64 = 384.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Tile {
    /// Ausschnitt in Bildpixeln.
    pub rect: IRect,
    /// Verkleinerung für die Erkennung (1 = unverändert).
    pub scale: f64,
    /// Zuständigkeitsbereich: Wörter, deren Mitte hier liegt, gehören zu dieser Kachel.
    /// Grenze zwischen zwei Kacheln = Mitte ihrer Überlappung.
    pub core: Rect,
}

impl Tile {
    pub fn covers(&self, width: u32, height: u32) -> bool {
        self.rect == IRect::new(0, 0, width as i32, height as i32)
    }
}

/// Startpositionen gleichmäßig verteilter Abschnitte der Länge `span` über `dim`, die sich um
/// mindestens `overlap` überlappen.
fn starts(dim: u32, span: u32, overlap: u32) -> Vec<u32> {
    if dim <= span {
        return vec![0];
    }
    let overlap = overlap.min(span / 2);
    let n = (dim - overlap).div_ceil(span - overlap).max(2);
    (0..n).map(|i| ((i as u64 * (dim - span) as u64 + (n as u64 - 1) / 2) / (n as u64 - 1)) as u32).collect()
}

/// Grenzen der Zuständigkeit je Abschnitt: Mitte der Überlappung mit dem Nachbarn.
fn cores(starts: &[u32], span: u32, dim: u32) -> Vec<(f64, f64)> {
    let end = |i: usize| (starts[i] + span).min(dim);
    (0..starts.len())
        .map(|i| {
            let lo = if i == 0 { 0.0 } else { (starts[i] as f64 + end(i - 1) as f64) / 2.0 };
            let hi = if i + 1 == starts.len() { dim as f64 } else { (starts[i + 1] as f64 + end(i) as f64) / 2.0 };
            (lo, hi)
        })
        .collect()
}

/// Kacheln für ein Bild von `width`×`height` Pixeln, je Kachel höchstens `limit` Erkennungspixel
/// lang. Passt das Bild mit höchstens Faktor `MIN_SCALE` als Ganzes, bleibt es eine Kachel.
pub fn plan(width: u32, height: u32, limit: u32) -> Vec<Tile> {
    if width == 0 || height == 0 || limit == 0 {
        return vec![];
    }
    let full = IRect::new(0, 0, width as i32, height as i32);
    let longest = width.max(height) as f64;
    let whole = (limit as f64 / longest).min(1.0);
    if whole >= MIN_SCALE {
        return vec![Tile { rect: full, scale: whole, core: full.to_rect() }];
    }
    // Die kürzere Seite möglichst in eine Kachel, aber nie stärker als `MIN_SCALE` verkleinern.
    let scale = (limit as f64 / width.min(height) as f64).clamp(MIN_SCALE, 1.0);
    let span = ((limit as f64 / scale).floor() as u32).max(1);
    let overlap = (OVERLAP / scale).ceil() as u32;
    let (xs, ys) = (starts(width, span, overlap), starts(height, span, overlap));
    let (cx, cy) = (cores(&xs, span, width), cores(&ys, span, height));
    let mut tiles = vec![];
    for (j, &y) in ys.iter().enumerate() {
        for (i, &x) in xs.iter().enumerate() {
            let rect = IRect::new(x as i32, y as i32, span.min(width - x) as i32, span.min(height - y) as i32);
            let core = Rect::new(cx[i].0, cy[j].0, cx[i].1 - cx[i].0, cy[j].1 - cy[j].0);
            tiles.push(Tile { rect, scale, core });
        }
    }
    tiles
}

fn owns(core: &Rect, r: &Rect) -> bool {
    let (x, y) = (r.mid_x(), r.mid_y());
    x >= core.min_x() && x < core.max_x() && y >= core.min_y() && y < core.max_y()
}

/// Ergebnisse der Kacheln (Zeilen bereits in Bildpixeln) zusammenführen: Jedes Wort zählt nur in
/// der Kachel, in deren Zuständigkeit seine Mitte liegt (Doppelte aus der Überlappung fallen weg,
/// am Rand abgeschnittene Wörter kommen aus der Nachbarkachel vollständig). Zeilen, die über eine
/// senkrechte Kachelgrenze laufen, werden wieder zu einer Zeile. Ergebnis in Lesereihenfolge.
pub fn merge(results: Vec<(Tile, Vec<TextLine>)>) -> Vec<TextLine> {
    if results.len() == 1 {
        // Eine Kachel: nichts zusammenzuführen.
        let (_, mut lines) = results.into_iter().next().expect("eine Kachel");
        sort_reading_order(&mut lines);
        return lines;
    }
    // (Zeile, Zuständigkeit der Kachel, aus der sie stammt)
    let mut parts: Vec<Option<(TextLine, Rect)>> = vec![];
    for (tile, lines) in results {
        for line in lines {
            if line.words.is_empty() {
                if owns(&tile.core, &line.rect) {
                    parts.push(Some((line, tile.core)));
                }
                continue;
            }
            let words: Vec<TextWord> = line.words.into_iter().filter(|w| owns(&tile.core, &w.rect)).collect();
            if !words.is_empty() {
                parts.push(Some((TextLine::from_words(words), tile.core)));
            }
        }
    }
    // Über senkrechte Kachelgrenzen laufende Zeilen verbinden, Grenze für Grenze von links: Teile aus
    // benachbarten Kacheln auf gleicher Höhe mit einem Abstand wie zwischen zwei Wörtern.
    let mut bounds: Vec<f64> = parts.iter().flatten().map(|(_, c)| c.min_x()).filter(|x| *x > 0.0).collect();
    bounds.sort_by(f64::total_cmp);
    bounds.dedup_by(|a, b| (*a - *b).abs() < 0.5);
    for bx in bounds {
        let at = |i: usize, left: bool| {
            parts[i].as_ref().is_some_and(|(_, c)| ((if left { c.max_x() } else { c.min_x() }) - bx).abs() < 0.5)
        };
        let lefts: Vec<usize> = (0..parts.len()).filter(|&i| at(i, true)).collect();
        let rights: Vec<usize> = (0..parts.len()).filter(|&i| at(i, false)).collect();
        let mut taken = vec![false; parts.len()];
        for b in rights {
            let Some((lb, _)) = parts[b].as_ref() else { continue };
            let mut best: Option<(usize, f64)> = None;
            for &a in lefts.iter().filter(|&&a| !taken[a]) {
                let Some((la, _)) = parts[a].as_ref() else { continue };
                let h = la.rect.height.min(lb.rect.height).max(1.0);
                let overlap_y = la.rect.max_y().min(lb.rect.max_y()) - la.rect.min_y().max(lb.rect.min_y());
                let gap = lb.rect.min_x() - la.rect.max_x();
                if overlap_y >= 0.5 * h && gap > -h && gap < 2.0 * h && best.is_none_or(|(_, o)| overlap_y > o) {
                    best = Some((a, overlap_y));
                }
            }
            let Some((a, _)) = best else { continue };
            taken[a] = true;
            let (lb, cb) = parts[b].take().expect("rechte Zeile");
            let (la, ca) = parts[a].as_mut().expect("linke Zeile");
            let mut words = std::mem::take(&mut la.words);
            words.extend(lb.words);
            words.sort_by(|x, y| x.rect.min_x().total_cmp(&y.rect.min_x()));
            *la = TextLine::from_words(words);
            // Die verbundene Zeile reicht jetzt bis an die rechte Grenze der rechten Kachel.
            *ca = Rect::new(ca.x, ca.y, cb.max_x() - ca.x, ca.height);
        }
    }
    let mut lines: Vec<TextLine> = parts.into_iter().flatten().map(|(l, _)| l).collect();
    sort_reading_order(&mut lines);
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMIT: u32 = 2048;

    #[test]
    fn screens_stay_one_tile() {
        // 4K wie auf dem Mac: als Ganzes auf 0,53 verkleinert.
        let t = plan(3840, 2160, LIMIT);
        assert_eq!(t.len(), 1);
        assert!(t[0].covers(3840, 2160));
        assert!((t[0].scale - 2048.0 / 3840.0).abs() < 1e-9);
        // Klein: unverändert.
        let t = plan(1400, 880, LIMIT);
        assert_eq!((t.len(), t[0].scale), (1, 1.0));
        assert!(plan(0, 10, LIMIT).is_empty());
    }

    #[test]
    fn tall_image_gets_overlapping_strips_at_full_size() {
        let (w, h) = (1280, 10_000);
        let tiles = plan(w, h, LIMIT);
        assert!(tiles.len() >= 5, "{}", tiles.len());
        for t in &tiles {
            assert_eq!(t.scale, 1.0, "Breite passt → unverkleinert");
            assert_eq!((t.rect.x, t.rect.width), (0, 1280));
            assert!(t.rect.height as u32 <= LIMIT);
        }
        // Lückenlos, Überlappung > OVERLAP, Zuständigkeiten aneinander und im Bild.
        assert_eq!(tiles[0].rect.y, 0);
        assert_eq!(tiles.last().unwrap().rect.bottom(), h as i32);
        for p in tiles.windows(2) {
            assert!(p[0].rect.bottom() - p[1].rect.y >= OVERLAP as i32, "Überlappung {}", p[0].rect.bottom() - p[1].rect.y);
            assert_eq!(p[0].core.max_y(), p[1].core.min_y());
            // Zuständigkeitsgrenze mindestens OVERLAP/2 vom Kachelrand entfernt.
            assert!(p[0].rect.bottom() as f64 - p[0].core.max_y() >= OVERLAP / 2.0 - 1.0);
            assert!(p[1].core.min_y() - p[1].rect.y as f64 >= OVERLAP / 2.0 - 1.0);
        }
        assert_eq!((tiles[0].core.min_y(), tiles.last().unwrap().core.max_y()), (0.0, h as f64));
    }

    #[test]
    fn huge_image_never_below_half_scale() {
        let tiles = plan(9000, 30_000, LIMIT);
        assert!(tiles.iter().all(|t| t.scale == MIN_SCALE));
        assert!(tiles.iter().all(|t| (t.rect.width.max(t.rect.height) as f64 * t.scale) <= LIMIT as f64 + 0.5));
        let cols = tiles.iter().filter(|t| t.rect.y == 0).count();
        assert!(cols >= 3, "{cols} Spalten");
        // Zuständigkeiten decken das Bild genau einmal ab (Stichproben).
        for (x, y) in [(0.0, 0.0), (4500.0, 15_000.0), (8999.0, 29_999.0), (4095.5, 3000.0)] {
            let n = tiles.iter().filter(|t| owns(&t.core, &Rect::new(x, y, 0.0, 0.0))).count();
            assert_eq!(n, 1, "Punkt {x},{y}");
        }
    }

    #[test]
    fn wide_image_gets_columns() {
        let tiles = plan(10_000, 900, LIMIT);
        assert!(tiles.len() >= 5);
        assert!(tiles.iter().all(|t| t.rect.y == 0 && t.rect.height == 900 && t.scale == 1.0));
    }

    /// Erfundene Seite: Zeilen mit Wörtern (je 10 px pro Zeichen, 24 px hoch); jedes 7. Wort ist
    /// ein 33 Zeichen langer „Schlüssel“ (330 px, wie ein API-Schlüssel in großer Schrift).
    fn page(width: u32, height: u32) -> Vec<TextLine> {
        let mut lines = vec![];
        let mut y = 10.0;
        let mut n = 0;
        while y + 24.0 < height as f64 {
            let mut x = 20.0;
            let mut words = vec![];
            while x < width as f64 - 400.0 {
                let text = if n % 7 == 3 { format!("sk_{n:06}_{}", "x".repeat(23)) } else { format!("w{n}") };
                let w = text.len() as f64 * 10.0;
                words.push(TextWord { text, rect: Rect::new(x, y, w, 24.0) });
                x += w + 12.0;
                n += 1;
            }
            lines.push(TextLine::from_words(words));
            y += 37.0;
        }
        lines
    }

    /// Simulierte Erkennung je Kachel: sieht nur Wörter, die zur Hälfte in der Kachel liegen
    /// (abgeschnittene Wörter werden gekürzt erkannt), und trennt Zeilen an der Kachelgrenze.
    fn recognize(tile: &Tile, page: &[TextLine]) -> Vec<TextLine> {
        let r = tile.rect.to_rect();
        page.iter()
            .filter_map(|l| {
                let words: Vec<TextWord> = l
                    .words
                    .iter()
                    .filter_map(|w| {
                        let i = w.rect.intersection(&r);
                        if i.is_null() || i.area() < w.rect.area() * 0.3 {
                            return None;
                        }
                        let keep = ((w.text.len() as f64) * i.width / w.rect.width).ceil() as usize;
                        let text = if i == w.rect { w.text.clone() } else { format!("{}~", &w.text[..keep.min(w.text.len())]) };
                        Some(TextWord { text, rect: i })
                    })
                    .collect();
                (!words.is_empty()).then(|| TextLine::from_words(words))
            })
            .collect()
    }

    fn all_words(lines: &[TextLine]) -> Vec<String> {
        lines.iter().flat_map(|l| l.words.iter().map(|w| w.text.clone())).collect()
    }

    fn check_roundtrip(width: u32, height: u32) {
        let page = page(width, height);
        let tiles = plan(width, height, LIMIT);
        assert!(tiles.len() > 1);
        let results = tiles.iter().map(|t| (t.clone(), recognize(t, &page))).collect();
        let merged = merge(results);
        // Jedes Wort genau einmal und vollständig, jede Zeile wieder eine Zeile.
        let mut want = all_words(&page);
        let mut got = all_words(&merged);
        assert!(got.iter().all(|w| !w.ends_with('~')), "abgeschnittenes Wort: {:?}", got.iter().find(|w| w.ends_with('~')));
        want.sort();
        got.sort();
        assert_eq!(got, want);
        assert_eq!(merged.len(), page.len(), "Zeilen");
        for (m, p) in merged.iter().zip(&page) {
            assert_eq!(m.text, p.text);
        }
    }

    #[test]
    fn merge_tall_page_without_duplicates() {
        check_roundtrip(1280, 10_000);
    }

    #[test]
    fn merge_wide_page_joins_lines_across_columns() {
        check_roundtrip(9000, 1000);
    }

    #[test]
    fn merge_huge_page_in_both_directions() {
        check_roundtrip(9000, 12_000);
    }

    #[test]
    fn single_tile_passes_through() {
        let page = page(1000, 600);
        let tiles = plan(1000, 600, LIMIT);
        let merged = merge(vec![(tiles[0].clone(), page.clone())]);
        assert_eq!(merged, page);
    }
}
