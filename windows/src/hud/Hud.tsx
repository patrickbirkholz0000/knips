import { useEffect, useRef, useState } from "react";
import { CircleAlert, CircleCheck, BoxSelect, Copy, Pin, ScanText, TextSearch, Trash2, type LucideIcon } from "lucide-react";
import { events, inTauri, mockEmit, registerMock } from "../shared/ipc";
import type { HudIcon, HudMessage } from "../shared/types";
import "./hud.css";

const icons: Record<HudIcon, LucideIcon> = {
  check: CircleCheck,
  text: ScanText,
  search: TextSearch,
  error: CircleAlert,
  trash: Trash2,
  dashed: BoxSelect,
  pin: Pin,
  copy: Copy,
};

const SHOW_MS = 1400;

// Ohne Tauri: Beispieleinblendung (?text=…&icon=…)
if (!inTauri) {
  registerMock("hud", () => undefined);
  const q = new URLSearchParams(window.location.hash.split("?")[1] ?? "");
  setTimeout(() => mockEmit("hud-show", { text: q.get("text") ?? "Kopiert", icon: q.get("icon") ?? "check" }), 300);
}

export default function Hud(_: { params: string[]; query: URLSearchParams }) {
  const [msg, setMsg] = useState<HudMessage | null>(null);
  const [fading, setFading] = useState(false);
  const timer = useRef<number>();

  useEffect(() => {
    const off = events.hudShow((m) => {
      setMsg(m);
      setFading(false);
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setFading(true), SHOW_MS);
    });
    return () => {
      off.then((f) => f());
      window.clearTimeout(timer.current);
    };
  }, []);

  if (!msg) return null;
  const Icon = icons[msg.icon] ?? CircleCheck;
  return (
    <div className="hud-wrap">
      <div className={"hud" + (fading ? " fading" : "")}>
        <Icon size={15} strokeWidth={2.2} />
        <span>{msg.text}</span>
      </div>
    </div>
  );
}
