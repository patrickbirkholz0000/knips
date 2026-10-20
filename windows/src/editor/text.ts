// „Text kopieren“ im Editor: nur, was im gespeicherten Bild zu sehen ist. Dieselbe Regel wie
// `knips_core::textlayout::visible_text` (Rust, Kern-Tests); der Selbsttest `render` vergleicht beide.
import type { Rect, TextLine } from "../shared/types";
import { area, intersection, midY } from "./geometry";

const MASK = "████";

/**
 * Erkannter Text in Lesereihenfolge, so wie er im gespeicherten Bild steht:
 * - Wörter, die eine Zensurfläche auch nur teilweise überdeckt, werden zu „████“.
 * - Wörter außerhalb des Zuschnitts `crop` fallen weg, angeschnittene werden zu „████“.
 * - Zeilen nur aus Verdecktem fallen weg, ebenso Zeilen ohne Wortboxen, die eine Zensurfläche
 *   berühren oder nicht ganz im Zuschnitt liegen.
 * Zeilen auf gleicher Höhe werden mit zwei Leerzeichen verbunden.
 */
export function visibleText(lines: TextLine[], hidden: Rect[], crop: Rect | null): string {
  const covered = (r: Rect) => hidden.some((h) => area(intersection(h, r)) > 0);
  const outside = (r: Rect) => crop !== null && area(intersection(crop, r)) <= 0;
  const cut = (r: Rect) => crop !== null && area(intersection(crop, r)) < area(r) - 1e-6;
  const out: string[] = [];
  let lastMidY: number | null = null;
  let current = "";
  for (const line of lines) {
    let text: string;
    if (line.words.length === 0) {
      if (covered(line.rect) || cut(line.rect) || outside(line.rect)) continue;
      text = line.text;
    } else {
      const words = line.words.filter((w) => !outside(w.rect)).map((w) => (covered(w.rect) || cut(w.rect) ? MASK : w.text));
      if (words.every((w) => w === MASK)) continue;
      text = words.join(" ");
    }
    if (lastMidY !== null && Math.abs(midY(line.rect) - lastMidY) < line.rect.height * 0.5) current += "  " + text;
    else {
      if (current) out.push(current);
      current = text;
    }
    lastMidY = midY(line.rect);
  }
  if (current) out.push(current);
  return out.join("\n");
}

/** Ohne Zuschnitt (wie `plain_text`). */
export const plainText = (lines: TextLine[], hidden: Rect[]) => visibleText(lines, hidden, null);
