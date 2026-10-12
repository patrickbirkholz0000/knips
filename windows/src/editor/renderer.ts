// Port von Editor/Renderer.swift + Annotation.swift: endgültiges Bild, Anmerkungen, Zensur-Effekte, Rahmen.
// Alle Koordinaten in Pixeln des Originals, Ursprung oben links.
import type { Annotation, FrameStyle, ImageDocument, Point, Rect, RedactStyle, Rgba, StrokeSize } from "../shared/types";
import { insetBy, integral, intersection, maxX, maxY } from "./geometry";

// ------------------------------------------------------------------ Farben & Größen

export const COLORS = {
  red: { r: 1, g: 0.23, b: 0.19, a: 1 },
  orange: { r: 1, g: 0.58, b: 0, a: 1 },
  yellow: { r: 1, g: 0.8, b: 0, a: 1 },
  green: { r: 0.2, g: 0.78, b: 0.35, a: 1 },
  blue: { r: 0, g: 0.48, b: 1, a: 1 },
  purple: { r: 0.69, g: 0.32, b: 0.87, a: 1 },
  black: { r: 0.08, g: 0.08, b: 0.09, a: 1 },
  white: { r: 1, g: 1, b: 1, a: 1 },
} satisfies Record<string, Rgba>;

export const PALETTE: Rgba[] = [COLORS.red, COLORS.orange, COLORS.yellow, COLORS.green, COLORS.blue, COLORS.purple, COLORS.black, COLORS.white];

export const rgbaCss = (c: Rgba, alpha?: number) =>
  `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${alpha ?? c.a})`;
export const luminance = (c: Rgba) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
export const sameColor = (a: Rgba, b: Rgba) =>
  Math.abs(a.r - b.r) < 0.004 && Math.abs(a.g - b.g) < 0.004 && Math.abs(a.b - b.b) < 0.004 && Math.abs(a.a - b.a) < 0.004;

export const STROKE_SIZES: StrokeSize[] = ["small", "medium", "large"];
export const STROKE_TITLE: Record<StrokeSize, string> = { small: "S", medium: "M", large: "L" };
const LINE_WIDTH: Record<StrokeSize, number> = { small: 3, medium: 5, large: 8 };
const FONT_SIZE: Record<StrokeSize, number> = { small: 16, medium: 24, large: 36 };
const COUNTER_RADIUS: Record<StrokeSize, number> = { small: 11, medium: 15, large: 21 };
export const lineWidth = (a: { size: StrokeSize }, scale: number) => LINE_WIDTH[a.size] * scale;
export const fontSize = (a: { size: StrokeSize }, scale: number) => FONT_SIZE[a.size] * scale;
export const counterRadius = (a: { size: StrokeSize }, scale: number) => COUNTER_RADIUS[a.size] * scale;

export const FRAME_GRADIENTS: { name: string; colors: [Rgba, Rgba] }[] = [
  { name: "Indigo", colors: [{ r: 0.39, g: 0.4, b: 0.95, a: 1 }, { r: 0.66, g: 0.33, b: 0.97, a: 1 }] },
  { name: "Abendrot", colors: [{ r: 0.98, g: 0.45, b: 0.09, a: 1 }, { r: 0.93, g: 0.28, b: 0.6, a: 1 }] },
  { name: "Ozean", colors: [{ r: 0.02, g: 0.71, b: 0.83, a: 1 }, { r: 0.23, g: 0.51, b: 0.96, a: 1 }] },
  { name: "Minze", colors: [{ r: 0.65, g: 0.95, b: 0.82, a: 1 }, { r: 0.2, g: 0.78, b: 0.55, a: 1 }] },
  { name: "Graphit", colors: [{ r: 0.22, g: 0.25, b: 0.32, a: 1 }, { r: 0.07, g: 0.09, b: 0.15, a: 1 }] },
  { name: "Hell", colors: [{ r: 0.96, g: 0.96, b: 0.97, a: 1 }, { r: 0.88, g: 0.89, b: 0.91, a: 1 }] },
];

export const DEFAULT_FRAME: FrameStyle = { gradient: 0, padding: 48, cornerRadius: 12, shadow: true };

export const FONT_FAMILY = `"Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif`;
const boldFont = (px: number) => `700 ${px}px ${FONT_FAMILY}`;

