// Popover „Hintergrund und Rahmen“ (FramePanel in EditorWindow.swift).
import { useEffect, useRef, useState } from "react";
import { Layers } from "lucide-react";
import type { FrameStyle } from "../shared/types";
import { EditorModel, useModel } from "./model";
import { FRAME_GRADIENTS, rgbaCss } from "./renderer";

function Segmented<T extends number>({ value, options, onChange }: { value: T; options: [string, T][]; onChange: (v: T) => void }) {
  return (
    <div className="ed-seg">
      {options.map(([label, v]) => (
        <button key={v} className={value === v ? "on" : ""} onClick={() => onChange(v)}>
          {label}
        </button>
      ))}
    </div>
  );
}

export function FrameButton({ model }: { model: EditorModel }) {
  useModel(model);
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        setOpen(false);
      }
    };
    window.addEventListener("mousedown", down);
    window.addEventListener("keydown", key, true);
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("keydown", key, true);
    };
  }, [open]);

  const style: FrameStyle = model.frame ?? model.lastFrame;
  const update = (change: Partial<FrameStyle>) => model.setFrame({ ...style, ...change });

  return (
    <div className="ed-pop-wrap" ref={ref}>
      <button className={`ed-icon${model.frame ? " accent" : ""}`} title="Hintergrund und Rahmen" onClick={() => setOpen(!open)}>
        <Layers size={16} strokeWidth={2} fill={model.frame ? "currentColor" : "none"} fillOpacity={0.25} />
      </button>
      {open && (
        <div className="ed-popover">
          <label className="ed-switch-row">
            <span style={{ fontWeight: 600 }}>Hintergrund und Rahmen</span>
            <input type="checkbox" className="ed-switch" checked={!!model.frame} onChange={(e) => model.setFrame(e.target.checked ? style : null)} />
          </label>
          <div className="ed-grads">
            {FRAME_GRADIENTS.map((g, i) => (
              <button
                key={g.name}
                title={g.name}
                className={model.frame?.gradient === i ? "on" : ""}
                style={{ background: `linear-gradient(135deg, ${rgbaCss(g.colors[0])}, ${rgbaCss(g.colors[1])})` }}
                onClick={() => update({ gradient: i })}
              />
            ))}
          </div>
          <div className="ed-field">
            <span>Abstand</span>
            <Segmented value={style.padding} options={[["Klein", 24], ["Mittel", 48], ["Groß", 80]]} onChange={(v) => update({ padding: v })} />
          </div>
          <div className="ed-field">
            <span>Ecken</span>
            <Segmented value={style.cornerRadius} options={[["Eckig", 0], ["Rund", 12], ["Sehr rund", 24]]} onChange={(v) => update({ cornerRadius: v })} />
          </div>
          <label className="ed-switch-row">
            <span>Schatten</span>
            <input type="checkbox" className="ed-switch" checked={style.shadow} onChange={(e) => update({ shadow: e.target.checked })} />
          </label>
        </div>
      )}
    </div>
  );
}
