// Popover „Hintergrund und Rahmen“ (FramePanel in EditorWindow.swift): Karte mit Schalter (Königsblau),
// Verläufen (bunt, Inhalt) und Segment-Schaltern; Überschriften in Mono-Versalien wie in der App-Familie.
import { useCallback, useRef, useState } from "react";
import { Layers } from "lucide-react";
import type { FrameStyle } from "../shared/types";
import { EditorModel, useModel } from "./model";
import { useDismiss } from "./popover";
import { FRAME_GRADIENTS, rgbaCss } from "./renderer";

function Segmented<T extends number>({ value, options, onChange }: { value: T; options: [string, T][]; onChange: (v: T) => void }) {
  return (
    <div className="kc-seg kc-seg--fill">
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
  const close = useCallback(() => setOpen(false), []);
  useDismiss(open, close, ref);

  const style: FrameStyle = model.frame ?? model.lastFrame;
  const update = (change: Partial<FrameStyle>) => model.setFrame({ ...style, ...change });

  return (
    <div className="ed-pop-wrap" ref={ref}>
      <button
        className={`kc-tool ed-icon${model.frame || open ? " on" : ""}`}
        title="Hintergrund und Rahmen"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <Layers size={17} strokeWidth={1.8} fill={model.frame ? "currentColor" : "none"} fillOpacity={0.2} />
      </button>
      {open && (
        <div className="kc-popover ed-popover">
          <label className="ed-switch-row">
            <span className="ed-pop-title">Hintergrund und Rahmen</span>
            <input type="checkbox" className="kc-switch ed-switch" checked={!!model.frame} onChange={(e) => model.setFrame(e.target.checked ? style : null)} />
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
            <span className="kc-overline">Abstand</span>
            <Segmented value={style.padding} options={[["Klein", 24], ["Mittel", 48], ["Groß", 80]]} onChange={(v) => update({ padding: v })} />
          </div>
          <div className="ed-field">
            <span className="kc-overline">Ecken</span>
            <Segmented value={style.cornerRadius} options={[["Eckig", 0], ["Rund", 12], ["Sehr rund", 24]]} onChange={(v) => update({ cornerRadius: v })} />
          </div>
          <label className="ed-switch-row">
            <span>Schatten</span>
            <input type="checkbox" className="kc-switch ed-switch" checked={style.shadow} onChange={(e) => update({ shadow: e.target.checked })} />
          </label>
        </div>
      )}
    </div>
  );
}
