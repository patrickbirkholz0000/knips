// Zeitleiste: Vorschaubilder, Kürzungs-Griffe und Abspielkopf in Tinte, Zensur-Spuren als Königsblau-Spannen.
import { useRef } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { useVideoState, type VideoModel } from "./model";

export default function Timeline({ model }: { model: VideoModel }) {
  const s = useVideoState(model);
  const ref = useRef<HTMLDivElement>(null);
  const trimDrag = useRef<{ start: number; end: number; x: number } | null>(null);
  const d = Math.max(model.duration, 0.001);
  const pct = (t: number) => `${(t / d) * 100}%`;

  const timeAt = (clientX: number) => {
    const b = ref.current!.getBoundingClientRect();
    return Math.max(0, Math.min((clientX - b.left) / b.width, 1)) * d;
  };

  const scrub = (e: React.PointerEvent) => {
    if (e.type === "pointerdown") e.currentTarget.setPointerCapture(e.pointerId);
    if (e.type === "pointerdown" || e.currentTarget.hasPointerCapture(e.pointerId)) model.seek(timeAt(e.clientX));
  };

  const trimHandle = (left: boolean) => (
    <div
      className={`vid-trim-handle ${left ? "left" : "right"}`}
      style={{ left: `calc(${pct(left ? s.trimStart : s.trimEnd)} - 6px)` }}
      onPointerDown={(e) => {
        e.stopPropagation();
        e.currentTarget.setPointerCapture(e.pointerId);
        trimDrag.current = { start: s.trimStart, end: s.trimEnd, x: e.clientX };
        model.checkpoint();
      }}
      onPointerMove={(e) => {
        const t = trimDrag.current;
        if (!t) return;
        const dt = ((e.clientX - t.x) / ref.current!.getBoundingClientRect().width) * d;
        if (left) {
          model.setTrim(t.start + dt);
          model.seek(model.s.trimStart);
        } else {
          model.setTrim(undefined, t.end + dt);
          model.seek(model.s.trimEnd);
        }
      }}
      onPointerUp={() => (trimDrag.current = null)}
      onPointerCancel={() => (trimDrag.current = null)}
    >
      {left ? <ChevronLeft size={11} strokeWidth={3} /> : <ChevronRight size={11} strokeWidth={3} />}
    </div>
  );

  return (
    <div className="vid-timeline" ref={ref}>
      <div className="vid-strip-row">
        <div className="vid-strip" onPointerDown={scrub} onPointerMove={scrub}>
          {s.thumbnails.map((u, i) => (
            <img key={i} src={u} alt="" draggable={false} style={{ width: `${100 / s.thumbnails.length}%` }} />
          ))}
        </div>
        {/* Außerhalb der Kürzung abdunkeln */}
        <div className="vid-dim" style={{ left: 0, width: pct(s.trimStart) }} />
        <div className="vid-dim" style={{ left: pct(s.trimEnd), right: 0 }} />
        <div
          className="vid-trim-frame"
          style={{ left: pct(s.trimStart), width: `max(4px, calc(${pct(s.trimEnd)} - ${pct(s.trimStart)}))` }}
        />
        {trimHandle(true)}
        {trimHandle(false)}
        <div className="vid-playhead" style={{ left: `calc(${pct(s.currentTime)} - 1px)` }}>
          <i />
        </div>
      </div>
      <div className="vid-tracks">
        {s.redactions.map((r) => (
          <div
            key={r.id}
            className={`vid-track-bar${r.id === s.selectedId ? " selected" : ""}`}
            title={r.auto ? "Zensur (auto)" : "Zensur"}
            style={{ left: pct(r.start), width: `max(4px, calc(${pct(r.end)} - ${pct(r.start)}))` }}
            onClick={() => {
              model.select(r.id);
              model.seek(Math.max(r.start, Math.min(model.s.currentTime, r.end)));
            }}
          />
        ))}
      </div>
    </div>
  );
}
