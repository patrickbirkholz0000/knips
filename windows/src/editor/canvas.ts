// Port von Editor/CanvasView.swift: Zeichenfläche des Bild-Editors als Controller um ein <canvas>.
// Bildkoordinaten = Pixel des Originals, Ursprung oben links; Ansichtskoordinaten = CSS-Pixel im Canvas.
import type { Annotation, Point, Rect } from "../shared/types";
import { contains, insetBy, intersection, maxX, maxY, midX, midY, rectFromPoints } from "./geometry";
import { EditorModel, TOOLS, TOOL_KEY, TOOL_KIND } from "./model";
import {
  FONT_FAMILY, annotationBounds, annotationRect, distanceToSegment, drawAll, fontSize, frameBackgroundPath, lineWidth, measureText, rgbaCss, luminance,
} from "./renderer";

export const CANVAS_BG = "rgb(27, 27, 29)";
const ACCENT = "#0a84ff";

type Handle = "topLeft" | "top" | "topRight" | "right" | "bottomRight" | "bottom" | "bottomLeft" | "left" | "start" | "end";

type Drag =
  | { t: "none" }
  | { t: "create"; id: string }
  | { t: "move"; id: string; last: Point; moved: boolean }
  | { t: "resize"; id: string; handle: Handle; anchor: Point }
  | { t: "cropNew"; origin: Point }
  | { t: "cropMove"; last: Point }
  | { t: "cropResize"; handle: Handle; original: Rect };

export interface CanvasActions {
  /** Esc ohne Auswahl: Fenster schließen. */
  close: () => void;
}

export class CanvasController {
  private ctx: CanvasRenderingContext2D;
  private w = 0;
  private h = 0;
  private dpr = 1;
  private drag: Drag = { t: "none" };
  private rawRedaction: { start: Point; end: Point } | null = null;
  private editingID: string | null = null;
  private input: HTMLInputElement | null = null;
  private spaceHeld = false;
  private panning: Point | null = null;
  private mouse: Point | null = null;
  private raf = 0;
  private disposers: (() => void)[] = [];

  constructor(readonly canvas: HTMLCanvasElement, readonly host: HTMLElement, readonly model: EditorModel, private actions: CanvasActions) {
    this.ctx = canvas.getContext("2d")!;
    model.commitPendingEdits = () => this.commitPendingEdits();
    const on = (t: EventTarget, type: string, fn: (e: any) => void, opts?: AddEventListenerOptions) => {
      t.addEventListener(type, fn, opts);
      this.disposers.push(() => t.removeEventListener(type, fn, opts));
    };
    on(canvas, "mousedown", (e) => this.mouseDown(e));
    on(window, "mousemove", (e) => this.mouseMove(e));
    on(window, "mouseup", (e) => this.mouseUp(e));
    on(canvas, "wheel", (e) => this.wheel(e), { passive: false });
    on(window, "keydown", (e) => this.keyDown(e));
    on(window, "keyup", (e) => this.keyUp(e));
    const ro = new ResizeObserver(() => this.resize());
    ro.observe(host);
    this.disposers.push(() => ro.disconnect());
    this.disposers.push(model.subscribe(() => this.invalidate()));
    this.resize();
  }

  dispose() {
    cancelAnimationFrame(this.raf);
    this.disposers.forEach((d) => d());
  }

  resize() {
    const r = this.host.getBoundingClientRect();
    this.w = Math.max(1, r.width);
    this.h = Math.max(1, r.height);
    this.dpr = window.devicePixelRatio || 1;
    this.canvas.width = Math.round(this.w * this.dpr);
    this.canvas.height = Math.round(this.h * this.dpr);
    this.canvas.style.width = `${this.w}px`;
    this.canvas.style.height = `${this.h}px`;
    this.clampCenter();
    this.updateZoomPercent();
    this.invalidate();
  }