// ------------------------------------------------------------------ Bildquellen

export type BaseImage = HTMLCanvasElement | HTMLImageElement | ImageBitmap | OffscreenCanvas;

export function imageSize(img: BaseImage): { w: number; h: number } {
  if (img instanceof HTMLImageElement) return { w: img.naturalWidth, h: img.naturalHeight };
  return { w: img.width, h: img.height };
}

function makeCanvas(w: number, h: number): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(w));
  c.height = Math.max(1, Math.round(h));
  return c;
}

// ------------------------------------------------------------------ Zensur-Effekte

/** Blockgröße: 12 pt — bei normaler UI-Schrift ist eine Zeile damit höchstens zwei Blöcke hoch. */
export const pixelBlock = (scale: number) => Math.max(10, Math.round(12 * scale));
/** Gaußscher Weichzeichner (Sigma wie CIGaussianBlur-Radius). */
export const blurRadius = (scale: number) => 14 * scale;

export interface Region {
  canvas: HTMLCanvasElement;
  /** Bildposition der linken oberen Ecke der Zeichenfläche. */
  x: number;
  y: number;
}

/** Effekt (verpixelt/unscharf) nur für einen Bildausschnitt; Ergebnis deckt `rect` vollständig ab. */
export function effectRegion(source: BaseImage, srcW: number, srcH: number, rect: Rect, style: Exclude<RedactStyle, "solid">, scale: number): Region {
  const full: Rect = { x: 0, y: 0, width: srcW, height: srcH };
  if (style === "pixelate") {
    // Wie CIPixellate: Raster ab der Bildunterkante (Core Image zählt von unten), Farbe aus der Blockmitte.
    const b = pixelBlock(scale);
    const off = srcH % b;
    const x0 = Math.floor(rect.x / b) * b, y0 = Math.floor((rect.y - off) / b) * b + off;
    const x1 = Math.ceil(maxX(rect) / b) * b, y1 = Math.ceil((maxY(rect) - off) / b) * b + off;
    const out = makeCanvas(x1 - x0, y1 - y0);
    const area = intersection({ x: x0, y: y0, width: x1 - x0, height: y1 - y0 }, full);
    if (!area || area.width < 1 || area.height < 1) return { canvas: out, x: x0, y: y0 };
    const tmp = makeCanvas(area.width, area.height);
    const tctx = tmp.getContext("2d", { willReadFrequently: true })!;
    tctx.drawImage(source as CanvasImageSource, area.x, area.y, area.width, area.height, 0, 0, area.width, area.height);
    const src = tctx.getImageData(0, 0, tmp.width, tmp.height).data;
    const octx = out.getContext("2d")!;
    const half = Math.max(1, Math.floor(b / 8));
    for (let by = y0; by < y1; by += b) {
      for (let bx = x0; bx < x1; bx += b) {
        // Mittelwert eines kleinen Fensters um die Blockmitte (an den Bildrand begrenzt)
        const cx = Math.min(Math.max(bx + b / 2, area.x), maxX(area) - 1) - area.x;
        const cy = Math.min(Math.max(by + b / 2, area.y), maxY(area) - 1) - area.y;
        const sx0 = Math.max(0, Math.floor(cx - half)), sx1 = Math.min(tmp.width, Math.floor(cx + half) + 1);
        const sy0 = Math.max(0, Math.floor(cy - half)), sy1 = Math.min(tmp.height, Math.floor(cy + half) + 1);
        let r = 0, g = 0, bl = 0, a = 0, n = 0;
        for (let y = sy0; y < sy1; y++) {
          let i = (y * tmp.width + sx0) * 4;
          for (let x = sx0; x < sx1; x++, i += 4) {
            r += src[i]; g += src[i + 1]; bl += src[i + 2]; a += src[i + 3]; n++;
          }
        }
        if (n === 0) continue;
        octx.fillStyle = `rgba(${Math.round(r / n)}, ${Math.round(g / n)}, ${Math.round(bl / n)}, ${a / n / 255})`;
        octx.fillRect(bx - x0, by - y0, b, b);
      }
    }
    return { canvas: out, x: x0, y: y0 };
  }
  // Unschärfe: Ausschnitt + 3 Sigma Rand, Rand wie clampedToExtent mit Randpixeln gefüllt.
  const sigma = blurRadius(scale);
  const pad = Math.ceil(sigma * 3);
  const px = Math.floor(rect.x) - pad, py = Math.floor(rect.y) - pad;
  const pw = Math.ceil(rect.width) + 2 * pad + 1, ph = Math.ceil(rect.height) + 2 * pad + 1;
  const c = intersection({ x: px, y: py, width: pw, height: ph }, full);
  const out = makeCanvas(pw, ph);
  if (!c || c.width < 1 || c.height < 1) return { canvas: out, x: px, y: py };
  const tmp = makeCanvas(pw, ph);
  const t = tmp.getContext("2d")!;
  const S = source as CanvasImageSource;
  const dx = c.x - px, dy = c.y - py;
  t.drawImage(S, c.x, c.y, c.width, c.height, dx, dy, c.width, c.height);
  const right = pw - dx - c.width, bottom = ph - dy - c.height;
  if (dx > 0) t.drawImage(S, c.x, c.y, 1, c.height, 0, dy, dx, c.height);
  if (right > 0) t.drawImage(S, maxX(c) - 1, c.y, 1, c.height, dx + c.width, dy, right, c.height);
  if (dy > 0) t.drawImage(S, c.x, c.y, c.width, 1, dx, 0, c.width, dy);
  if (bottom > 0) t.drawImage(S, c.x, maxY(c) - 1, c.width, 1, dx, dy + c.height, c.width, bottom);
  if (dx > 0 && dy > 0) t.drawImage(S, c.x, c.y, 1, 1, 0, 0, dx, dy);
  if (right > 0 && dy > 0) t.drawImage(S, maxX(c) - 1, c.y, 1, 1, dx + c.width, 0, right, dy);
  if (dx > 0 && bottom > 0) t.drawImage(S, c.x, maxY(c) - 1, 1, 1, 0, dy + c.height, dx, bottom);
  if (right > 0 && bottom > 0) t.drawImage(S, maxX(c) - 1, maxY(c) - 1, 1, 1, dx + c.width, dy + c.height, right, bottom);
  const o = out.getContext("2d")!;
  o.filter = `blur(${sigma}px)`;
  o.drawImage(tmp, 0, 0);
  o.filter = "none";
  return { canvas: out, x: px, y: py };
}

