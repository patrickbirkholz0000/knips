//! Textzeilen in Lesereihenfolge und „Text kopieren“ ohne Zensiertes (`TextLayout` in SensitiveDetector.swift).

use crate::geometry::Rect;
use crate::model::TextLine;

/// Lesereihenfolge: oben nach unten, innerhalb einer Zeile (Mitten näher als die halbe
/// kleinere Zeilenhöhe) links nach rechts.
pub fn sort_reading_order(lines: &mut [TextLine]) {
    let _ = lines;
    todo!("knips-core: textlayout::sort_reading_order")
}

/// Text in Lesereihenfolge. Wörter unter einer Zensur (Schnittfläche > 15 % des Worts) werden
/// zu „████“, ganz verdeckte Zeilen fallen weg; Zeilen auf gleicher Höhe werden mit zwei
/// Leerzeichen verbunden.
pub fn plain_text(lines: &[TextLine], hidden: &[Rect]) -> String {
    let _ = (lines, hidden);
    todo!("knips-core: textlayout::plain_text")
}
