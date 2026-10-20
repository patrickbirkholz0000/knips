import { useEffect, useRef, useState } from "react";
import { getCurrentWindow, LogicalPosition, LogicalSize } from "@tauri-apps/api/window";
import { Copy, X } from "lucide-react";
import { api, fileUrl, inTauri } from "../shared/ipc";
import type { PinInfo } from "../shared/types";
import "./pin.css";
import "./mock";

const MIN_WIDTH = 60;

export default function Pin({ params }: { params: string[]; query: URLSearchParams }) {
  const n = Number(params[0] ?? 0);
  const [info, setInfo] = useState<PinInfo | null>(null);
  // Fenstermaße nachgeführt, damit schnelle Mausrad-Schritte nicht auf alten Werten aufbauen.
  const geo = useRef<{ x: number; y: number; w: number; h: number } | null>(null);

  useEffect(() => {
    api.pinInfo(n).then((i) => i && setInfo(i));
  }, [n]);

  const close = () => (inTauri ? getCurrentWindow().close() : undefined);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
      else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "c") api.pinCopy(n);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [n]);

  const onWheel = async (e: React.WheelEvent) => {
    if (!inTauri || !info) return;
    const win = getCurrentWindow();
    if (!geo.current) {
      const scale = await win.scaleFactor();
      const p = (await win.outerPosition()).toLogical(scale);
      geo.current = { x: p.x, y: p.y, w: window.innerWidth, h: window.innerHeight };
    }
    const g = geo.current;
    const factor = 1 - e.deltaY * 0.0015;
    const w = Math.max(MIN_WIDTH, g.w * factor);
    const h = (w * info.pixelHeight) / Math.max(info.pixelWidth, 1);
    g.x -= (w - g.w) / 2;
    g.y -= (h - g.h) / 2;
    g.w = w;
    g.h = h;
    await win.setSize(new LogicalSize(w, h));
    await win.setPosition(new LogicalPosition(g.x, g.y));
  };

  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    if (e.detail === 2) return close();
    if (inTauri) getCurrentWindow().startDragging();
  };

  if (!info) return null;
  return (
    <div className="pin" onMouseDown={onMouseDown} onWheel={onWheel}>
      <img src={fileUrl(info.path)} alt="" draggable={false} />
      <div className="pin-controls" onMouseDown={(e) => e.stopPropagation()}>
        <button className="pin-btn" title="Schließen (Esc)" onClick={close}>
          <X size={14} strokeWidth={2.4} />
        </button>
        <button className="pin-btn" title="Kopieren (Strg+C)" onClick={() => api.pinCopy(n)}>
          <Copy size={13} strokeWidth={2.1} />
        </button>
      </div>
    </div>
  );
}
