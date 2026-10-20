// Video-Fläche: <video> plus Zeichenebene mit Live-Zensur, Rahmen, Griffen und Ziehen neuer Felder.
// Rahmen, Griffe und das aufgezogene Feld in Königsblau aus den Tokens (--k-accent, folgt Hell/Dunkel).
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Rect } from "../shared/types";
import { contains, drawRedaction, rectAt } from "./redact";
import { useVideoState, type VideoModel } from "./model";

const INSET = 16;

/** Farben der Oberfläche aus tokens.css; neu gelesen, wenn <html data-theme> wechselt. */
interface Ink {
  accent: string;
  paper: string;
}
function readInk(el: Element): Ink {
  const cs = getComputedStyle(el);
  return { accent: cs.getPropertyValue("--k-accent").trim(), paper: cs.getPropertyValue("--k-dark-button").trim() };
}

type Drag =
  | { kind: "none" }
  | { kind: "draw"; start: { x: number; y: number } }
  | { kind: "move"; id: string; last: { x: number; y: number }; moved: boolean }
  | { kind: "resize"; id: string; anchor: { x: number; y: number } };

export default function Player({ model }: { model: VideoModel }) {
  const s = useVideoState(model);
  const stageRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const dragRef = useRef<Drag>({ kind: "none" });
  const draftRef = useRef<Rect | null>(null);
  const [cursor, setCursor] = useState("crosshair");
  const inkRef = useRef<Ink | null>(null);

  // Seitenverhältnis einpassen (AVMakeRect)
  const vr = (() => {
    const aw = Math.max(1, size.w - INSET * 2);
    const ah = Math.max(1, size.h - INSET * 2);
    const k = Math.min(aw / model.videoW, ah / model.videoH);
    const w = model.videoW * k;
    const h = model.videoH * k;
    return { x: INSET + (aw - w) / 2, y: INSET + (ah - h) / 2, width: w, height: h };
  })();
  const factor = vr.width / model.videoW;
  const geo = useRef({ vr, factor });
  geo.current = { vr, factor };

  useLayoutEffect(() => {
    const el = stageRef.current!;
    const ro = new ResizeObserver(() => setSize({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    setSize({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  const toVideo = (px: number, py: number) => {
    const { vr, factor } = geo.current;
    return {
      x: Math.max(0, Math.min((px - vr.x) / factor, model.videoW)),
      y: Math.max(0, Math.min((py - vr.y) / factor, model.videoH)),
    };
  };
  const toView = (r: Rect): Rect => {
    const { vr, factor } = geo.current;
    return { x: vr.x + r.x * factor, y: vr.y + r.y * factor, width: r.width * factor, height: r.height * factor };
  };

  // ------------------------------------------------------------ Zeichnen

  const draw = useCallback(() => {
    const canvas = canvasRef.current;
    const video = videoRef.current;
    if (!canvas || !video) return;
    const st = model.s;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const t = st.isPlaying ? video.currentTime : st.currentTime;
    const { factor } = geo.current;
    const ink = (inkRef.current ??= readInk(canvas));

    // Vorschau der Zensur im Bild
    for (const r of st.redactions) {
      if (!model.isActive(r, t)) continue;
      const rect = rectAt(r, t);
      drawRedaction(ctx, video, model.videoW, model.videoH, rect, toView(rect), r.style, model.scale, factor);
    }

    // Rahmen der aktiven Felder
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = ink.accent;
    ctx.globalAlpha = 0.9;
    ctx.setLineDash([5, 4]);
    for (const r of st.redactions) {
      if (r.id === st.selectedId || !model.isActive(r, t)) continue;
      const v = toView(rectAt(r, t));
      ctx.strokeRect(v.x, v.y, v.width, v.height);
    }
    ctx.setLineDash([]);
    ctx.globalAlpha = 1;

    // Auswahl mit Griffen
    const sel = st.redactions.find((r) => r.id === st.selectedId);
    if (sel) {
      const v = toView(rectAt(sel, t));
      ctx.globalAlpha = model.isActive(sel, t) ? 1 : 0.45;
      ctx.strokeStyle = ink.accent;
      ctx.lineWidth = 2;
      ctx.strokeRect(v.x, v.y, v.width, v.height);
      for (const [cx, cy] of [[v.x, v.y], [v.x + v.width, v.y], [v.x, v.y + v.height], [v.x + v.width, v.y + v.height]]) {
        ctx.beginPath();
        ctx.arc(cx, cy, 5, 0, Math.PI * 2);
        ctx.fillStyle = ink.paper;
        ctx.fill();
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }

    // Feld, das gerade aufgezogen wird
    const draft = draftRef.current;
    if (draft) {
      const v = toView(draft);
      ctx.fillStyle = ink.accent;
      ctx.globalAlpha = 0.18;
      ctx.fillRect(v.x, v.y, v.width, v.height);
      ctx.globalAlpha = 1;
      ctx.strokeStyle = ink.accent;
      ctx.lineWidth = 1.5;
      ctx.strokeRect(v.x, v.y, v.width, v.height);
    }
  }, [model]);

  const pending = useRef(0);
  const requestDraw = useCallback(() => {
    if (pending.current) return;
    pending.current = requestAnimationFrame(() => {
      pending.current = 0;
      draw();
    });
  }, [draw]);

  // Hell/Dunkel umgeschaltet: Farben neu lesen und neu zeichnen.
  useEffect(() => {
    const mo = new MutationObserver(() => {
      inkRef.current = null;
      requestDraw();
    });
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => mo.disconnect();
  }, [requestDraw]);

  // Jede Zustandsänderung und Größenänderung zeichnet neu.
  useEffect(() => {
    requestDraw();
  }, [s, size, requestDraw]);
  useEffect(() => {
    const off = model.subscribe(requestDraw);
    return () => void off();
  }, [model, requestDraw]);

  // Video anbinden
  useEffect(() => {
    const v = videoRef.current!;
    model.video = v;
    const onMeta = () => {
      v.currentTime = model.s.currentTime;
      requestDraw();
    };
    const onEnded = () => {
      model.tick(v.currentTime);
      if (model.s.isPlaying) model.set({ isPlaying: false });
    };
    v.addEventListener("loadedmetadata", onMeta);
    v.addEventListener("loadeddata", requestDraw);
    v.addEventListener("seeked", requestDraw);
    v.addEventListener("ended", onEnded);
    return () => {
      v.removeEventListener("loadedmetadata", onMeta);
      v.removeEventListener("loadeddata", requestDraw);
      v.removeEventListener("seeked", requestDraw);
      v.removeEventListener("ended", onEnded);
      if (model.video === v) model.video = null;
    };
  }, [model, requestDraw]);

  // Wiedergabe: Zeit und Zeichenebene im Takt der Videobilder halten
  useEffect(() => {
    if (!s.isPlaying) return;
    const v = videoRef.current!;
    let alive = true;
    let raf = 0;
    const loop = () => {
      if (!alive) return;
      model.tick(v.currentTime);
      draw();
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => {
      alive = false;
      cancelAnimationFrame(raf);
    };
  }, [s.isPlaying, model, draw]);

  // ------------------------------------------------------------ Zeiger

  const local = (e: React.PointerEvent) => {
    const b = stageRef.current!.getBoundingClientRect();
    return { x: e.clientX - b.left, y: e.clientY - b.top };
  };

  const handleHit = (p: { x: number; y: number }) => {
    const sel = model.selected;
    if (!sel) return null;
    const cur = rectAt(sel, model.s.currentTime);
    const r = toView(cur);
    const corners = [
      { c: [r.x, r.y], a: { x: cur.x + cur.width, y: cur.y + cur.height }, cur: "nwse-resize" },
      { c: [r.x + r.width, r.y], a: { x: cur.x, y: cur.y + cur.height }, cur: "nesw-resize" },
      { c: [r.x, r.y + r.height], a: { x: cur.x + cur.width, y: cur.y }, cur: "nesw-resize" },
      { c: [r.x + r.width, r.y + r.height], a: { x: cur.x, y: cur.y }, cur: "nwse-resize" },
    ];
    for (const k of corners) if (Math.hypot(k.c[0] - p.x, k.c[1] - p.y) <= 9) return { id: sel.id, anchor: k.a, cur: k.cur };
    return null;
  };

  const hitRedaction = (vp: { x: number; y: number }) => {
    const { redactions, selectedId, currentTime } = model.s;
    const candidates = redactions.filter((r) => r.id === selectedId || model.isActive(r));
    return [...candidates].reverse().find((r) => contains(rectAt(r, currentTime), vp.x, vp.y));
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (e.button !== 0) return;
    const p = local(e);
    e.currentTarget.setPointerCapture(e.pointerId);
    const h = handleHit(p);
    if (h) {
      model.checkpoint();
      dragRef.current = { kind: "resize", id: h.id, anchor: h.anchor };
      return;
    }
    const vp = toVideo(p.x, p.y);
    const hit = hitRedaction(vp);
    if (hit) {
      model.select(hit.id);
      dragRef.current = { kind: "move", id: hit.id, last: vp, moved: false };
      return;
    }
    model.select(null);
    const { vr } = geo.current;
    dragRef.current = contains(vr, p.x, p.y) ? { kind: "draw", start: vp } : { kind: "none" };
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const p = local(e);
    const d = dragRef.current;
    if (d.kind === "none") {
      const h = handleHit(p);
      const vp = toVideo(p.x, p.y);
      setCursor(h ? h.cur : hitRedaction(vp) ? "move" : "crosshair");
      return;
    }
    const vp = toVideo(p.x, p.y);
    if (d.kind === "draw") {
      draftRef.current = { x: Math.min(d.start.x, vp.x), y: Math.min(d.start.y, vp.y), width: Math.abs(vp.x - d.start.x), height: Math.abs(vp.y - d.start.y) };
      requestDraw();
    } else if (d.kind === "move") {
      if (!d.moved) model.checkpoint();
      model.moveRedaction(d.id, vp.x - d.last.x, vp.y - d.last.y);
      dragRef.current = { ...d, last: vp, moved: true };
    } else {
      model.updateRedaction(d.id, (r) => ({
        ...r,
        rect: { x: Math.min(d.anchor.x, vp.x), y: Math.min(d.anchor.y, vp.y), width: Math.abs(vp.x - d.anchor.x), height: Math.abs(vp.y - d.anchor.y) },
        track: null, // neue Größe: Verfolgung neu starten
      }));
    }
  };

  const onPointerUp = () => {
    const d = dragRef.current;
    if (d.kind === "draw") {
      const r = draftRef.current;
      if (r && r.width * factor >= 6 && r.height * factor >= 6) model.addRedaction(r);
      draftRef.current = null;
      requestDraw();
    }
    dragRef.current = { kind: "none" };
  };

  return (
    <div className="vid-stage" ref={stageRef}>
      <video
        ref={videoRef}
        src={model.sourceUrl}
        preload="auto"
        playsInline
        style={{ left: vr.x, top: vr.y, width: vr.width, height: vr.height }}
      />
      <canvas
        ref={canvasRef}
        style={{ cursor }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      />
    </div>
  );
}
