// Port von Editor/EditorModel.swift: Zustand des Bild-Editors (Anmerkungen, Zuschnitt, Rahmen, Undo, Zoom).
import { useSyncExternalStore } from "react";
import { api } from "../shared/ipc";
import type { Annotation, AnnotationKind, EditorSession, EditorTool, FrameStyle, ImageDocument, Point, Rect, RedactStyle, Rgba, Settings, StrokeSize, TextLine } from "../shared/types";
import { area, contains, insetBy, integral, intersection, intersects, maxX, maxY, rectEq, union } from "./geometry";
import { COLORS, DEFAULT_FRAME, EffectsCache, imageSize, sameColor, type BaseImage } from "./renderer";
import { visibleText } from "./text";

export const TOOLS: EditorTool[] = ["select", "arrow", "rectangle", "ellipse", "line", "text", "counter", "highlight", "redact", "crop"];
export const TOOL_TITLE: Record<EditorTool, string> = {
  select: "Auswählen", arrow: "Pfeil", rectangle: "Rechteck", ellipse: "Ellipse", line: "Linie", text: "Text",
  counter: "Nummerierung", highlight: "Markieren", redact: "Zensieren", crop: "Zuschneiden",
};
export const TOOL_KEY: Record<EditorTool, string> = {
  select: "v", arrow: "a", rectangle: "r", ellipse: "o", line: "l", text: "t", counter: "n", highlight: "h", redact: "x", crop: "c",
};
export const TOOL_KIND: Partial<Record<EditorTool, AnnotationKind>> = {
  arrow: "arrow", rectangle: "rectangle", ellipse: "ellipse", line: "line", text: "text", counter: "counter", highlight: "highlight", redact: "redact",
};
export const REDACT_STYLES: RedactStyle[] = ["pixelate", "blur", "solid"];
export const REDACT_TITLE: Record<RedactStyle, string> = { pixelate: "Verpixeln", blur: "Unschärfe", solid: "Balken" };
const KIND_TITLE: Record<string, string> = { email: "E-Mail", iban: "IBAN", phone: "Telefon", card: "Karte", secret: "Schlüssel", ip: "IP" };

interface Snapshot {
  annotations: Annotation[];
  crop: Rect | null;
  frame: FrameStyle | null;
}

