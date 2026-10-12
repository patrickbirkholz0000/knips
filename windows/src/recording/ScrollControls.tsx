import { useEffect, useState } from "react";
import { ArrowDownToLine, X } from "lucide-react";
import { api, events } from "../shared/ipc";
import type { ScrollState } from "../shared/types";
import "./recording.css";
import "./mock";

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
      <ArrowDownToLine size={14} strokeWidth={2.4} color="rgba(255,255,255,0.85)" />
      <div className="scroll-text" data-tauri-drag-region>
        <span className="a">Jetzt langsam nach unten scrollen</span>
        <span className="b">{s.sections} Abschnitt{s.sections === 1 ? "" : "e"} · {s.outputHeight} px hoch</span>
      </div>
      <button className="pill-white" onClick={() => api.scrollFinish(true)}>Fertig</button>
      <button className="round" title="Abbrechen" onClick={() => api.scrollFinish(false)}>
        <X size={12} strokeWidth={2.8} />
      </button>
    </div>
  );
}
