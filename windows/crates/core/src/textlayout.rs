//! Textzeilen in Lesereihenfolge und „Text kopieren“ ohne Zensiertes und ohne Weggeschnittenes
//! (`TextLayout` in SensitiveDetector.swift; `visibleText` in `src/editor/text.ts` ist dieselbe Regel).

use crate::geometry::Rect;
use crate::model::TextLine;

/// Liegt `a` vor `b`? Gleiche Zeile (Mitten näher als die halbe kleinere Höhe) → links zuerst,
/// sonst oben zuerst. Genau der Vergleich vom Mac.
fn before(a: &TextLine, b: &TextLine) -> bool {
    let (ar, br) = (&a.rect, &b.rect);
    if (ar.mid_y() - br.mid_y()).abs() < ar.height.min(br.height) * 0.5 {
        ar.min_x() < br.min_x()
    } else {
        ar.mid_y() < br.mid_y()
    }
}

/// Lesereihenfolge: oben nach unten, innerhalb einer Zeile (Mitten näher als die halbe
/// kleinere Zeilenhöhe) links nach rechts.
///
/// Der Vergleich ist nicht transitiv (Ketten leicht versetzter Zeilen); darum Einfügesortierung
/// — stabil und ohne Panik wie bei `slice::sort_by` mit widersprüchlicher Ordnung.
pub fn sort_reading_order(lines: &mut [TextLine]) {
    for i in 1..lines.len() {
        let mut j = i;
        while j > 0 && before(&lines[j], &lines[j - 1]) {
            lines.swap(j, j - 1);
            j -= 1;
        }
    }
}

/// Text in Lesereihenfolge (Karte „Text kopieren“). Wie `visible_text` ohne Zuschnitt.
pub fn plain_text(lines: &[TextLine], hidden: &[Rect]) -> String {
    visible_text(lines, hidden, None)
}

