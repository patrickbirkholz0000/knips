// Kleine Rechteck-Helfer (Gegenstücke zu CGRect-Methoden). Ursprung oben links.
import type { Point, Rect } from "../shared/types";

export const maxX = (r: Rect) => r.x + r.width;
export const maxY = (r: Rect) => r.y + r.height;
export const midX = (r: Rect) => r.x + r.width / 2;
export const midY = (r: Rect) => r.y + r.height / 2;
export const area = (r: Rect | null) => (r ? r.width * r.height : 0);

export function rectFromPoints(a: Point, b: Point): Rect {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) };
}

export function insetBy(r: Rect, dx: number, dy: number): Rect {
  return { x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy };
}

/** Wie CGRect.intersection: null, wenn sich die Rechtecke nicht berühren. */
export function intersection(a: Rect, b: Rect): Rect | null {
  const x1 = Math.max(a.x, b.x), y1 = Math.max(a.y, b.y);
  const x2 = Math.min(maxX(a), maxX(b)), y2 = Math.min(maxY(a), maxY(b));
  if (x1 > x2 || y1 > y2) return null;
  return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
}

/** Echte Überlappung (Kanten berühren zählt nicht) wie CGRect.intersects. */
export function intersects(a: Rect, b: Rect): boolean {
  return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0 && a.x < maxX(b) && b.x < maxX(a) && a.y < maxY(b) && b.y < maxY(a);
}

export function union(a: Rect, b: Rect): Rect {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, width: Math.max(maxX(a), maxX(b)) - x, height: Math.max(maxY(a), maxY(b)) - y };
}

export function contains(r: Rect, p: Point): boolean {
  return p.x >= r.x && p.x < maxX(r) && p.y >= r.y && p.y < maxY(r);
}

/** CGRect.integral: nach außen auf ganze Pixel. */
export function integral(r: Rect): Rect {
  const x = Math.floor(r.x), y = Math.floor(r.y);
  return { x, y, width: Math.ceil(maxX(r)) - x, height: Math.ceil(maxY(r)) - y };
}

export function rectEq(a: Rect | null, b: Rect | null): boolean {
  if (!a || !b) return a === b;
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}
