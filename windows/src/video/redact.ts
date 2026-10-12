// Geometrie und Vorschau-Zeichnen für Video-Zensur (Gegenstück zu VideoRedaction.rect(at:) und dem Renderer).
import type { Rect, RedactStyle, VideoRedaction } from "../shared/types";

/** Rechteck der Zensur zum Zeitpunkt t; mitlaufende Balken werden linear zwischen den Wegpunkten überblendet. */
export function rectAt(r: VideoRedaction, t: number): Rect {
  const track = r.track;
  if (!track || track.length === 0) return r.rect;
  const first = track[0];
  const last = track[track.length - 1];
  if (t <= first.time) return first.rect;
  if (t >= last.time) return last.rect;
  let lo = 0;
  let hi = track.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (track[mid].time <= t) lo = mid;
    else hi = mid;
  }
  const a = track[lo];
  const b = track[hi];
  const f = (t - a.time) / Math.max(0.0001, b.time - a.time);
  const mix = (p: number, q: number) => p + (q - p) * f;
  return {
    x: mix(a.rect.x, b.rect.x),
    y: mix(a.rect.y, b.rect.y),
    width: mix(a.rect.width, b.rect.width),
    height: mix(a.rect.height, b.rect.height),
  };
}

/** Zensur komplett verschieben (inkl. Wegpunkte). */
export function offsetRedaction(r: VideoRedaction, dx: number, dy: number): VideoRedaction {
  const move = (q: Rect): Rect => ({ ...q, x: q.x + dx, y: q.y + dy });
  return { ...r, rect: move(r.rect), track: r.track ? r.track.map((p) => ({ time: p.time, rect: move(p.rect) })) : null };
}

export function contains(r: Rect, x: number, y: number): boolean {
  return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
}

/** Nach außen auf ganze Pixel runden (CGRect.integral). */
export function integral(r: Rect): Rect {
  const x = Math.floor(r.x);
  const y = Math.floor(r.y);
  return { x, y, width: Math.ceil(r.x + r.width) - x, height: Math.ceil(r.y + r.height) - y };
}

export const BAR_COLOR = "rgb(15,15,15)";

let scratch: HTMLCanvasElement | null = null;
function scratchCanvas(w: number, h: number): HTMLCanvasElement {
  scratch ??= document.createElement("canvas");
  scratch.width = Math.max(1, Math.round(w));
  scratch.height = Math.max(1, Math.round(h));
  return scratch;
}

/**
 * Zeichnet die Zensur eines Videobild-Ausschnitts in `dest` (Zeichenflächen-Pixel).
 * `f` = Zeichenflächen-Pixel pro Videopixel, `scale` = Pixel pro Punkt der Aufnahme (wie auf dem Mac).
 */
export function drawRedaction(
  ctx: CanvasRenderingContext2D,
  video: HTMLVideoElement,
  videoW: number,
  videoH: number,
  rect: Rect,
  dest: Rect,
  style: RedactStyle,
  scale: number,
  f: number,
) {
  ctx.save();
  ctx.beginPath();
  ctx.rect(dest.x, dest.y, dest.width, dest.height);
  ctx.clip();
  try {
    if (style === "solid") {
      ctx.fillStyle = BAR_COLOR;
      ctx.fillRect(dest.x, dest.y, dest.width, dest.height);
    } else if (style === "pixelate") {
      const block = Math.max(10, Math.round(12 * scale));
      const cw = Math.max(1, Math.ceil(rect.width / block));
      const ch = Math.max(1, Math.ceil(rect.height / block));
      const c = scratchCanvas(cw, ch);
      const sctx = c.getContext("2d")!;
      sctx.imageSmoothingEnabled = true;
      sctx.clearRect(0, 0, cw, ch);
      sctx.drawImage(video, rect.x, rect.y, rect.width, rect.height, 0, 0, cw, ch);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(c, 0, 0, cw, ch, dest.x, dest.y, cw * block * f, ch * block * f);
    } else {
      const radius = 14 * scale;
      // Rand mit einlesen, damit die Unschärfe an den Kanten nicht ausblutet.
      const pad = radius * 2;
      const sx = Math.max(0, rect.x - pad);
      const sy = Math.max(0, rect.y - pad);
      const ex = Math.min(videoW, rect.x + rect.width + pad);
      const ey = Math.min(videoH, rect.y + rect.height + pad);
      ctx.filter = `blur(${radius * f}px)`;
      ctx.drawImage(
        video,
        sx, sy, ex - sx, ey - sy,
        dest.x + (sx - rect.x) * f, dest.y + (sy - rect.y) * f, (ex - sx) * f, (ey - sy) * f,
      );
      ctx.filter = "none";
    }
  } catch {
    // Noch kein Videobild vorhanden.
  }
  ctx.restore();
}