  invalidate() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      this.draw();
    });
  }

  // ------------------------------------------------------------ Geometrie

  private get m() {
    return this.model;
  }
  private get viewport(): Rect {
    return this.m.tool === "crop" ? this.m.fullRect : this.m.crop ?? this.m.fullRect;
  }
  private get framePadding() {
    const f = this.m.frame;
    return f && this.m.tool !== "crop" ? f.padding * this.m.scale : 0;
  }
  private get fitScale() {
    const vp = insetBy(this.viewport, -this.framePadding, -this.framePadding);
    const pad = 32;
    const s = Math.min((this.w - 2 * pad) / vp.width, (this.h - 2 * pad) / vp.height);
    // Höchstens 1:1 in Punkten — ein Retina-Screenshot erscheint so groß wie auf dem Bildschirm.
    return Math.max(0.02, Math.min(s, 1 / this.m.scale));
  }
  get scaleFactor() {
    return this.m.zoom ?? this.fitScale;
  }
  private get origin(): Point {
    const vp = this.viewport, s = this.scaleFactor;
    if (this.m.zoom === null) return { x: Math.round((this.w - vp.width * s) / 2), y: Math.round((this.h - vp.height * s) / 2) };
    const c = this.m.zoomCenter;
    return { x: Math.round(this.w / 2 - (c.x - vp.x) * s), y: Math.round(this.h / 2 - (c.y - vp.y) * s) };
  }
  private toImage(p: Point): Point {
    const s = this.scaleFactor, o = this.origin, vp = this.viewport;
    return { x: (p.x - o.x) / s + vp.x, y: (p.y - o.y) / s + vp.y };
  }
  private toView(p: Point): Point {
    const s = this.scaleFactor, o = this.origin, vp = this.viewport;
    return { x: (p.x - vp.x) * s + o.x, y: (p.y - vp.y) * s + o.y };
  }
  private toViewRect(r: Rect): Rect {
    const a = this.toView({ x: r.x, y: r.y }), s = this.scaleFactor;
    return { x: a.x, y: a.y, width: r.width * s, height: r.height * s };
  }

  // ------------------------------------------------------------ Zoom

  zoomIn() { this.setZoom(this.scaleFactor * 1.25, null); }
  zoomOut() { this.setZoom(this.scaleFactor / 1.25, null); }
  zoomToFit() { this.setZoom(null, null); }
  /** 100 % = ein Bildpunkt pro Bildschirmpunkt, also so groß wie beim Aufnehmen. */
  zoomActualSize() { this.setZoom(1 / this.m.scale, null); }

  private setZoom(value: number | null, anchor: Point | null) {
    this.commitPendingEdits();
    if (value === null || !(value > this.fitScale * 1.01)) {
      this.m.zoom = null;
      this.updateZoomPercent();
      this.m.notify();
      return;
    }
    const z = Math.min(value, 8);
    const av = anchor ?? { x: this.w / 2, y: this.h / 2 };
    const ai = this.toImage(av);
    this.m.zoom = z;
    this.m.zoomCenter = { x: ai.x - (av.x - this.w / 2) / z, y: ai.y - (av.y - this.h / 2) / z };
    this.clampCenter();
    this.updateZoomPercent();
    this.m.notify();
  }

  private clampCenter() {
    const z = this.m.zoom;
    if (z === null) return;
    const vp = this.viewport;
    const halfW = this.w / 2 / z, halfH = this.h / 2 / z;
    const c = this.m.zoomCenter;
    this.m.zoomCenter = {
      x: vp.width <= 2 * halfW ? midX(vp) : Math.max(vp.x + halfW - 40 / z, Math.min(c.x, maxX(vp) - halfW + 40 / z)),
      y: vp.height <= 2 * halfH ? midY(vp) : Math.max(vp.y + halfH - 40 / z, Math.min(c.y, maxY(vp) - halfH + 40 / z)),
    };
  }

  private pan(dx: number, dy: number) {
    const z = this.m.zoom;
    if (z === null) return;
    this.m.zoomCenter = { x: this.m.zoomCenter.x - dx / z, y: this.m.zoomCenter.y - dy / z };
    this.clampCenter();
    this.m.notify();
  }

  private updateZoomPercent() {
    const p = Math.round(this.scaleFactor * this.m.scale * 100);
    if (this.m.zoomPercent !== p) {
      this.m.zoomPercent = p;
      queueMicrotask(() => this.m.notify());
    }
  }

  private wheel(e: WheelEvent) {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      const delta = (-e.deltaY * (e.deltaMode === 0 ? 0.01 : 0.1)) * (e.deltaMode === 0 && Math.abs(e.deltaY) >= 50 ? 0.4 : 1);
      this.setZoom(this.scaleFactor * (1 + delta), this.local(e));
    } else if (this.m.zoom !== null) {
      e.preventDefault();
      const f = e.deltaMode === 0 ? 1 : 16;
      this.pan(-e.deltaX * f, -e.deltaY * f);
    }
  }

  private local(e: MouseEvent): Point {
    const r = this.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  // ------------------------------------------------------------ Zeichnen

  draw() {
    const { ctx, m } = this;
    const dpr = this.dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = CANVAS_BG;
    ctx.fillRect(0, 0, this.w, this.h);
    this.updateZoomPercent();

    const vp = this.viewport, s = this.scaleFactor;
    const imageRect = this.toViewRect(vp);
    let radius = 0;
    const f = m.frame && m.tool !== "crop" ? m.frame : null;
    if (f) {
      // Vorschau des Rahmens: Verlauf, Schatten, runde Ecken — wie im gespeicherten Bild.
      const pad = this.framePadding * s;
      frameBackgroundPath(ctx, f, insetBy(imageRect, -pad, -pad));
      radius = Math.min(f.cornerRadius * m.scale * s, Math.min(imageRect.width, imageRect.height) / 2);
      if (f.shadow) {
        ctx.save();
        ctx.shadowColor = "rgba(0,0,0,0.35)";
        ctx.shadowOffsetY = 10 * m.scale * s * dpr;
        ctx.shadowBlur = 32 * m.scale * s * dpr;
        ctx.fillStyle = "#fff";
        ctx.beginPath();
        ctx.roundRect(imageRect.x, imageRect.y, imageRect.width, imageRect.height, radius);
        ctx.fill();
        ctx.restore();
      }
    } else {
      ctx.save();
      ctx.shadowColor = "rgba(0,0,0,0.55)";
      ctx.shadowOffsetY = 6 * dpr;
      ctx.shadowBlur = 24 * dpr;
      ctx.fillStyle = "#000";
      ctx.fillRect(imageRect.x, imageRect.y, imageRect.width, imageRect.height);
      ctx.restore();
    }

    ctx.save();
    ctx.beginPath();
    ctx.roundRect(imageRect.x, imageRect.y, imageRect.width, imageRect.height, radius);
    ctx.clip();
    const o = this.origin;
    ctx.translate(o.x, o.y);
    ctx.scale(s, s);
    ctx.translate(-vp.x, -vp.y);
    ctx.imageSmoothingEnabled = s < 1;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(m.base as CanvasImageSource, 0, 0);
    drawAll(ctx, m.annotations, m.scale, m.effects, this.editingID, s * dpr);
    ctx.restore();

    if (m.tool === "crop") this.drawCropOverlay(imageRect);
    else if (m.selected && this.editingID === null) this.drawSelection(m.selected);
  }

  private drawSelection(a: Annotation) {
    const { ctx } = this;
    const box = insetBy(this.toViewRect(annotationBounds(a, this.m.scale)), -4, -4);
    ctx.save();
    ctx.strokeStyle = ACCENT;
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 3]);
    if (a.kind !== "arrow" && a.kind !== "line") ctx.strokeRect(box.x + 0.5, box.y + 0.5, box.width, box.height);
    ctx.restore();
    for (const [, p] of this.handles(a)) this.drawHandle(p);
  }

  private drawHandle(p: Point) {
    const { ctx } = this;
    ctx.beginPath();
    ctx.arc(p.x, p.y, 5, 0, Math.PI * 2);
    ctx.fillStyle = "#fff";
    ctx.fill();
    ctx.strokeStyle = ACCENT;
    ctx.lineWidth = 1.5;
    ctx.stroke();
  }

  private drawCropOverlay(imageRect: Rect) {
    const { ctx } = this;
    const draft = this.m.cropDraft;
    if (!draft) return;
    const r = this.toViewRect(draft);
    ctx.save();
    ctx.beginPath();
    ctx.rect(imageRect.x, imageRect.y, imageRect.width, imageRect.height);
    ctx.rect(r.x, r.y, r.width, r.height);
    ctx.fillStyle = "rgba(0,0,0,0.55)";
    ctx.fill("evenodd");
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 1.5;
    ctx.strokeRect(r.x, r.y, r.width, r.height);
    ctx.strokeStyle = "rgba(255,255,255,0.35)";
    ctx.lineWidth = 0.5;
    ctx.beginPath();
    for (let i = 1; i <= 2; i++) {
      const x = r.x + (r.width * i) / 3, y = r.y + (r.height * i) / 3;
      ctx.moveTo(x, r.y); ctx.lineTo(x, maxY(r));
      ctx.moveTo(r.x, y); ctx.lineTo(maxX(r), y);
    }
    ctx.stroke();
    ctx.restore();
    ctx.fillStyle = "#fff";
    for (const [, p] of this.cropHandles(r)) ctx.fillRect(p.x - 4, p.y - 4, 8, 8);
    const label = `${Math.trunc(draft.width)} × ${Math.trunc(draft.height)}`;
    ctx.font = `600 11px ${FONT_FAMILY}`;
    const tw = ctx.measureText(label).width, th = 14;
    const bg = { x: midX(r) - tw / 2 - 8, y: Math.max(4, r.y - th - 12), width: tw + 16, height: th + 6 };
    ctx.fillStyle = "rgba(0,0,0,0.7)";
    ctx.beginPath();
    ctx.roundRect(bg.x, bg.y, bg.width, bg.height, bg.height / 2);
    ctx.fill();
    ctx.fillStyle = "#fff";
    ctx.textBaseline = "middle";
    ctx.fillText(label, bg.x + 8, bg.y + bg.height / 2 + 0.5);
    ctx.textBaseline = "alphabetic";
  }

  // ------------------------------------------------------------ Griffe

  private handles(a: Annotation): [Handle, Point][] {
    if (a.kind === "arrow" || a.kind === "line") return [["start", this.toView(a.start)], ["end", this.toView(a.end)]];
    if (!(a.kind === "rectangle" || a.kind === "ellipse" || a.kind === "highlight" || a.kind === "redact")) return [];
    const r = this.toViewRect(annotationRect(a));
    return [["topLeft", { x: r.x, y: r.y }], ["topRight", { x: maxX(r), y: r.y }], ["bottomLeft", { x: r.x, y: maxY(r) }], ["bottomRight", { x: maxX(r), y: maxY(r) }]];
  }

  private cropHandles(r: Rect): [Handle, Point][] {
    return [
      ["topLeft", { x: r.x, y: r.y }], ["top", { x: midX(r), y: r.y }], ["topRight", { x: maxX(r), y: r.y }], ["right", { x: maxX(r), y: midY(r) }],
      ["bottomRight", { x: maxX(r), y: maxY(r) }], ["bottom", { x: midX(r), y: maxY(r) }], ["bottomLeft", { x: r.x, y: maxY(r) }], ["left", { x: r.x, y: midY(r) }],
    ];
  }

  private handleHit(vp: Point, list: [Handle, Point][]): Handle | null {
    return list.find(([, p]) => Math.hypot(p.x - vp.x, p.y - vp.y) <= 8)?.[0] ?? null;
  }

  /** Oberste Anmerkung unter dem Punkt (Bildkoordinaten). */
  private annotationAt(p: Point): Annotation | null {
    const tol = 6 / this.scaleFactor;
    const all = this.m.annotations;
    const ordered = [...all.filter((a) => a.kind !== "redact"), ...all.filter((a) => a.kind === "redact")];
    for (const a of ordered.reverse()) {
      switch (a.kind) {
        case "arrow":
        case "line":
          if (distanceToSegment(p, a.start, a.end) <= Math.max(tol, lineWidth(a, this.m.scale))) return a;
          break;
        case "rectangle":
        case "ellipse": {
          const r = annotationRect(a);
          if (a.filled) {
            if (contains(insetBy(r, -tol, -tol), p)) return a;
          } else {
            const lw = lineWidth(a, this.m.scale);
            if (contains(insetBy(r, -tol, -tol), p) && !contains(insetBy(r, tol + lw, tol + lw), p)) return a;
          }
          break;
        }
        default:
          if (contains(insetBy(annotationBounds(a, this.m.scale), -tol, -tol), p)) return a;
      }
    }
    return null;
  }

  // ------------------------------------------------------------ Maus

  private mouseDown(e: MouseEvent) {
    if (e.button !== 0) return;
    if (this.editingID) this.endTextEditing();
    const vp = this.local(e);
    if (this.spaceHeld && this.m.zoom !== null) {
      this.panning = vp;
      this.canvas.style.cursor = "grabbing";
      return;
    }
    const p = this.toImage(vp);
    const m = this.m;
    if (m.tool === "crop") {
      this.beginCropDrag(vp, p);
      return;
    }
    const sel = m.selected;
    if (sel) {
      const h = this.handleHit(vp, this.handles(sel));
      if (h) {
        m.checkpoint();
        let anchor: Point;
        if (h === "start") anchor = sel.end;
        else if (h === "end") anchor = sel.start;
        else {
          const r = annotationRect(sel);
          if (h === "topLeft") anchor = { x: maxX(r), y: maxY(r) };
          else if (h === "topRight") anchor = { x: r.x, y: maxY(r) };
          else if (h === "bottomLeft") anchor = { x: maxX(r), y: r.y };
          else anchor = { x: r.x, y: r.y };
        }
        this.drag = { t: "resize", id: sel.id, handle: h, anchor };
        return;
      }
    }
    const hit = this.annotationAt(p);
    const grabs = hit && (m.tool === "select" || hit.id === m.selectedID || (m.tool === "text" && hit.kind === "text"));
    if (hit && grabs) {
      m.select(hit.id);
      if (e.detail === 2 && hit.kind === "text") {
        this.beginTextEditing(hit.id);
        return;
      }
      this.drag = { t: "move", id: hit.id, last: p, moved: false };
      return;
    }
    m.select(null);
    const kind = TOOL_KIND[m.tool];
    if (!kind) {
      this.drag = { t: "none" };
      return;
    }
    if (kind === "text") {
      m.checkpoint();
      const a = m.makeAnnotation("text", p);
      a.start.y -= fontSize(a, m.scale) * 0.6;
      m.add(a);
      m.select(a.id);
      this.beginTextEditing(a.id, true);
      this.drag = { t: "none" };
    } else if (kind === "counter") {
      m.checkpoint();
      const a = m.makeAnnotation("counter", p);
      m.add(a);
      m.select(a.id);
      this.drag = { t: "move", id: a.id, last: p, moved: true };
    } else {
      m.checkpoint();
      const a = m.makeAnnotation(kind, p);
      m.add(a);
      if (kind === "redact") this.rawRedaction = { start: p, end: p };
      this.drag = { t: "create", id: a.id };
    }
    e.preventDefault();
  }

  private mouseMove(e: MouseEvent) {
    const vp = this.local(e);
    this.mouse = vp;
    if (this.panning) {
      this.pan(vp.x - this.panning.x, vp.y - this.panning.y);
      this.panning = vp;
      return;
    }
    if (this.drag.t === "none") {
      if (e.target === this.canvas) this.updateCursor(vp);
      return;
    }
    let p = this.toImage(vp);
    const m = this.m;
    const d = this.drag;
    switch (d.t) {
      case "create": {
        const a = m.annotations.find((x) => x.id === d.id);
        if (!a) return;
        if (a.kind === "redact" && this.rawRedaction) {
          this.rawRedaction.end = p;
          const drawn = rectFromPoints(this.rawRedaction.start, p);
          // Alt beim Ziehen: exakt wie gezogen, ohne Anpassen an Wörter.
          const r = e.altKey ? drawn : m.snappedRedaction(drawn);
          m.update(d.id, (x) => { x.start = { x: r.x, y: r.y }; x.end = { x: maxX(r), y: maxY(r) }; });
          return;
        }
        if (e.shiftKey) p = this.constrain(p, a.start, a.kind === "arrow" || a.kind === "line");
        m.update(d.id, (x) => (x.end = p));
        break;
      }
      case "move": {
        const dx = p.x - d.last.x, dy = p.y - d.last.y;
        if (!d.moved) m.checkpoint();
        m.update(d.id, (a) => offset(a, dx, dy));
        this.drag = { t: "move", id: d.id, last: p, moved: true };
        break;
      }
      case "resize": {
        if (e.shiftKey) p = this.constrain(p, d.anchor, d.handle === "start" || d.handle === "end");
        m.update(d.id, (a) => {
          if (d.handle === "start") a.start = p;
          else if (d.handle === "end") a.end = p;
          else { a.start = d.anchor; a.end = p; }
        });
        break;
      }
      case "cropNew":
        m.cropDraft = intersection(rectFromPoints(d.origin, p), m.fullRect);
        m.notify();
        break;
      case "cropMove": {
        const r = { ...m.cropDraft! };
        r.x += p.x - d.last.x;
        r.y += p.y - d.last.y;
        r.x = Math.max(0, Math.min(r.x, m.fullRect.width - r.width));
        r.y = Math.max(0, Math.min(r.y, m.fullRect.height - r.height));
        m.cropDraft = r;
        this.drag = { t: "cropMove", last: p };
        m.notify();
        break;
      }
      case "cropResize": {
        let x0 = d.original.x, y0 = d.original.y, x1 = maxX(d.original), y1 = maxY(d.original);
        const h = d.handle;
        if (h === "topLeft" || h === "left" || h === "bottomLeft") x0 = p.x;
        if (h === "topRight" || h === "right" || h === "bottomRight") x1 = p.x;
        if (h === "topLeft" || h === "top" || h === "topRight") y0 = p.y;
        if (h === "bottomLeft" || h === "bottom" || h === "bottomRight") y1 = p.y;
        m.cropDraft = intersection({ x: Math.min(x0, x1), y: Math.min(y0, y1), width: Math.abs(x1 - x0), height: Math.abs(y1 - y0) }, m.fullRect);
        m.notify();
        break;
      }
    }
  }

  private mouseUp(e: MouseEvent) {
    if (this.panning) {
      this.panning = null;
      this.canvas.style.cursor = "grab";
      return;
    }
    const d = this.drag;
    const m = this.m;
    if (d.t === "create") {
      const a = m.annotations.find((x) => x.id === d.id);
      if (a) {
        const lineLike = a.kind === "arrow" || a.kind === "line";
        const r = annotationRect(a), s = this.scaleFactor;
        const tooSmall = lineLike ? Math.hypot(a.end.x - a.start.x, a.end.y - a.start.y) * s < 6 : r.width * s < 4 || r.height * s < 4;
        const start = this.rawRedaction?.start;
        const target = tooSmall && a.kind === "redact" && start ? m.textTarget(start, e.altKey) : null;
        if (target) {
          // Klick auf Text: Balken über Zeile bzw. Wort.
          m.update(d.id, (x) => { x.start = { x: target.x, y: target.y }; x.end = { x: maxX(target), y: maxY(target) }; });
          m.select(d.id);
        } else if (tooSmall) {
          m.remove(d.id);
          m.dropCheckpoint();
        } else m.select(d.id);
      }
    }
    this.drag = { t: "none" };
    this.rawRedaction = null;
    this.invalidate();
  }

  private beginCropDrag(vp: Point, p: Point) {
    const draft = this.m.cropDraft;
    if (!draft) return;
    const r = this.toViewRect(draft);
    const h = this.handleHit(vp, this.cropHandles(r));
    if (h) this.drag = { t: "cropResize", handle: h, original: draft };
    else if (contains(r, vp)) this.drag = { t: "cropMove", last: p };
    else {
      const f = this.m.fullRect;
      this.drag = { t: "cropNew", origin: { x: Math.max(0, Math.min(p.x, maxX(f))), y: Math.max(0, Math.min(p.y, maxY(f))) } };
    }
  }

  /** Shift: Linien auf 45°-Schritte, Rechtecke quadratisch. */
  private constrain(p: Point, o: Point, lineLike: boolean): Point {
    const dx = p.x - o.x, dy = p.y - o.y;
    if (lineLike) {
      const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
      const len = Math.hypot(dx, dy);
      return { x: o.x + Math.cos(angle) * len, y: o.y + Math.sin(angle) * len };
    }
    const side = Math.max(Math.abs(dx), Math.abs(dy));
    return { x: o.x + (dx < 0 ? -side : side), y: o.y + (dy < 0 ? -side : side) };
  }

  // ------------------------------------------------------------ Tastatur

  private typing(e: KeyboardEvent) {
    const t = e.target as HTMLElement | null;
    return !!t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA");
  }

  private keyUp(e: KeyboardEvent) {
    if (e.code === "Space") {
      this.spaceHeld = false;
      if (this.mouse) this.updateCursor(this.mouse);
    }
  }

  private keyDown(e: KeyboardEvent) {
    if (this.typing(e)) return;
    const m = this.m;
    const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && !e.altKey) {
      switch (e.key) {
        case "+": case "=": e.preventDefault(); this.zoomIn(); return;
        case "-": e.preventDefault(); this.zoomOut(); return;
        case "0": e.preventDefault(); this.zoomToFit(); return;
        case "1": e.preventDefault(); this.zoomActualSize(); return;
      }
      return;
    }
    if (e.code === "Space") {
      e.preventDefault();
      if (!this.spaceHeld && m.zoom !== null) this.canvas.style.cursor = "grab";
      this.spaceHeld = true;
      return;
    }
    switch (e.key) {
      case "Backspace":
      case "Delete":
        m.deleteSelection();
        return;
      case "Escape":
        if (m.tool === "crop") m.cancelCrop();
        else if (m.selectedID) m.select(null);
        else this.actions.close();
        return;
      case "Enter":
        if (m.tool === "crop") { m.applyCrop(); return; }
        if (m.selected?.kind === "text") { e.preventDefault(); this.beginTextEditing(m.selected.id); return; }
        break;
      case "ArrowLeft": case "ArrowRight": case "ArrowDown": case "ArrowUp": {
        const id = m.selectedID;
        if (!id) break;
        e.preventDefault();
        const step = e.shiftKey ? 10 * m.scale : m.scale;
        const dx = e.key === "ArrowLeft" ? -step : e.key === "ArrowRight" ? step : 0;
        const dy = e.key === "ArrowDown" ? step : e.key === "ArrowUp" ? -step : 0;
        if (!e.repeat) m.checkpoint();
        m.update(id, (a) => offset(a, dx, dy));
        return;
      }
    }
    if (!e.altKey) {
      const tool = TOOLS.find((t) => TOOL_KEY[t] === e.key.toLowerCase());
      if (tool && e.key.length === 1) {
        if (tool === "crop") m.startCrop();
        else m.tool = tool;
      }
    }
  }

  // ------------------------------------------------------------ Cursor

  private updateCursor(vp: Point) {
    const c = this.canvas.style;
    const m = this.m;
    if (this.spaceHeld && m.zoom !== null) { c.cursor = "grab"; return; }
    if (m.tool === "crop") {
      c.cursor = m.cropDraft && contains(this.toViewRect(m.cropDraft), vp) ? "grab" : "crosshair";
      return;
    }
    const sel = m.selected;
    if (sel && this.handleHit(vp, this.handles(sel))) { c.cursor = "pointer"; return; }
    const hit = this.annotationAt(this.toImage(vp));
    if (hit && (m.tool === "select" || hit.id === m.selectedID)) { c.cursor = "grab"; return; }
    c.cursor = m.tool === "select" ? "default" : m.tool === "text" ? "text" : "crosshair";
  }

  // ------------------------------------------------------------ Text

  private beginTextEditing(id: string, isNew = false) {
    const a = this.m.annotations.find((x) => x.id === id);
    if (!a) return;
    this.editingID = id;
    const input = document.createElement("input");
    input.type = "text";
    input.value = a.text;
    const px = fontSize(a, this.m.scale) * this.scaleFactor;
    Object.assign(input.style, {
      position: "absolute",
      font: `700 ${px}px ${FONT_FAMILY}`,
      color: rgbaCss(a.color),
      background: luminance(a.color) > 0.75 ? "rgba(51,51,51,0.9)" : "rgba(255,255,255,0.9)",
      border: "0",
      outline: "none",
      padding: "0 6px",
      margin: "0",
      userSelect: "text",
      webkitUserSelect: "text",
      cursor: "text",
      boxSizing: "content-box",
    });
    const o = this.toView(a.start);
    input.style.left = `${o.x - 6}px`;
    input.style.top = `${o.y}px`;
    const fit = () => {
      const t = input.value === "" ? "Text" : input.value + " ";
      const mm = measureText(t, px);
      input.style.width = `${Math.ceil(mm.width)}px`;
      input.style.height = `${Math.ceil(mm.height) + 4}px`;
    };
    fit();
    input.addEventListener("input", fit);
    input.addEventListener("keydown", (ev) => {
      ev.stopPropagation();
      if (ev.key === "Enter" || ev.key === "Escape") {
        ev.preventDefault();
        this.endTextEditing();
      }
    });
    input.addEventListener("blur", () => this.endTextEditing());
    this.host.appendChild(input);
    this.input = input;
    (input as HTMLInputElement & { _new?: boolean })._new = isNew;
    input.focus();
    input.select();
    this.invalidate();
  }

  private endTextEditing() {
    const id = this.editingID, input = this.input;
    if (!id || !input) return;
    this.editingID = null;
    this.input = null;
    const text = input.value.trim();
    const wasNew = (input as HTMLInputElement & { _new?: boolean })._new;
    input.remove();
    const m = this.m;
    const a = m.annotations.find((x) => x.id === id);
    if (text === "") {
      if (a) {
        // Neuer, leerer Text: der Checkpoint vom Anlegen war umsonst.
        if (wasNew && a.text === "") m.dropCheckpoint();
        else if (a.text !== "") m.checkpoint();
        m.remove(id);
      }
      m.select(null);
    } else {
      if (a && a.text !== "" && a.text !== text) m.checkpoint();
      m.update(id, (x) => (x.text = text));
      m.select(id);
    }
    this.invalidate();
  }

  commitPendingEdits() {
    if (this.editingID) this.endTextEditing();
  }
}

function offset(a: Annotation, dx: number, dy: number) {
  a.start = { x: a.start.x + dx, y: a.start.y + dy };
  a.end = { x: a.end.x + dx, y: a.end.y + dy };
}
