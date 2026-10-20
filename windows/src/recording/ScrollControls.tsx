import { useEffect, useState } from "react";
import { ArrowDownToLine } from "lucide-react";
import { api, events } from "../shared/ipc";
import type { ScrollState } from "../shared/types";
import "./recording.css";
import "./mock";

/** 12480 → „12 480“ (schmales geschütztes Leerzeichen als Tausendertrenner, wie in docs/design.md). */
function grouped(n: number): string {
  return String(Math.max(0, Math.round(n))).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
}

// Scroll-Leiste (docs/design.md): dunkle Pille mit Höhe in Mono, „Fertig“ (Papier) und „Abbrechen“.
export default function ScrollControls(_: { params: string[]; query: URLSearchParams }) {
  const [s, setS] = useState<ScrollState>({ active: false, sections: 0, outputHeight: 0 });
  useEffect(() => {
    let alive = true;
    api.getScrollState().then((v) => alive && v && setS(v));
    const off = events.scrollState((v) => alive && setS(v));
    return () => {
      alive = false;
      off.then((f) => f());
    };
  }, []);
  return (
    <div className="bar scroll-bar" data-tauri-drag-region>
      <ArrowDownToLine className="scroll-ico" size={16} strokeWidth={2.1} />
      <div className="scroll-text grow" data-tauri-drag-region>
        <span className="a" data-tauri-drag-region>
          Langsam nach unten scrollen
        </span>
        <span className="b bar-mono" data-tauri-drag-region>
          <b>{grouped(s.outputHeight)} px</b> · {s.sections} Abschnitt{s.sections === 1 ? "" : "e"}
        </span>
      </div>
      <button className="pill-paper" onClick={() => api.scrollFinish(true)}>
        Fertig
      </button>
      <button className="pill-ghost" onClick={() => api.scrollFinish(false)}>
        Abbrechen
      </button>
    </div>
  );
}
