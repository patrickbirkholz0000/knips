// Zustand und Aktionen des Video-Editors (Gegenstück zu VideoEditorModel.swift).
// Ein kleiner Store statt React-State: Ziehen und Wiedergabe lesen immer den aktuellen Stand.
import { useSyncExternalStore } from "react";
import { api, events, fileUrl } from "../shared/ipc";
import type { CaptureItem, Rect, RedactStyle, SensitiveKind, VideoDocument, VideoRedaction, VideoSession } from "../shared/types";
import { integral, offsetRedaction, rectAt } from "./redact";

export interface VideoState {
  item: CaptureItem;
  currentTime: number;
  isPlaying: boolean;
  trimStart: number;
  trimEnd: number;
  redactions: VideoRedaction[];
  selectedId: string | null;
  style: RedactStyle;
  dirty: boolean;
  busy: string | null;
  progress: number;
  toast: { text: string; error: boolean } | null;
  thumbnails: string[];
  canUndo: boolean;
}

interface Snapshot {
  redactions: VideoRedaction[];
  trimStart: number;
  trimEnd: number;
}

export class VideoModel {
  readonly id: string;
  readonly duration: number;
  readonly videoW: number;
  readonly videoH: number;
  /** Pixel pro Punkt der Aufnahme (Maßstab für Block- und Unschärfegröße). */
  readonly scale: number;
  readonly sourceUrl: string;
  video: HTMLVideoElement | null = null;
  s: VideoState;

  private listeners = new Set<() => void>();
  private undoStack: Snapshot[] = [];
  private toastTimer = 0;
  private cancelled = false;
  private offProgress: Promise<() => void>;

  constructor(session: VideoSession, style: RedactStyle) {
    this.id = session.item.id;
    this.duration = session.info.duration;
    this.videoW = session.info.width;
    this.videoH = session.info.height;
    this.scale = Math.max(1, session.scale);
    this.sourceUrl = fileUrl(session.sourcePath);
    const doc = session.document;
    this.s = {
      item: session.item,
      currentTime: 0,
      isPlaying: false,
      trimStart: Math.max(0, Math.min(doc.trimStart ?? 0, this.duration)),
      trimEnd: Math.min(this.duration, Math.max(doc.trimEnd ?? this.duration, 0)),
      redactions: doc.redactions,
      selectedId: null,
      style,
      dirty: false,
      busy: null,
      progress: 0,
      toast: null,
      thumbnails: [],
      canUndo: false,
    };
    this.s.currentTime = this.s.trimStart;
    this.offProgress = events.videoProgress((p) => {
      if (p.id === this.id && this.s.busy) this.set({ progress: p.progress });
    });
    api
      .videoThumbnails(this.id, 12)
      .then((paths) => this.set({ thumbnails: (paths ?? []).map((p) => fileUrl(p)) }))
      .catch(() => {});
  }

