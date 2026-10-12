//! Erkennung sensibler Daten (SensitiveDetector.swift) — Muster und Prüfsummen exakt wie auf dem Mac.
//! Die Texterkennung selbst liefert die Plattform (`knips_platform::ocr`).

use std::collections::BTreeSet;
use std::ops::Range;

use crate::model::{Finding, SensitiveKind, TextLine};

/// Treffer in `text` als Byte-Bereiche, ohne Überschneidungen (erster Treffer gewinnt), in der
/// Reihenfolge der Musterliste; danach die generische „lange Zeichenkette mit ≥ 4 Ziffern und
/// ≥ 8 Buchstaben“-Regel für `Secret`. Karte: Luhn, Telefon: ≥ 8 Ziffern, IBAN: Prüfsumme.
pub fn matches(text: &str, kinds: &BTreeSet<SensitiveKind>) -> Vec<(SensitiveKind, Range<usize>)> {
    let _ = (text, kinds);
    todo!("knips-core: sensitive::matches")
}

pub fn luhn(s: &str) -> bool {
    let _ = s;
    todo!("knips-core: sensitive::luhn")
}

pub fn iban_valid(s: &str) -> bool {
    let _ = s;
    todo!("knips-core: sensitive::iban_valid")
}

/// Funde auf erkannten Zeilen. Rechteck eines Treffers = Vereinigung der Wörter, die der
/// Zeichenbereich berührt (`TextLine.text` = Wörter mit je einem Leerzeichen verbunden).
/// Doppelte (überlappend und Text enthalten) werden übersprungen — wie auf dem Mac.
pub fn detect(lines: &[TextLine], kinds: &BTreeSet<SensitiveKind>) -> Vec<Finding> {
    let _ = (lines, kinds);
    todo!("knips-core: sensitive::detect")
}