/** Vollbild-Effektbilder (verpixelt, unscharf) — Zensurflächen zeigen davon nur ihren Ausschnitt. */
export class EffectsCache {
  readonly width: number;
  readonly height: number;
  private cache = new Map<RedactStyle, Region>();
  constructor(readonly base: BaseImage, readonly scale: number) {
    const s = imageSize(base);
    this.width = s.w;
    this.height = s.h;
  }
  get pixelBlock() {
    return pixelBlock(this.scale);
  }
  /** Ganzes Effektbild (nur Bildbereich); null bei „Balken“. */
  image(style: RedactStyle): Region | null {
    if (style === "solid") return null;
    let r = this.cache.get(style);
    if (!r) {
      r = effectRegion(this.base, this.width, this.height, { x: 0, y: 0, width: this.width, height: this.height }, style, this.scale);
      this.cache.set(style, r);
    }
    return r;
  }
}

/** Zensur auf `ctx` (Bildkoordinaten) — auch für den Video-Editor. `source` = Bild/Videobild in voller Größe. */
export function drawRedaction(ctx: CanvasRenderingContext2D, source: BaseImage, srcW: number, srcH: number, rect: Rect, style: RedactStyle, scale: number, effects?: EffectsCache | null) {
  const r = integral(rect);
  if (r.width <= 0 || r.height <= 0) return;
  ctx.save();
  ctx.beginPath();
  ctx.rect(r.x, r.y, r.width, r.height);
  ctx.clip();
  if (style !== "solid") {
    const fx = effects?.image(style) ?? effectRegion(source, srcW, srcH, r, style, scale);
    ctx.drawImage(fx.canvas, fx.x, fx.y);
  } else {
    ctx.fillStyle = "rgb(15, 15, 15)"; // grau 0,06
    ctx.fillRect(r.x, r.y, r.width, r.height);
  }
  ctx.restore();
}

// ------------------------------------------------------------------ Text

export interface TextMetricsBox {
  width: number;
  height: number;
  ascent: number;
}

