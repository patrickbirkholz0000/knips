import { useEffect, useState, type ReactNode } from "react";
import { Check, ChevronDown, ChevronUp } from "lucide-react";

// Bausteine der Einstellungen (Card, Row, Switch, Choice, SecondsField, Pill, Notice).

export function Card({ title, footer, children }: { title?: string; footer?: string; children: ReactNode }) {
  return (
    <section className="st-card">
      {title && <h3>{title}</h3>}
      <div className="st-card-box">{children}</div>
      {footer && <p>{footer}</p>}
    </section>
  );
}

export function Row({ title, subtitle, off, children }: { title: string; subtitle?: string; off?: boolean; children?: ReactNode }) {
  return (
    <div className={`st-row${off ? " off" : ""}`}>
      <div className="tx">
        <div className="t">{title}</div>
        {subtitle && <div className="s">{subtitle}</div>}
      </div>
      {children}
    </div>
  );
}

export const Div = () => <div className="st-div" />;

export function Switch({ on, onChange, disabled }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return <button role="switch" aria-checked={on} className={`st-switch${on ? " on" : ""}`} disabled={disabled} onClick={() => onChange(!on)} />;
}

export function Checkbox({ on, onChange, disabled }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <button role="checkbox" aria-checked={on} className={`st-check${on ? " on" : ""}`} disabled={disabled} onClick={() => onChange(!on)}>
      {on && <Check size={12} strokeWidth={3.5} />}
    </button>
  );
}

export function Choice<T extends string | number | boolean>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  const idx = options.findIndex(([v]) => v === value);
  return (
    <span className="st-choice">
      <select value={idx} onChange={(e) => onChange(options[Number(e.target.value)][0])}>
        {options.map(([, label], i) => (
          <option key={i} value={i}>{label}</option>
        ))}
      </select>
      <ChevronDown size={13} />
    </span>
  );
}

export function Pill({ kind, onClick, children }: { kind?: "primary" | "danger"; onClick?: () => void; children: ReactNode }) {
  return <button className={`st-pill${kind ? " " + kind : ""}`} onClick={onClick}>{children}</button>;
}

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
        <button onClick={() => onChange(clamp(value + 1))}><ChevronUp size={10} strokeWidth={3} /></button>
        <button onClick={() => onChange(clamp(value - 1))}><ChevronDown size={10} strokeWidth={3} /></button>
      </div>
    </div>
  );
}

export function Notice({ tone, icon, title, detail, children }: { tone: "orange" | "green"; icon: ReactNode; title: string; detail: string; children?: ReactNode }) {
  return (
    <div className={`st-notice ${tone}`}>
      <span className="ico">{icon}</span>
      <div>
        <div className="t">{title}</div>
        <div className="d">{detail}</div>
        {children && <div className="a">{children}</div>}
      </div>
    </div>
  );
}