export const newId = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`);

export class EditorModel {
  readonly item;
  readonly scale: number;
  readonly effects: EffectsCache;
  readonly width: number;
  readonly height: number;

  annotations: Annotation[];
  crop: Rect | null;
  cropDraft: Rect | null = null;
  frame: FrameStyle | null;
  private _tool: EditorTool;
  color: Rgba;
  size: StrokeSize;
  redactStyle: RedactStyle;
  filled = false;
  selectedID: string | null = null;
  dirty = false;
  busy: string | null = null;
  toast: string | null = null;
  canUndo = false;
  canRedo = false;
  /** Zoom in Ansichtspunkten pro Bildpixel; null = einpassen. */
  zoom: number | null = null;
  zoomCenter: Point = { x: 0, y: 0 };
  /** Anzeige: 100 % = so groß wie auf dem Bildschirm. */
  zoomPercent = 100;
  /** Wird vom Canvas gesetzt, wenn Texteingabe läuft (für Fertig/Kopieren). */
  commitPendingEdits: () => void = () => {};

  textLines: TextLine[] = [];
  textReady = false;
  private textWaiters: (() => void)[] = [];

  private undoStack: Snapshot[] = [];
  private redoStack: Snapshot[] = [];
  private toastTimer: ReturnType<typeof setTimeout> | null = null;
  private toolBeforeCrop: EditorTool = "arrow";
  lastFrame: FrameStyle;
  settings: Settings;

  private listeners = new Set<() => void>();
  version = 0;

  constructor(session: EditorSession, readonly base: BaseImage, settings: Settings) {
    this.item = session.item;
    this.settings = settings;
    this.scale = Math.max(1, session.scale || session.item.scale);
    this.effects = new EffectsCache(base, this.scale);
    const s = imageSize(base);
    this.width = s.w;
    this.height = s.h;
    this.annotations = session.document.annotations.map((a) => ({ ...a }));
    this.crop = session.document.crop;
    this.frame = session.document.frame;
    const p = settings.editor;
    this._tool = session.initialTool && session.initialTool !== "crop" ? session.initialTool : p.tool && p.tool !== "crop" ? p.tool : "redact";
    this.color = p.color ?? COLORS.red;
    this.size = p.size ?? "medium";
    this.redactStyle = settings.redactStyle;
    this.lastFrame = p.lastFrameStyle ?? DEFAULT_FRAME;
    api.editorTextLines(this.item.id)
      .then((l) => this.didRecognize(l ?? []))
      .catch(() => this.didRecognize([]));
  }

  // ---- Abo
  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };
  getVersion = () => this.version;
  notify() {
    this.version++;
    this.listeners.forEach((f) => f());
  }

  // ---- Text
  private didRecognize(lines: TextLine[]) {
    this.textLines = lines;
    this.textReady = true;
    this.textWaiters.forEach((f) => f());
    this.textWaiters = [];
    this.notify();
  }
  waitForText(): Promise<void> {
    return this.textReady ? Promise.resolve() : new Promise((r) => this.textWaiters.push(r));
  }

  /** Wortgenaue Zensur: Jedes Wort, das der Balken in der Höhe deutlich trifft, wird ganz bedeckt. */
  snappedRedaction(r: Rect): Rect {
    const pad = 2 * this.scale;
    let out = r;
    for (const line of this.textLines) {
      if (!intersects(line.rect, r)) continue;
      for (const { rect: w } of line.words) {
        const i = intersection(w, r);
        if (!i) continue;
        if (i.height >= w.height * 0.35 && i.width >= Math.min(w.width * 0.15, 4 * this.scale)) out = union(out, insetBy(w, -pad, -pad));
      }
    }
    return intersection(out, this.fullRect) ?? out;
  }

  /** Klick auf Text: ganze Zeile (oder mit `word` nur das Wort darunter). */
  textTarget(p: Point, word: boolean): Rect | null {
    const pad = 3 * this.scale;
    const line = this.textLines.find((l) => contains(insetBy(l.rect, -pad, -pad), p));
    if (!line) return null;
    if (word) {
      const w = line.words.find((w) => contains(insetBy(w.rect, -pad, -pad), p));
      if (w) return intersection(insetBy(w.rect, -pad, -pad), this.fullRect);
    }
    return intersection(insetBy(line.rect, -pad, -pad * 0.7), this.fullRect);
  }

  /** Text, wie er im gespeicherten Bild steht: ohne Zensiertes und ohne Weggeschnittenes. */
  visibleText(): string {
    const hidden = this.annotations.filter((a) => a.kind === "redact").map((a) => annotationRect(a));
    return visibleText(this.textLines, hidden, this.crop);
  }

  get fullRect(): Rect {
    return { x: 0, y: 0, width: this.width, height: this.height };
  }
  get document(): ImageDocument {
    return { version: 1, annotations: this.annotations, crop: this.crop, frame: this.frame };
  }
  get selected(): Annotation | undefined {
    return this.annotations.find((a) => a.id === this.selectedID);
  }

  // ---- Werkzeug
  get tool() {
    return this._tool;
  }
  set tool(t: EditorTool) {
    const old = this._tool;
    if (t === old) return;
    this._tool = t;
    if (t === "crop" || old === "crop") this.zoom = null;
    if (t === "crop") {
      this.cropDraft = this.crop ?? this.fullRect;
      this.selectedID = null;
    } else if (old === "crop") this.cropDraft = null;
    if (t !== "crop") void api.setEditorPrefs({ tool: t });
    this.notify();
  }

  // ---- Undo
  checkpoint() {
    this.undoStack.push({ annotations: this.annotations.map((a) => ({ ...a })), crop: this.crop, frame: this.frame });
    if (this.undoStack.length > 300) this.undoStack.shift();
    this.redoStack = [];
    this.dirty = true;
    this.refreshUndo();
  }
  /** Verwirft den letzten Checkpoint, wenn die Aktion nichts verändert hat (Klick ohne Ziehen). */
  dropCheckpoint() {
    this.undoStack.pop();
    this.refreshUndo();
  }
  private snap(): Snapshot {
    return { annotations: this.annotations.map((a) => ({ ...a })), crop: this.crop, frame: this.frame };
  }
  undo() {
    const s = this.undoStack.pop();
    if (!s) return;
    this.redoStack.push(this.snap());
    this.restore(s);
  }
  redo() {
    const s = this.redoStack.pop();
    if (!s) return;
    this.undoStack.push(this.snap());
    this.restore(s);
  }
  private restore(s: Snapshot) {
    this.annotations = s.annotations;
    this.crop = s.crop;
    this.frame = s.frame;
    if (this.selectedID && !this.annotations.some((a) => a.id === this.selectedID)) this.selectedID = null;
    this.dirty = true;
    this.refreshUndo();
  }
  private refreshUndo() {
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = this.redoStack.length > 0;
    this.notify();
  }

  // ---- Anmerkungen
  makeAnnotation(kind: AnnotationKind, p: Point): Annotation {
    const a: Annotation = {
      id: newId(), kind, start: { ...p }, end: { ...p }, color: this.color, size: this.size, filled: false,
      text: "", number: 1, redactStyle: "pixelate", auto: false,
    };
    if (kind === "redact") a.redactStyle = this.redactStyle;
    else if (kind === "highlight") {
      if (sameColor(this.color, COLORS.red)) a.color = COLORS.yellow;
    } else if (kind === "counter") a.number = this.nextCounterNumber();
    else if (kind === "rectangle" || kind === "ellipse") a.filled = this.filled;
    return a;
  }
  nextCounterNumber() {
    return Math.max(0, ...this.annotations.filter((a) => a.kind === "counter").map((a) => a.number)) + 1;
  }
  update(id: string, change: (a: Annotation) => void) {
    const a = this.annotations.find((x) => x.id === id);
    if (!a) return;
    change(a);
    this.dirty = true;
    this.notify();
  }
  add(a: Annotation) {
    this.annotations.push(a);
    this.dirty = true;
    this.notify();
  }
  remove(id: string) {
    this.annotations = this.annotations.filter((a) => a.id !== id);
    if (this.selectedID === id) this.selectedID = null;
    this.dirty = true;
    this.notify();
  }
  select(id: string | null) {
    this.selectedID = id;
    this.notify();
  }
  deleteSelection() {
    if (!this.selectedID) return;
    this.checkpoint();
    this.remove(this.selectedID);
  }

  // ---- Stil (wirkt auch auf die Auswahl)
  setColor(c: Rgba) {
    this.color = c;
    void api.setEditorPrefs({ color: c });
    const sel = this.selected;
    if (sel && sel.kind !== "redact") {
      this.checkpoint();
      this.update(sel.id, (a) => (a.color = c));
    }
    this.notify();
  }
  setSize(s: StrokeSize) {
    this.size = s;
    void api.setEditorPrefs({ size: s });
    const sel = this.selected;
    if (sel && sel.kind !== "redact" && sel.kind !== "highlight") {
      this.checkpoint();
      this.update(sel.id, (a) => (a.size = s));
    }
    this.notify();
  }
  setRedactStyle(style: RedactStyle) {
    this.redactStyle = style;
    void api.setSettings({ redactStyle: style });
    const sel = this.selected;
    if (sel?.kind === "redact") {
      this.checkpoint();
      this.update(sel.id, (a) => (a.redactStyle = style));
    }
    this.notify();
  }
  setFilled(v: boolean) {
    this.filled = v;
    const sel = this.selected;
    if (sel && (sel.kind === "rectangle" || sel.kind === "ellipse")) {
      this.checkpoint();
      this.update(sel.id, (a) => (a.filled = v));
    }
    this.notify();
  }
  setFrame(style: FrameStyle | null) {
    if (JSON.stringify(style) === JSON.stringify(this.frame)) return;
    this.checkpoint();
    this.frame = style;
    if (style) {
      this.lastFrame = style;
      void api.setEditorPrefs({ lastFrameStyle: style });
    }
    this.notify();
  }

  // ---- Zuschneiden
  applyCrop() {
    const d = this.cropDraft ? intersection(integral(this.cropDraft), this.fullRect) : null;
    if (!d || d.width < 4 || d.height < 4) {
      this.tool = this.toolBeforeCrop;
      return;
    }
    const full = rectEq(d, this.fullRect);
    const next = full ? null : d;
    if (!rectEq(next, this.crop)) {
      this.checkpoint();
      this.crop = next;
    }
    this.tool = this.toolBeforeCrop;
  }
  cancelCrop() {
    this.tool = this.toolBeforeCrop;
  }
  startCrop() {
    if (this._tool !== "crop") this.toolBeforeCrop = this._tool;
    this.tool = "crop";
  }
  resetCrop() {
    this.cropDraft = this.fullRect;
    this.notify();
  }

  // ---- Auto-Zensur
  async autoRedact() {
    if (this.busy) return;
    this.busy = "Suche nach sensiblen Daten …";
    this.notify();
    let findings: Awaited<ReturnType<typeof api.editorDetect>> = [];
    try {
      findings = (await api.editorDetect(this.item.id, this.settings.autoRedactKinds)) ?? [];
    } finally {
      this.busy = null;
    }
    const existing = this.annotations.filter((a) => a.kind === "redact").map(annotationRect);
    const fresh = findings.filter((f) => !existing.some((e) => area(intersection(e, f.rect)) > area(f.rect) * 0.6));
    if (fresh.length === 0) {
      this.showToast(findings.length === 0 ? "Nichts Sensibles gefunden" : "Schon alles zensiert");
      return;
    }
    this.checkpoint();
    for (const f of fresh) {
      const r = intersection(insetBy(f.rect, -3 * this.scale, -2 * this.scale), this.fullRect) ?? f.rect;
      const a = this.makeAnnotation("redact", { x: r.x, y: r.y });
      a.end = { x: maxX(r), y: maxY(r) };
      a.redactStyle = this.redactStyle;
      a.auto = true;
      this.annotations.push(a);
    }
    const kinds = [...new Set(fresh.map((f) => KIND_TITLE[f.kind] ?? f.kind))].sort().join(", ");
    this.showToast(`${fresh.length} Stelle${fresh.length === 1 ? "" : "n"} zensiert · ${kinds}`);
  }

  showToast(text: string) {
    this.toast = text;
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => {
      this.toast = null;
      this.notify();
    }, 2600);
    this.notify();
  }
}

function annotationRect(a: { start: Point; end: Point }): Rect {
  return { x: Math.min(a.start.x, a.end.x), y: Math.min(a.start.y, a.end.y), width: Math.abs(a.end.x - a.start.x), height: Math.abs(a.end.y - a.start.y) };
}

/** React: bei jeder Änderung des Modells neu rendern. */
export function useModel(m: EditorModel) {
  useSyncExternalStore(m.subscribe, m.getVersion);
  return m;
}