let measureCtx: CanvasRenderingContext2D | null = null;
export function measureText(text: string, px: number): TextMetricsBox {
  measureCtx ??= makeCanvas(1, 1).getContext("2d")!;
  measureCtx.font = boldFont(px);
  const m = measureCtx.measureText(text);
  const ascent = m.fontBoundingBoxAscent ?? px * 0.98;
  const descent = m.fontBoundingBoxDescent ?? px * 0.24;
  return { width: m.width, height: ascent + descent, ascent };
}

export function textRect(a: Annotation, scale: number): Rect {
  const m = measureText(a.text === "" ? " " : a.text, fontSize(a, scale));
  return { x: a.start.x, y: a.start.y, width: m.width, height: m.height };
}

/** Bounding-Box für Treffer und Auswahlrahmen. */
export function annotationBounds(a: Annotation, scale: number): Rect {
  switch (a.kind) {
    case "text":
      return textRect(a, scale);
    case "counter": {
      const r = counterRadius(a, scale);
      return { x: a.start.x - r, y: a.start.y - r, width: 2 * r, height: 2 * r };
    }
    case "arrow":
    case "line": {
      const lw = lineWidth(a, scale);
      return insetBy(annotationRect(a), -lw * 2, -lw * 2);
    }
    default:
      return annotationRect(a);
  }
}

export function annotationRect(a: { start: Point; end: Point }): Rect {
  return { x: Math.min(a.start.x, a.end.x), y: Math.min(a.start.y, a.end.y), width: Math.abs(a.end.x - a.start.x), height: Math.abs(a.end.y - a.start.y) };
}

// ------------------------------------------------------------------ Formen

/** Spitz zulaufender Pfeil: schmaler Schaft, breiter Kopf. */
export function arrowPath(start: Point, end: Point, w: number): Path2D | null {
  const dx = end.x - start.x, dy = end.y - start.y;
  const length = Math.hypot(dx, dy);
  if (length <= 1) return null;
  const ux = dx / length, uy = dy / length;
  const nx = -uy, ny = ux;
  const headLength = Math.min(Math.max(w * 4.2, 14), length * 0.7);
  const headHalf = Math.max(w * 2.1, headLength * 0.48);
  const tailHalf = w * 0.22;
  const shaftHalf = w * 0.62;
  const p = (along: number, across: number): [number, number] => [start.x + ux * along + nx * across, start.y + uy * along + ny * across];
  const baseAlong = length - headLength * 0.82;
  const path = new Path2D();
  path.moveTo(...p(0, tailHalf));
  path.lineTo(...p(baseAlong, shaftHalf));
  path.lineTo(...p(length - headLength, headHalf));
  path.lineTo(end.x, end.y);
  path.lineTo(...p(length - headLength, -headHalf));
  path.lineTo(...p(baseAlong, -shaftHalf));
  path.lineTo(...p(0, -tailHalf));
  path.closePath();
  return path;
}

export function distanceToSegment(p: Point, a: Point, b: Point): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  if (len2 <= 0) return Math.hypot(p.x - a.x, p.y - a.y);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

function roundedRectPath(path: Path2D | CanvasRenderingContext2D, x: number, y: number, w: number, h: number, rx: number, ry: number) {
  path.moveTo(x + rx, y);
  path.lineTo(x + w - rx, y);
  path.ellipse(x + w - rx, y + ry, rx, ry, 0, -Math.PI / 2, 0);
  path.lineTo(x + w, y + h - ry);
  path.ellipse(x + w - rx, y + h - ry, rx, ry, 0, 0, Math.PI / 2);
  path.lineTo(x + rx, y + h);
  path.ellipse(x + rx, y + h - ry, rx, ry, 0, Math.PI / 2, Math.PI);
  path.lineTo(x, y + ry);
  path.ellipse(x + rx, y + ry, rx, ry, 0, Math.PI, Math.PI * 1.5);
  path.closePath();
}

/** `k` = Verhältnis Bildpixel → Zeichenfläche (Schatten werden von der Transformation nicht skaliert). */
function applyShadow(ctx: CanvasRenderingContext2D, scale: number, k: number) {
  ctx.shadowColor = "rgba(0, 0, 0, 0.35)";
  ctx.shadowOffsetX = 0;
  ctx.shadowOffsetY = 1 * scale * k;
  ctx.shadowBlur = 3 * scale * k;
}
function clearShadow(ctx: CanvasRenderingContext2D) {
  ctx.shadowColor = "transparent";
  ctx.shadowBlur = 0;
  ctx.shadowOffsetY = 0;
}

