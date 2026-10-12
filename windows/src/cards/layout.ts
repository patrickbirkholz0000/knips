// Raster der Karten (Port von QuickAccessController.panelSize / cardOrigin; Konstanten wie crates/core/src/cards.rs).
export const CARD_W = 236;
export const CARD_H = 148;
export const SPACING = 10;
export const PADDING = 16;
export const HEADER_H = 30;

export function panelSize(n: number, rows: number): { width: number; height: number } {
  if (n <= 0) return { width: 0, height: 0 };
  rows = Math.max(1, rows);
  const tall = Math.min(n, rows);
  const columns = Math.floor((n - 1) / rows) + 1;
  const header = n > 1 ? HEADER_H : 0;
  return {
    width: columns * CARD_W + (columns - 1) * SPACING + 2 * PADDING,
    height: tall * CARD_H + (tall - 1) * SPACING + header + 2 * PADDING,
  };
}

/** Abstand der Karte `index` von links und von unten (Panel-Ecke unten links). Neueste Karte unten in ihrer Spalte. */
export function cardOrigin(index: number, n: number, rows: number): { x: number; y: number } {
  rows = Math.max(1, rows);
  const column = Math.floor(index / rows);
  const inColumn = Math.min(rows, n - column * rows);
  const fromBottom = inColumn - 1 - (index % rows);
  return { x: PADDING + column * (CARD_W + SPACING), y: PADDING + fromBottom * (CARD_H + SPACING) };
}