  // ------------------------------------------------------------ Store

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  };
  getSnapshot = () => this.s;

  set(patch: Partial<VideoState>) {
    this.s = { ...this.s, ...patch };
    this.listeners.forEach((fn) => fn());
  }

  shutdown() {
    window.clearTimeout(this.toastTimer);
    this.video?.pause();
    this.offProgress.then((f) => f());
    if (this.s.busy) api.videoCancel(this.id).catch(() => {});
  }

  // ------------------------------------------------------------ Abgeleitetes

  get document(): VideoDocument {
    const { trimStart, trimEnd, redactions } = this.s;
    return {
      version: 1,
      trimStart: trimStart > 0.001 ? trimStart : null,
      trimEnd: trimEnd < this.duration - 0.001 ? trimEnd : null,
      redactions,
    };
  }

  get selected(): VideoRedaction | undefined {
    return this.s.redactions.find((r) => r.id === this.s.selectedId);
  }

  isActive(r: VideoRedaction, t = this.s.currentTime) {
    return t >= r.start - 0.001 && t <= r.end + 0.001;
  }

  // ------------------------------------------------------------ Wiedergabe

  togglePlay() {
    const v = this.video;
    if (!v) return;
    if (this.s.isPlaying) {
      v.pause();
      this.set({ isPlaying: false });
    } else {
      const { currentTime, trimEnd, trimStart } = this.s;
      if (currentTime >= trimEnd - 0.05 || currentTime < trimStart) this.seek(trimStart);
      void v.play().catch(() => this.set({ isPlaying: false }));
      this.set({ isPlaying: true });
    }
  }

  seek(t: number) {
    const clamped = Math.max(0, Math.min(t, this.duration));
    if (this.video) this.video.currentTime = clamped;
    this.set({ currentTime: clamped });
  }

  /** Aus der Abspielschleife: Zeit übernehmen, am Kürzungsende anhalten. */
  tick(t: number) {
    if (this.s.isPlaying && t >= this.s.trimEnd - 0.01) {
      this.video?.pause();
      this.set({ currentTime: t, isPlaying: false });
    } else if (Math.abs(t - this.s.currentTime) > 0.0005) {
      this.set({ currentTime: t });
    }
  }

  // ------------------------------------------------------------ Bearbeiten

  checkpoint() {
    const { redactions, trimStart, trimEnd } = this.s;
    this.undoStack.push({ redactions, trimStart, trimEnd });
    if (this.undoStack.length > 200) this.undoStack.shift();
    this.set({ canUndo: true, dirty: true });
  }

  undo() {
    const last = this.undoStack.pop();
    if (!last) return;
    this.set({ ...last, canUndo: this.undoStack.length > 0, dirty: true });
  }

  setTrim(start?: number, end?: number) {
    let { trimStart, trimEnd } = this.s;
    if (start !== undefined) trimStart = Math.max(0, Math.min(start, trimEnd - 0.2));
    if (end !== undefined) trimEnd = Math.min(this.duration, Math.max(end, trimStart + 0.2));
    this.set({ trimStart, trimEnd, dirty: true });
  }

  /** Neue Felder gelten zunächst für die ganze (gekürzte) Länge — lieber zu viel als zu wenig verdecken. */
  addRedaction(rect: Rect) {
    this.checkpoint();
    const r: VideoRedaction = {
      id: crypto.randomUUID(),
      rect: integral(rect),
      start: this.s.trimStart,
      end: this.s.trimEnd,
      style: this.s.style,
      auto: false,
      track: null,
    };
    this.set({ redactions: [...this.s.redactions, r], selectedId: r.id });
  }

  updateRedaction(id: string, change: (r: VideoRedaction) => VideoRedaction) {
    this.set({ redactions: this.s.redactions.map((r) => (r.id === id ? change(r) : r)), dirty: true });
  }

  moveRedaction(id: string, dx: number, dy: number) {
    const r = this.s.redactions.find((q) => q.id === id);
    if (!r) return;
    // Mitlaufende Balken verschieben sich als Ganzes, begrenzt auf das Bild.
    const x = Math.max(0, Math.min(r.rect.x + dx, this.videoW - r.rect.width)) - r.rect.x;
    const y = Math.max(0, Math.min(r.rect.y + dy, this.videoH - r.rect.height)) - r.rect.y;
    this.updateRedaction(id, (q) => offsetRedaction(q, x, y));
  }

  deleteSelected() {
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    this.set({ redactions: this.s.redactions.filter((r) => r.id !== id), selectedId: null });
  }

  select(id: string | null) {
    if (id !== this.s.selectedId) this.set({ selectedId: id });
  }

  setStyle(style: RedactStyle) {
    this.set({ style });
    void api.setSettings({ redactStyle: style });
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    this.updateRedaction(id, (r) => ({ ...r, style }));
  }

  selectedStartHere() {
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    const t = this.s.currentTime;
    this.updateRedaction(id, (r) => ({ ...r, start: Math.min(t, r.end - 0.05) }));
  }

  selectedEndHere() {
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    const t = this.s.currentTime;
    this.updateRedaction(id, (r) => ({ ...r, end: Math.max(t, r.start + 0.05) }));
  }

  selectedWholeClip() {
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    this.updateRedaction(id, (r) => ({ ...r, start: 0, end: this.duration }));
  }

  // ------------------------------------------------------------ Hintergrundarbeit

  private begin(text: string): boolean {
    if (this.s.busy) return false;
    this.cancelled = false;
    this.set({ busy: text, progress: 0 });
    return true;
  }

  private end() {
    this.set({ busy: null, progress: 0 });
  }

  cancel() {
    this.cancelled = true;
    void api.videoCancel(this.id);
  }

  /** Ausgewählter Balken folgt dem Inhalt (z. B. beim Scrollen) — ab der aktuellen Position vor und zurück. */
  async followSelected() {
    const sel = this.selected;
    if (!sel || !this.begin("Balken folgt dem Inhalt …")) return;
    const t0 = Math.max(sel.start, Math.min(this.s.currentTime, sel.end));
    const rect = rectAt(sel, t0);
    try {
      const points = await api.videoTrack(this.id, rect, t0, sel.start, sel.end);
      this.end();
      this.checkpoint();
      this.updateRedaction(sel.id, (r) => ({ ...r, rect, track: points }));
      this.showToast(`Balken folgt dem Inhalt (${points.length} Positionen)`);
    } catch {
      this.end();
    }
  }

  unfollowSelected() {
    const id = this.s.selectedId;
    if (!id) return;
    this.checkpoint();
    const t = this.s.currentTime;
    this.updateRedaction(id, (r) => ({ ...r, rect: rectAt(r, t), track: null }));
  }

  async autoRedact(kinds: SensitiveKind[]) {
    if (!this.begin("Suche sensible Daten im Video …")) return;
    try {
      const found = await api.videoDetect(this.id, this.s.trimStart, this.s.trimEnd, this.s.style, kinds);
      this.end();
      if (!found || found.length === 0) return this.showToast("Nichts Sensibles gefunden");
      this.checkpoint();
      this.set({ redactions: [...this.s.redactions, ...found] });
      this.showToast(`${found.length} Fundstelle${found.length === 1 ? "" : "n"} zensiert — bitte kurz prüfen`);
    } catch {
      this.end();
    }
  }

  /** Speichert (Rust exportiert gekürzt + zensiert). Liefert true bei Erfolg. */
  async save(): Promise<boolean> {
    if (!this.begin("Video wird gespeichert …")) return false;
    try {
      const item = await api.videoSave(this.id, this.document);
      this.end();
      this.set({ item: item ?? this.s.item, dirty: false });
      this.showToast("Gespeichert");
      return true;
    } catch (e) {
      this.end();
      if (!this.cancelled) this.showToast(`Speichern fehlgeschlagen: ${errorText(e)}`, true);
      return false;
    }
  }

  async exportGif() {
    if (!this.begin("GIF wird erstellt …")) return;
    try {
      await api.videoExportGif(this.id, this.document);
      this.end();
      this.showToast("GIF gespeichert");
    } catch (e) {
      this.end();
      if (!this.cancelled) this.showToast(`GIF-Export fehlgeschlagen: ${errorText(e)}`, true);
    }
  }

  async copyFile() {
    if (this.s.busy) return;
    if (this.s.dirty && !(await this.save())) return;
    try {
      await api.itemCopy(this.id);
      this.showToast("Datei kopiert — in Slack, Mail usw. einfügen");
    } catch (e) {
      this.showToast(`Kopieren fehlgeschlagen: ${errorText(e)}`, true);
    }
  }

  showToast(text: string, error = false) {
    this.set({ toast: { text, error } });
    window.clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => this.set({ toast: null }), 2600);
  }
}

function errorText(e: unknown): string {
  return typeof e === "string" ? e : e instanceof Error ? e.message : String(e);
}

export function useVideoState(model: VideoModel): VideoState {
  return useSyncExternalStore(model.subscribe, model.getSnapshot);
}