function haloColor(a: Annotation) {
  return luminance(a.color) > 0.75 ? "rgba(20, 20, 20, 0.9)" : "rgba(255, 255, 255, 0.95)";
}

/** Eine Anmerkung zeichnen. `source`/`effects` nur für Zensur nötig. */
export function drawAnnotation(ctx: CanvasRenderingContext2D, a: Annotation, scale: number, effects: EffectsCache | null | undefined, k = 1) {
  ctx.save();
  const lw = lineWidth(a, scale);
  const rect = annotationRect(a);
  switch (a.kind) {
    case "redact":
      if (effects) drawRedaction(ctx, effects.base, effects.width, effects.height, rect, a.redactStyle, scale, effects);
      else {
        const r = integral(rect);
        ctx.fillStyle = "rgb(15, 15, 15)";
        ctx.fillRect(r.x, r.y, r.width, r.height);
      }
      break;
    case "highlight":
      ctx.fillStyle = rgbaCss(a.color, 0.38);
      ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
      break;
    case "rectangle":
    case "ellipse": {
      applyShadow(ctx, scale, k);
      ctx.beginPath();
      if (a.kind === "rectangle") roundedRectPath(ctx, rect.x, rect.y, rect.width, rect.height, Math.min(lw, rect.width / 2), Math.min(lw, rect.height / 2));
      else ctx.ellipse(rect.x + rect.width / 2, rect.y + rect.height / 2, rect.width / 2, rect.height / 2, 0, 0, Math.PI * 2);
      if (a.filled) {
        ctx.fillStyle = rgbaCss(a.color);
        ctx.fill();
      } else {
        ctx.strokeStyle = rgbaCss(a.color);
        ctx.lineWidth = lw;
        ctx.lineJoin = "round";
        ctx.stroke();
      }
      break;
    }
    case "line":
      applyShadow(ctx, scale, k);
      ctx.strokeStyle = rgbaCss(a.color);
      ctx.lineWidth = lw;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(a.start.x, a.start.y);
      ctx.lineTo(a.end.x, a.end.y);
      ctx.stroke();
      break;
    case "arrow": {
      const path = arrowPath(a.start, a.end, lw);
      if (!path) break;
      applyShadow(ctx, scale, k);
      ctx.fillStyle = rgbaCss(a.color);
      ctx.strokeStyle = rgbaCss(a.color);
      ctx.lineWidth = lw * 0.35;
      ctx.lineJoin = "round";
      ctx.fill(path);
      clearShadow(ctx);
      ctx.stroke(path);
      break;
    }
    case "counter": {
      const r = counterRadius(a, scale);
      applyShadow(ctx, scale, k);
      ctx.fillStyle = rgbaCss(a.color);
      ctx.beginPath();
      ctx.arc(a.start.x, a.start.y, r, 0, Math.PI * 2);
      ctx.fill();
      clearShadow(ctx);
      ctx.strokeStyle = "rgba(255, 255, 255, 0.95)";
      ctx.lineWidth = Math.max(1.5, 2 * scale);
      ctx.beginPath();
      ctx.arc(a.start.x, a.start.y, r - scale, 0, Math.PI * 2);
      ctx.stroke();
      const px = r * 1.1;
      const m = measureText(String(a.number), px);
      ctx.font = boldFont(px);
      ctx.textBaseline = "alphabetic";
      ctx.fillStyle = luminance(a.color) > 0.7 ? "#000" : "#fff";
      ctx.fillText(String(a.number), a.start.x - m.width / 2, a.start.y - m.height / 2 + m.ascent);
      break;
    }
    case "text": {
      if (a.text === "") break;
      const px = fontSize(a, scale);
      const m = measureText(a.text, px);
      ctx.font = boldFont(px);
      ctx.textBaseline = "alphabetic";
      ctx.lineJoin = "round";
      ctx.strokeStyle = haloColor(a);
      ctx.lineWidth = px * 0.22;
      ctx.strokeText(a.text, a.start.x, a.start.y + m.ascent);
      ctx.fillStyle = rgbaCss(a.color);
      ctx.fillText(a.text, a.start.x, a.start.y + m.ascent);
      break;
    }
  }
  ctx.restore();
}

