//! Raster der Karten unten links (`QuickAccessController.grid` / `panelSize` / `cardOrigin`).
//! Alle Maße in logischen Punkten. Ist eine Spalte bis zur Bildschirmhöhe voll, stapeln sich
//! neue Karten rechts daneben weiter; in jeder Spalte sitzt die neueste unten.

pub const CARD_WIDTH: f64 = 236.0;
pub const CARD_HEIGHT: f64 = 148.0;
pub const SPACING: f64 = 10.0;
pub const PADDING: f64 = 16.0;
pub const HEADER_HEIGHT: f64 = 30.0;
/// Abstand des Panels zum Rand des sichtbaren Bildschirmbereichs (Arbeitsbereich ohne Taskleiste).
pub const MARGIN: f64 = 4.0;

/// Karten pro Spalte und Spalten nebeneinander für einen Arbeitsbereich (Punkte).
pub fn grid(work_width: f64, work_height: f64) -> (usize, usize) {
    let height = work_height - 2.0 * MARGIN - HEADER_HEIGHT - 2.0 * PADDING + SPACING;
    let width = work_width - 2.0 * MARGIN - 2.0 * PADDING + SPACING;
    let rows = ((height / (CARD_HEIGHT + SPACING)) as usize).max(1);
    let columns = ((width / (CARD_WIDTH + SPACING)) as usize).max(1);
    (rows, columns)
}

/// Größe des Panels für `n` Karten bei `rows` Karten pro Spalte.
pub fn panel_size(n: usize, rows: usize) -> (f64, f64) {
    if n == 0 {
        return (0.0, 0.0);
    }
    let rows = rows.max(1);
    let tall = n.min(rows) as f64;
    let columns = ((n - 1) / rows + 1) as f64;
    let header = if n > 1 { HEADER_HEIGHT } else { 0.0 };
    (
        columns * CARD_WIDTH + (columns - 1.0) * SPACING + 2.0 * PADDING,
        tall * CARD_HEIGHT + (tall - 1.0) * SPACING + header + 2.0 * PADDING,
    )
}

/// Linke obere Ecke der Karte `index` im Panel, gemessen von **unten links** (x nach rechts, y nach oben).
pub fn card_origin_from_bottom(index: usize, n: usize, rows: usize) -> (f64, f64) {
    let rows = rows.max(1);
    let column = index / rows;
    let in_column = rows.min(n - column * rows);
    let from_bottom = in_column - 1 - index % rows;
    (
        PADDING + column as f64 * (CARD_WIDTH + SPACING),
        PADDING + from_bottom as f64 * (CARD_HEIGHT + SPACING),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_matches_mac() {
        // 2048×1028-pt-Bildschirm: 6 hoch, 8 Spalten (gemessen am Mac, 09.10.2026).
        assert_eq!(grid(2048.0, 1028.0), (6, 8));
        let (w, h) = panel_size(5, 2);
        assert_eq!((w, h), (3.0 * 246.0 - 10.0 + 32.0, 2.0 * 158.0 - 10.0 + 30.0 + 32.0));
        assert_eq!(card_origin_from_bottom(0, 5, 2), (16.0, 16.0 + 158.0));
        assert_eq!(card_origin_from_bottom(4, 5, 2), (16.0 + 2.0 * 246.0, 16.0));
    }
}
