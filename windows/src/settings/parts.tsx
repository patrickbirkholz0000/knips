import { useEffect, useState } from "react";
import { ChevronDown, ChevronUp } from "lucide-react";
import { cx, Keys } from "../shared/ui";

// Bausteine nur der Einstellungen. Allgemeine (Switch, Select, Row …) liegen in shared/ui.

/** Zahl tippen (Enter übernimmt) oder mit den Pfeilen ändern; ungültig → letzter Wert. */
export function SecondsField({ value, min, max, onChange }: { value: number; min: number; max: number; onChange: (n: number) => void }) {
  const [text, setText] = useState(String(value));
  useEffect(() => setText((t) => (Number(t) === value ? t : String(value))), [value]);
  const clamp = (n: number) => Math.min(max, Math.max(min, n));
  const normalize = () => {
    const n = parseInt(text.replace(/\D/g, ""), 10);
    const v = Number.isFinite(n) ? clamp(n) : value;
    if (v !== value) onChange(v);
    setText(String(v));
  };
  return (
    <div className="st-secs">
      <input
        value={text}
        inputMode="numeric"
        aria-label="Sekunden"
        onChange={(e) => {
          setText(e.target.value);
          const n = parseInt(e.target.value.replace(/\D/g, ""), 10);
          if (Number.isFinite(n) && n >= min && n <= max && n !== value) onChange(n);
        }}
        onKeyDown={(e) => e.key === "Enter" && (normalize(), (e.target as HTMLInputElement).blur())}
        onBlur={normalize}
      />
      <span>{value === 1 ? "Sekunde" : "Sekunden"}</span>
      <div className="st-step">
        <button type="button" aria-label="Mehr" onClick={() => onChange(clamp(value + 1))}>
          <ChevronUp size={11} strokeWidth={2.8} />
        </button>
        <button type="button" aria-label="Weniger" onClick={() => onChange(clamp(value - 1))}>
          <ChevronDown size={11} strokeWidth={2.8} />
        </button>
      </div>
    </div>
  );
}

/** Kürzel als Tastenkappen; Klick nimmt eine neue Kombination auf. */
export function KeyButton({ action, label, recording, dim, onClick }: { action: string; label?: string; recording: boolean; dim?: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      data-hotkey={action}
      className={cx("st-keybtn", recording && "is-rec", !recording && !label && "is-empty", dim && "is-dim")}
      title="Klicken und neue Tastenkombination drücken"
      onClick={onClick}
    >
      {recording ? "Tasten drücken …" : label ? <Keys combo={label} /> : "Nicht belegt"}
    </button>
  );
}