/** Zensur zuerst (sie verdeckt Bildinhalt, nicht andere Markierungen), danach alles andere in Reihenfolge. */
export function drawAll(ctx: CanvasRenderingContext2D, annotations: Annotation[], scale: number, effects: EffectsCache | null | undefined, hidingId?: string | null, k = 1) {
  for (const a of annotations) if (a.kind === "redact" && a.id !== hidingId) drawAnnotation(ctx, a, scale, effects, k);
  for (const a of annotations) if (a.kind !== "redact" && a.id !== hidingId) drawAnnotation(ctx, a, scale, effects, k);
}

// ------------------------------------------------------------------ Rahmen

export function frameBackgroundPath(ctx: CanvasRenderingContext2D, style: FrameStyle, rect: Rect) {
  const g = FRAME_GRADIENTS[Math.max(0, Math.min(style.gradient, FRAME_GRADIENTS.length - 1))].colors;
  // von links unten nach rechts oben
  const grad = ctx.createLinearGradient(rect.x, maxY(rect), maxX(rect), rect.y);
  grad.addColorStop(0, rgbaCss(g[0]));
  grad.addColorStop(1, rgbaCss(g[1]));
  ctx.save();
  ctx.beginPath();
  ctx.rect(rect.x, rect.y, rect.width, rect.height);
  ctx.clip();
  ctx.fillStyle = grad;
  ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
  ctx.restore();
}

/** Bild mit runden Ecken und weichem Schatten in `rect`. `scale` = Bildpunkt-Maßstab, `k` wie bei drawAll. */
export function drawFramedImage(ctx: CanvasRenderingContext2D, image: CanvasImageSource | null, rect: Rect, style: FrameStyle, scale: number, k = 1, draw?: () => void) {
  const radius = Math.min(style.cornerRadius * scale, Math.min(rect.width, rect.height) / 2);
  const path = new Path2D();
  roundedRectPath(path, rect.x, rect.y, rect.width, rect.height, radius, radius);
  if (style.shadow) {
    ctx.save();
    ctx.shadowColor = "rgba(0, 0, 0, 0.35)";
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 10 * scale * k;
    ctx.shadowBlur = 32 * scale * k;
    ctx.fillStyle = "#fff";
    ctx.fill(path);
    ctx.restore();
  }
  ctx.save();
  ctx.clip(path);
  if (draw) draw();
  else if (image) ctx.drawImage(image, rect.x, rect.y, rect.width, rect.height);
  ctx.restore();
}

// ------------------------------------------------------------------ Gesamtbild

/** Endgültiges Bild: Original + Anmerkungen, auf den Zuschnitt begrenzt, optional mit Rahmen. */
export function render(base: BaseImage, doc: ImageDocument, scale: number, effects?: EffectsCache | null): HTMLCanvasElement {
  const { w: bw, h: bh } = imageSize(base);
  const full: Rect = { x: 0, y: 0, width: bw, height: bh };
  const crop = intersection(integral(doc.crop ?? full), full) ?? full;
  const w = Math.max(1, Math.floor(crop.width)), h = Math.max(1, Math.floor(crop.height));
  const fx = effects ?? new EffectsCache(base, scale);
  const content = makeCanvas(w, h);
  const ctx = content.getContext("2d")!;
  ctx.imageSmoothingQuality = "high";
  ctx.translate(-crop.x, -crop.y);
  ctx.drawImage(base as CanvasImageSource, 0, 0);
  drawAll(ctx, doc.annotations, scale, fx, null);
  if (!doc.frame) return content;
  return framed(content, doc.frame, scale);
}

/** Screenshot auf Farbverlauf mit Abstand, runden Ecken und weichem Schatten. */
export function framed(content: HTMLCanvasElement, style: FrameStyle, scale: number): HTMLCanvasElement {
  const pad = style.padding * scale;
  const w = content.width + Math.trunc(2 * pad), h = content.height + Math.trunc(2 * pad);
  const out = makeCanvas(w, h);
  const ctx = out.getContext("2d")!;
  frameBackgroundPath(ctx, style, { x: 0, y: 0, width: w, height: h });
  drawFramedImage(ctx, content, { x: pad, y: pad, width: content.width, height: content.height }, style, scale);
  return out;
}
