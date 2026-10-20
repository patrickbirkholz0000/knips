//! Erkennung sensibler Daten (SensitiveDetector.swift) — Muster und Prüfsummen exakt wie auf dem Mac.
//! Die Texterkennung selbst liefert die Plattform (`knips_platform::ocr`).

use std::collections::BTreeSet;
use std::ops::Range;
use std::sync::OnceLock;

use regex::Regex;

use crate::geometry::Rect;
use crate::model::{Finding, SensitiveKind, TextLine};

/// Muster in der Reihenfolge der Mac-Liste (Reihenfolge entscheidet: erster Treffer gewinnt).
fn patterns() -> &'static [(SensitiveKind, Regex)] {
    static P: OnceLock<Vec<(SensitiveKind, Regex)>> = OnceLock::new();
    P.get_or_init(|| {
        use SensitiveKind::*;
        let list: [(SensitiveKind, &str); 15] = [
            (Email, r"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"),
            (Iban, r"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,4})?\b"),
            (Secret, r"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"),
            (Secret, r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{16,}"),
            (Secret, r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
            (Secret, r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
            (Secret, r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"),
            (Secret, r"\bAKIA[0-9A-Z]{16}\b"),
            (Secret, r"\bAIza[0-9A-Za-z_\-]{30,}"),
            (Secret, r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}"),
            // Wie auf dem Mac, dazu „…-Key:“ und „Schlüssel:“ als Bezeichner: die Windows-Texterkennung
            // verliert bei Schlüsseln mit Unterstrichen gern den Anfang („sk_live_…“), der Rest
            // hängt dann nur noch am Bezeichner.
            (Secret, r"(?i)(?:passwor[dt]|password|pwd|secret|token|api[_ -]?key|\bkey|schl[üu]ssel)\s*[:=]\s*\S{4,}"),
            (Card, r"\b(?:\d[ \-]?){12,18}\d\b"),
            (Phone, r"(?:\+|00)[1-9][0-9 ()/.\-]{7,}[0-9]"),
            (Phone, r"\b0[1-9][0-9]{1,4}[ /\-]?[0-9]{3,}(?:[ \-]?[0-9]{2,})*\b"),
            (Ip, r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"),
        ];
        list.iter().filter_map(|(k, p)| Regex::new(p).ok().map(|r| (*k, r))).collect()
    })
}

/// Lange Zeichenketten aus Buchstaben UND Ziffern ohne Leerzeichen: typisch für Tokens/Hashes.
fn generic() -> &'static Regex {
    static G: OnceLock<Regex> = OnceLock::new();
    G.get_or_init(|| Regex::new(r"\b[A-Za-z0-9_\-]{28,}\b").expect("Muster gültig"))
}

fn overlaps(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

/// Treffer in `text` als Byte-Bereiche, ohne Überschneidungen (erster Treffer gewinnt), in der
/// Reihenfolge der Musterliste; danach die generische „lange Zeichenkette mit ≥ 4 Ziffern und
/// ≥ 8 Buchstaben“-Regel für `Secret`. Karte: Luhn, Telefon: ≥ 8 Ziffern, IBAN: Prüfsumme.
pub fn matches(text: &str, kinds: &BTreeSet<SensitiveKind>) -> Vec<(SensitiveKind, Range<usize>)> {
    let mut taken: Vec<Range<usize>> = Vec::new();
    let mut out = Vec::new();
    let mut add = |kind: SensitiveKind, r: Range<usize>| {
        if taken.iter().any(|t| overlaps(t, &r)) {
            return;
        }
        taken.push(r.clone());
        out.push((kind, r));
    };
    for (kind, re) in patterns() {
        if !kinds.contains(kind) {
            continue;
        }
        for m in re.find_iter(text) {
            let s = m.as_str();
            match kind {
                SensitiveKind::Card if !luhn(s) => continue,
                SensitiveKind::Phone if s.chars().filter(|c| c.is_numeric()).count() < 8 => continue,
                SensitiveKind::Iban if !iban_valid(s) => continue,
                _ => {}
            }
            add(*kind, m.range());
        }
    }
    if kinds.contains(&SensitiveKind::Secret) {
        for m in generic().find_iter(text) {
            let s = m.as_str();
            let digits = s.chars().filter(|c| c.is_numeric()).count();
            let letters = s.chars().filter(|c| c.is_alphabetic()).count();
            if digits >= 4 && letters >= 8 {
                add(SensitiveKind::Secret, m.range());
            }
        }
    }
    out
}

pub fn luhn(s: &str) -> bool {
    let digits: Vec<u32> = s.chars().filter_map(|c| c.to_digit(10)).collect();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &d)| {
            if i % 2 == 1 {
                let x = d * 2;
                if x > 9 { x - 9 } else { x }
            } else {
                d
            }
        })
        .sum();
    sum.is_multiple_of(10)
}

pub fn iban_valid(s: &str) -> bool {
    let iban: Vec<char> = s.replace(' ', "").to_uppercase().chars().collect();
    if iban.len() < 15 || iban.len() > 34 {
        return false;
    }
    let mut remainder = 0u32;
    for &ch in iban[4..].iter().chain(iban[..4].iter()) {
        let value = if let Some(d) = ch.to_digit(10) {
            d
        } else if ch.is_ascii_uppercase() {
            ch as u32 - 55
        } else {
            return false;
        };
        for digit in value.to_string().chars() {
            remainder = (remainder * 10 + digit.to_digit(10).unwrap_or(0)) % 97;
        }
    }
    remainder == 1
}

/// Byte-Bereiche der Wörter in `line.text`. `text` = Wörter mit einem Leerzeichen verbunden;
/// weicht ein Text davon ab, wird das Wort ab der letzten Stelle gesucht.
fn word_spans(line: &TextLine) -> Vec<Option<Range<usize>>> {
    let mut cursor = 0usize;
    line.words
        .iter()
        .map(|w| {
            let found = if line.text.get(cursor..).is_some_and(|t| t.starts_with(&w.text)) {
                Some(cursor)
            } else {
                line.text.get(cursor..).and_then(|t| t.find(&w.text)).map(|i| cursor + i)
            };
            found.map(|s| {
                cursor = s + w.text.len();
                s..cursor
            })
        })
        .collect()
}

/// Funde auf erkannten Zeilen. Rechteck eines Treffers = Vereinigung der Wörter, die der
/// Zeichenbereich berührt (`TextLine.text` = Wörter mit je einem Leerzeichen verbunden).
/// Doppelte (überlappend und Text enthalten) werden übersprungen — wie auf dem Mac.
pub fn detect(lines: &[TextLine], kinds: &BTreeSet<SensitiveKind>) -> Vec<Finding> {
    if kinds.is_empty() {
        return Vec::new();
    }
    let mut findings: Vec<Finding> = Vec::new();
    for line in lines {
        let spans = word_spans(line);
        for (kind, range) in matches(&line.text, kinds) {
            let mut rect = Rect::NULL;
            for (w, span) in line.words.iter().zip(&spans) {
                if span.as_ref().is_some_and(|s| overlaps(s, &range)) {
                    rect = rect.union(&w.rect);
                }
            }
            if rect.is_null() {
                if !line.words.is_empty() {
                    continue;
                }
                rect = line.rect; // Zeile ohne Wortrechtecke: ganze Zeile
                if rect.is_null() {
                    continue;
                }
            }
            let snippet = line.text[range].to_string();
            if findings.iter().any(|f| f.rect.intersects(&rect) && f.text.contains(&snippet)) {
                continue;
            }
            findings.push(Finding { rect, kind, text: snippet });
        }
    }
    findings
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TextWord;
    use SensitiveKind::*;

    fn all() -> BTreeSet<SensitiveKind> {
        SensitiveKind::ALL.into_iter().collect()
    }

    fn kinds_of(s: &str) -> Vec<SensitiveKind> {
        matches(s, &all()).into_iter().map(|m| m.0).collect()
    }

    fn only(s: &str) -> Vec<(SensitiveKind, String)> {
        matches(s, &all()).into_iter().map(|(k, r)| (k, s[r].to_string())).collect()
    }

    #[test]
    fn email() {
        assert_eq!(only("erika.mustermann@example.com"), vec![(Email, "erika.mustermann@example.com".into())]);
        assert_eq!(only("Mail: KONTAKT@example.com bitte"), vec![(Email, "KONTAKT@example.com".into())]);
        assert!(kinds_of("kein at hier example.com").is_empty());
    }

    #[test]
    fn iban() {
        assert_eq!(only("IBAN DE89 3704 0044 0532 0130 00"), vec![(Iban, "DE89 3704 0044 0532 0130 00".into())]);
        assert_eq!(kinds_of("DE89370400440532013000"), vec![Iban]);
        // falsche Prüfsumme
        assert!(!kinds_of("DE89 3704 0044 0532 0130 01").contains(&Iban));
        assert!(iban_valid("GB82 WEST 1234 5698 7654 32"));
        assert!(!iban_valid("GB82 WEST 1234 5698 7654 33"));
        assert!(!iban_valid("DE89"));
        assert!(!iban_valid("DE89 3704 0044 0532 0130 0$"));
    }

    #[test]
    fn phone() {
        assert_eq!(only("Tel +49 170 1234567"), vec![(Phone, "+49 170 1234567".into())]);
        assert_eq!(only("Ruf 030 1234567 an"), vec![(Phone, "030 1234567".into())]);
        assert_eq!(only("0170 1234567"), vec![(Phone, "0170 1234567".into())]);
        // zu kurz
        assert!(kinds_of("+49 12 34").is_empty());
        assert!(kinds_of("Bestellung 48213 versendet").is_empty());
        assert!(!kinds_of("030 1234").contains(&Phone));
    }

    /// Erfundener Stripe-Schlüssel wie im Testbild (`knips_platform::sample::STRIPE_KEY`). Absichtlich
    /// zusammengesetzt: Im Quelltext steht so nie „sk_“ + „live_“ direkt vor Buchstaben/Ziffern, damit
    /// Secret-Scanner (GitHub-Push-Schutz) nicht anschlagen.
    const STRIPE_KEY: &str = concat!("sk_", "live_KnipsBeispiel42");

    #[test]
    fn secrets() {
        assert_eq!(only(STRIPE_KEY), vec![(Secret, STRIPE_KEY.into())]);
        let line = format!("Stripe-Key: {STRIPE_KEY}");
        assert_eq!(only(&line), vec![(Secret, STRIPE_KEY.into())]);
        assert_eq!(kinds_of("ghp_abcdefghijklmnopqrstuvwxyz123456"), vec![Secret]);
        assert_eq!(kinds_of("AKIAIOSFODNN7EXAMPLE"), vec![Secret]);
        assert_eq!(kinds_of("sk-ant-api03-abcdefghijklmnop1234"), vec![Secret]);
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
        assert_eq!(only(jwt), vec![(Secret, jwt.into())]);
        assert_eq!(only("Passwort: hunter22"), vec![(Secret, "Passwort: hunter22".into())]);
        assert_eq!(only("API_KEY=abcd1234"), vec![(Secret, "API_KEY=abcd1234".into())]);
        // Texterkennung hat den Anfang verloren: Bezeichner + Rest
        assert_eq!(only("Stripe-key: KnipsBeispiel42"), vec![(Secret, "key: KnipsBeispiel42".into())]);
        assert_eq!(only("Lizenzschlüssel: ABCD-EFGH"), vec![(Secret, "schlüssel: ABCD-EFGH".into())]);
        assert!(only("Hotkey: Strg+Druck").is_empty());
        // generisch: >= 28 Zeichen, >= 4 Ziffern, >= 8 Buchstaben
        assert_eq!(kinds_of("d41d8cd98f00b204e9800998ecf8427e1234"), vec![Secret]);
        assert!(kinds_of("abcdefghijklmnopqrstuvwxyzabcdefgh").is_empty()); // keine Ziffern
        assert!(kinds_of("Passwort ändern").is_empty());
    }

    #[test]
    fn card_and_luhn() {
        assert_eq!(only("Karte 4111 1111 1111 1111"), vec![(Card, "4111 1111 1111 1111".into())]);
        assert_eq!(only("4111-1111-1111-1111"), vec![(Card, "4111-1111-1111-1111".into())]);
        assert!(luhn("4111 1111 1111 1111"));
        assert!(luhn("5500 0000 0000 0004"));
        assert!(!luhn("4111 1111 1111 1112"));
        assert!(!luhn("1234"));
        assert!(!kinds_of("4111 1111 1111 1112").contains(&Card));
    }

    #[test]
    fn ip() {
        assert_eq!(only("Server 192.168.178.1 läuft"), vec![(Ip, "192.168.178.1".into())]);
        assert_eq!(kinds_of("10.0.0.255"), vec![Ip]);
        assert!(kinds_of("999.1.1.1").is_empty());
        assert!(kinds_of("Version 1.2.3").is_empty());
    }

    #[test]
    fn kind_filter_and_no_overlap() {
        let only_email: BTreeSet<_> = [Email].into_iter().collect();
        assert!(matches("DE89 3704 0044 0532 0130 00", &only_email).is_empty());
        // Karte überlappt mit Telefon-Muster: Karte (früher in der Liste) gewinnt
        let v = matches("4111 1111 1111 1111", &all());
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].0, Card);
        // Treffer-Bereiche sind Byte-Bereiche (Umlaute davor)
        let s = "Größe ä ö mail@x.de";
        let m = matches(s, &all());
        assert_eq!(&s[m[0].1.clone()], "mail@x.de");
    }

    fn line(words: &[(&str, f64, f64)]) -> TextLine {
        TextLine::from_words(words.iter().map(|(t, x, w)| TextWord { text: t.to_string(), rect: Rect::new(*x, 10.0, *w, 20.0) }).collect())
    }

    #[test]
    fn detect_maps_to_word_rects() {
        let l = line(&[("Kontakt:", 0.0, 60.0), ("erika.mustermann@example.com", 70.0, 200.0), ("danke", 280.0, 40.0)]);
        let f = detect(&[l], &all());
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].kind, Email);
        assert_eq!(f[0].text, "erika.mustermann@example.com");
        assert_eq!(f[0].rect, Rect::new(70.0, 10.0, 200.0, 20.0));
    }

    #[test]
    fn detect_unions_multiple_words() {
        let l = line(&[("IBAN", 0.0, 40.0), ("DE89", 50.0, 40.0), ("3704", 100.0, 40.0), ("0044", 150.0, 40.0), ("0532", 200.0, 40.0), ("0130", 250.0, 40.0), ("00", 300.0, 20.0)]);
        let f = detect(&[l], &all());
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].kind, Iban);
        assert_eq!(f[0].text, "DE89 3704 0044 0532 0130 00");
        assert_eq!(f[0].rect, Rect::new(50.0, 10.0, 270.0, 20.0));
        // Passwort: hunter22
        let l = line(&[("Passwort:", 0.0, 70.0), ("hunter22", 80.0, 60.0)]);
        let f = detect(&[l], &all());
        assert_eq!(f[0].rect, Rect::new(0.0, 10.0, 140.0, 20.0));
    }

    #[test]
    fn detect_dedups_overlapping_same_text() {
        let l1 = line(&[("mail@x.de", 0.0, 90.0)]);
        let l2 = line(&[("mail@x.de", 10.0, 90.0)]); // überlappt, gleicher Text → übersprungen
        let l3 = TextLine::from_words(vec![TextWord { text: "mail@x.de".into(), rect: Rect::new(0.0, 100.0, 90.0, 20.0) }]);
        let f = detect(&[l1, l2, l3], &all());
        assert_eq!(f.len(), 2);
    }

    #[test]
    fn detect_negatives_and_empty_kinds() {
        let l = line(&[("Bestellung", 0.0, 80.0), ("48213", 90.0, 40.0), ("versendet", 140.0, 70.0)]);
        assert!(detect(std::slice::from_ref(&l), &all()).is_empty());
        let l2 = line(&[("a@b.de", 0.0, 50.0)]);
        assert!(detect(&[l2], &BTreeSet::new()).is_empty());
    }

    #[test]
    fn detect_line_without_words_uses_line_rect() {
        let l = TextLine { text: "a@b.de".into(), rect: Rect::new(5.0, 5.0, 50.0, 12.0), words: vec![] };
        let f = detect(&[l], &all());
        assert_eq!(f[0].rect, Rect::new(5.0, 5.0, 50.0, 12.0));
    }
}