/// Text, so wie er im gespeicherten Bild zu sehen ist (Editor „Text kopieren“), in Lesereihenfolge:
/// - Wörter, die eine Zensurfläche auch nur teilweise überdeckt, werden zu „████“.
/// - Wörter außerhalb des Zuschnitts `crop` fallen weg, angeschnittene werden zu „████“.
/// - Zeilen nur aus Verdecktem fallen weg, ebenso Zeilen ohne Wortboxen, die eine Zensurfläche
///   berühren oder nicht ganz im Zuschnitt liegen.
///
/// Zeilen auf gleicher Höhe werden mit zwei Leerzeichen verbunden. (Der Mac verdeckt erst ab 15 %
/// Überdeckung; hier zählt jede Überschneidung — lieber ein Wort zu viel verdeckt als eines verraten.)
pub fn visible_text(lines: &[TextLine], hidden: &[Rect], crop: Option<&Rect>) -> String {
    const MASK: &str = "████";
    let covered = |r: &Rect| hidden.iter().any(|h| h.intersection(r).area() > 0.0);
    let outside = |r: &Rect| crop.is_some_and(|c| c.intersection(r).area() <= 0.0);
    let cut = |r: &Rect| crop.is_some_and(|c| c.intersection(r).area() < r.area() - 1e-6);
    let mut out: Vec<String> = Vec::new();
    let mut last_mid_y: Option<f64> = None;
    let mut current = String::new();
    for line in lines {
        let text = if line.words.is_empty() {
            if covered(&line.rect) || cut(&line.rect) || outside(&line.rect) {
                continue;
            }
            line.text.clone()
        } else {
            let words: Vec<&str> = line
                .words
                .iter()
                .filter(|w| !outside(&w.rect))
                .map(|w| if covered(&w.rect) || cut(&w.rect) { MASK } else { w.text.as_str() })
                .collect();
            if words.iter().all(|w| *w == MASK) {
                continue;
            }
            words.join(" ")
        };
        match last_mid_y {
            Some(y) if (line.rect.mid_y() - y).abs() < line.rect.height * 0.5 => {
                current.push_str("  ");
                current.push_str(&text);
            }
            _ => {
                if !current.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
                current = text;
            }
        }
        last_mid_y = Some(line.rect.mid_y());
    }
    if !current.is_empty() {
        out.push(current);
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TextWord;

    fn line(x: f64, y: f64, words: &[&str]) -> TextLine {
        let mut cx = x;
        TextLine::from_words(
            words
                .iter()
                .map(|t| {
                    let w = t.chars().count() as f64 * 8.0;
                    let r = TextWord { text: t.to_string(), rect: Rect::new(cx, y, w, 16.0) };
                    cx += w + 8.0;
                    r
                })
                .collect(),
        )
    }

    #[test]
    fn reading_order() {
        let mut lines = vec![
            line(300.0, 52.0, &["rechts"]),
            line(10.0, 100.0, &["unten"]),
            line(10.0, 50.0, &["links"]),
            line(10.0, 10.0, &["oben"]),
        ];
        sort_reading_order(&mut lines);
        let order: Vec<_> = lines.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(order, ["oben", "links", "rechts", "unten"]);
    }

    #[test]
    fn sort_never_panics_on_intransitive_input() {
        let mut lines: Vec<TextLine> = (0..300).map(|i| line((i * 37 % 500) as f64, (i * 5 % 97) as f64, &["x"])).collect();
        sort_reading_order(&mut lines);
        assert_eq!(lines.len(), 300);
    }

    #[test]
    fn plain_text_joins_same_row_with_two_spaces() {
        let lines = vec![line(10.0, 10.0, &["Name:", "Erika"]), line(300.0, 11.0, &["Ort"]), line(10.0, 60.0, &["zweite", "Zeile"])];
        assert_eq!(plain_text(&lines, &[]), "Name: Erika  Ort\nzweite Zeile");
    }

    #[test]
    fn plain_text_masks_hidden_words_and_drops_hidden_lines() {
        let lines = vec![line(10.0, 10.0, &["Passwort:", "hunter22"]), line(10.0, 60.0, &["geheim"]), line(10.0, 110.0, &["sichtbar", "bleibt"])];
        // Balken über „hunter22“ (x ab 90) und über die ganze zweite Zeile
        let hidden = vec![Rect::new(85.0, 5.0, 100.0, 26.0), Rect::new(0.0, 55.0, 200.0, 26.0)];
        let t = plain_text(&lines, &hidden);
        assert_eq!(t, "Passwort: ████\nsichtbar bleibt");
        assert!(!t.contains("hunter22") && !t.contains("geheim"));
    }

    #[test]
    fn any_overlap_hides_a_word() {
        let l = vec![line(0.0, 0.0, &["abcdefghij"])]; // 80 x 16
        // Schon 1 px Überschneidung verdeckt (früher erst ab 15 %); bloßes Berühren nicht.
        assert_eq!(plain_text(&l, &[Rect::new(79.0, 15.0, 10.0, 10.0)]), "");
        assert_eq!(plain_text(&l, &[Rect::new(80.0, 0.0, 10.0, 16.0)]), "abcdefghij");
        let l = vec![line(0.0, 0.0, &["abcdefghij", "ok"])];
        assert_eq!(plain_text(&l, &[Rect::new(0.0, 0.0, 2.0, 16.0)]), "████ ok");
    }

    #[test]
    fn crop_drops_words_outside_and_masks_cut_words() {
        let lines = vec![
            line(10.0, 10.0, &["oben", "geheim"]),
            line(10.0, 60.0, &["Name:", "Erika", "Mustermann"]),
            line(10.0, 110.0, &["unten", "weg"]),
        ];
        // Zuschnitt: nur die mittlere Zeile bis in „Mustermann“ hinein (x 106…186).
        let crop = Rect::new(0.0, 50.0, 150.0, 40.0);
        let t = visible_text(&lines, &[], Some(&crop));
        assert_eq!(t, "Name: Erika ████");
        assert!(!t.contains("geheim") && !t.contains("Mustermann") && !t.contains("unten"));
        // Zuschnitt + Zensur zusammen.
        let t = visible_text(&lines, &[Rect::new(58.0, 62.0, 4.0, 4.0)], Some(&crop));
        assert_eq!(t, "Name: ████ ████");
        // Ganz außerhalb: nichts.
        assert_eq!(visible_text(&lines, &[], Some(&Rect::new(500.0, 500.0, 10.0, 10.0))), "");
        // Ohne Zuschnitt alles.
        assert_eq!(visible_text(&lines, &[], None), "oben geheim\nName: Erika Mustermann\nunten weg");
    }

    #[test]
    fn plain_text_line_without_words() {
        let l = vec![TextLine { text: "ganze Zeile".into(), rect: Rect::new(0.0, 0.0, 100.0, 16.0), words: vec![] }];
        assert_eq!(plain_text(&l, &[]), "ganze Zeile");
        assert_eq!(plain_text(&l, &[Rect::new(0.0, 0.0, 100.0, 16.0)]), "");
        // Jede Berührung mit einer Zensur oder dem Rand des Zuschnitts nimmt die Zeile heraus.
        assert_eq!(plain_text(&l, &[Rect::new(99.0, 15.0, 5.0, 5.0)]), "");
        assert_eq!(visible_text(&l, &[], Some(&Rect::new(0.0, 0.0, 90.0, 40.0))), "");
        assert_eq!(visible_text(&l, &[], Some(&Rect::new(-5.0, -5.0, 200.0, 40.0))), "ganze Zeile");
        assert_eq!(plain_text(&[], &[]), "");
    }
}
