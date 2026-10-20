// Gemeinsame Bausteine in der Markensprache der App-Familie (docs/design.md): Schalter, Segment-Schalter,
// Auswahlfeld, Knöpfe, Tastenkappen, Karten mit Zeilen, Überschriften in Mono-Versalien, Hinweise,
// Bereit-Zeichen und Dialog-Karte. Stil in ui.css, Werte nur aus tokens.css (--k-*). Jede Ansicht darf sie nutzen.
import type { ButtonHTMLAttributes, CSSProperties, ReactNode } from "react";
import { Check, ChevronDown } from "lucide-react";
import "./ui.css";

export function cx(...c: (string | false | null | undefined)[]): string {
  return c.filter(Boolean).join(" ");
}

// ---------------------------------------------------------------- Bedienelemente

/** Schalter (Königsblau, wenn an). */
export function Switch({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} className="k-switch" disabled={disabled} onClick={() => onChange(!on)} />
  );
}

/** Segment-Schalter: graue Spur (fill), gewählter Teil als weißer Daumen. */
export function Segmented<T extends string | number | boolean>({
  value,
  options,
  onChange,
  label,
  size,
}: {
  value: T;
  options: [T, ReactNode][];
  onChange: (v: T) => void;
  label?: string;
  size?: "sm";
}) {
  return (
    <div className={cx("k-seg", size === "sm" && "k-seg--sm")} role="radiogroup" aria-label={label}>
      {options.map(([v, text], i) => (
        <button key={i} type="button" role="radio" aria-checked={v === value} className={v === value ? "on" : undefined} onClick={() => onChange(v)}>
          {text}
        </button>
      ))}
    </div>
  );
}

/** Auswahlfeld (natives Menü, Linie, Pfeil). Optionen als [Wert, Text]. */
export function Select<T extends string | number | boolean>({
  value,
  options,
  onChange,
  label,
  disabled,
}: {
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
  label?: string;
  disabled?: boolean;
}) {
  const idx = options.findIndex(([v]) => v === value);
  return (
    <span className="k-select">
      <select value={idx} aria-label={label} disabled={disabled} onChange={(e) => onChange(options[Number(e.target.value)][0])}>
        {options.map(([, text], i) => (
          <option key={i} value={i}>
            {text}
          </option>
        ))}
      </select>
      <ChevronDown size={14} strokeWidth={2.2} aria-hidden="true" />
    </span>
  );
}

/** Kästchen (selten — für Einstellungen lieber `Switch`). Echtes <input>, damit Formulare und Tests es lesen können. */
export function Checkbox({
  checked,
  onChange,
  disabled,
  children,
  ...rest
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  children?: ReactNode;
  [data: `data-${string}`]: string | undefined;
}) {
  return (
    <label className={cx("k-check", disabled && "is-off")}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} {...rest} />
      <span className="k-check__box" aria-hidden="true">
        <Check size={12} strokeWidth={3.2} />
      </span>
      {children && <span>{children}</span>}
    </label>
  );
}

export type ButtonVariant = "primary" | "secondary" | "text";

/** Knopf: primär = Tinte, sekundär = Karte mit Linie, Text = leise. */
export function Button({
  variant = "secondary",
  size,
  className,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant; size?: "sm" }) {
  return (
    <button type="button" className={cx("k-btn", `k-btn--${variant}`, size === "sm" && "k-btn--sm", className)} {...rest}>
      {children}
    </button>
  );
}

// ---------------------------------------------------------------- Kürzel

/** Eine Tastenkappe (weiß, Linie, Mono); `tone="dark"` auf den immer dunklen Flächen (Menü, Pillen). */
export function KeyCap({ children, size, tone }: { children: ReactNode; size?: "lg"; tone?: "dark" }) {
  return <kbd className={cx("k-key", size === "lg" && "k-key--lg", tone === "dark" && "k-key--dark")}>{children}</kbd>;
}

/** „Strg+Umschalt+Druck“ → ["Strg", "Umschalt", "Druck"]; die Plus-Taste selbst bleibt erhalten („Strg++“). */
export function comboParts(label: string): string[] {
  if (label === "+") return ["+"];
  if (label.endsWith("++")) return [...label.slice(0, -2).split("+").filter(Boolean), "+"];
  return label.split("+").filter(Boolean);
}

/** Kürzel als Tastenkappen mit leisem „+“ dazwischen („Strg+Druck“ → [Strg] + [Druck]). */
export function Keys({ combo, size, tone }: { combo: string; size?: "lg"; tone?: "dark" }) {
  const parts = comboParts(combo);
  return (
    <span className={cx("k-keys", size === "lg" && "k-keys--lg", tone === "dark" && "k-keys--dark")} aria-label={combo}>
      {parts.map((p, i) => (
        <span key={i} className="k-keys__part">
          {i > 0 && <span className="k-keys__plus">+</span>}
          <KeyCap size={size} tone={tone}>
            {p}
          </KeyCap>
        </span>
      ))}
    </span>
  );
}

// ---------------------------------------------------------------- Flächen

/** Kleine Überschrift in Mono-Versalien (`AUFNAHME`, `ZULETZT`); `side` für die dunkle Seitenleiste. */
export function Overline({ children, tone, className, style }: { children: ReactNode; tone?: "side"; className?: string; style?: CSSProperties }) {
  return (
    <div className={cx("k-overline", tone === "side" && "k-overline--side", className)} style={style}>
      {children}
    </div>
  );
}

/** Weiße Karte mit feiner Linie. `rows`: Innenabstand für Zeilen (Trennlinien eingerückt). */
export function Card({ children, rows, className, style }: { children: ReactNode; rows?: boolean; className?: string; style?: CSSProperties }) {
  return (
    <div className={cx("k-card", rows && "k-card--rows", className)} style={style}>
      {children}
    </div>
  );
}

/** Abschnitt: Titel (17 halbfett), Karte mit Zeilen, leiser Satz darunter. */
export function Section({
  title,
  footer,
  aside,
  children,
  plain,
}: {
  title?: ReactNode;
  footer?: ReactNode;
  /** rechts neben dem Titel (z. B. Textknopf) */
  aside?: ReactNode;
  children: ReactNode;
  /** ohne Karte (Inhalt bringt eigene Flächen mit) */
  plain?: boolean;
}) {
  return (
    <section className="k-section">
      {(title || aside) && (
        <div className="k-section__head">
          {title && <h2 className="k-section__title">{title}</h2>}
          {aside}
        </div>
      )}
      {plain ? children : <Card rows>{children}</Card>}
      {footer && <p className="k-section__foot">{footer}</p>}
    </section>
  );
}

/** Zeile in einer Karte: Titel, Beschreibung, Bedienelement rechts. */
export function Row({
  title,
  description,
  children,
  off,
  stack,
  lead,
  className,
}: {
  title: ReactNode;
  description?: ReactNode;
  children?: ReactNode;
  /** gedämpft und nicht bedienbar */
  off?: boolean;
  /** Bedienelement unter dem Text statt rechts */
  stack?: boolean;
  /** links vor dem Text (Icon-Kachel, Bereit-Zeichen) */
  lead?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cx("k-row", off && "k-row--off", stack && "k-row--stack", className)}>
      {lead}
      <div className="k-row__text">
        <div className="k-row__title">{title}</div>
        {description && <div className="k-row__desc">{description}</div>}
        {stack && children && <div className="k-row__below">{children}</div>}
      </div>
      {!stack && children && <div className="k-row__ctl">{children}</div>}
    </div>
  );
}

/** Hinweis über einer Karte: `warn` (orange), `success` (grün = erledigt). */
export function Notice({
  tone,
  icon,
  title,
  children,
  actions,
}: {
  tone: "warn" | "success";
  icon?: ReactNode;
  title: ReactNode;
  children?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className={cx("k-notice", `k-notice--${tone}`)} role={tone === "warn" ? "alert" : "status"}>
      {icon && <span className="k-notice__icon">{icon}</span>}
      <div className="k-notice__body">
        <div className="k-notice__title">{title}</div>
        {children && <div className="k-notice__detail">{children}</div>}
        {actions && <div className="k-notice__actions">{actions}</div>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Zustand

export type ReadyState = "ok" | "missing" | "optional";

/** Bereit-Zeichen: grünes Häkchen (erledigt), roter Punkt (fehlt), gestrichelter Kreis (optional/offen). */
export function StatusIcon({ state }: { state: ReadyState }) {
  if (state === "ok") {
    return (
      <span className="k-status k-status--ok" aria-label="erledigt">
        <Check size={13} strokeWidth={2.6} />
      </span>
    );
  }
  return <span className={cx("k-status", `k-status--${state}`)} aria-label={state === "missing" ? "fehlt" : "optional"} />;
}

/** Kleiner Punkt (Status in der Seitenleiste). */
export function Dot({ tone }: { tone: "ok" | "missing" | "idle" }) {
  return <i className={cx("k-dot", `k-dot--${tone}`)} aria-hidden="true" />;
}

/** Zähler-Plakette (offene Schritte). */
export function Badge({ children }: { children: ReactNode }) {
  return <span className="k-badge">{children}</span>;
}

// ---------------------------------------------------------------- Dialoge

/** Icon-Kachel (Königsblau auf accentSoft). */
export function IconTile({ children, size }: { children: ReactNode; size?: "lg" }) {
  return <span className={cx("k-tile", size === "lg" && "k-tile--lg")}>{children}</span>;
}

/** Punkt mit Icon-Kachel, Titel und Satz (Dialoge, „So arbeitet Knips“). */
export function Point({ icon, title, children }: { icon: ReactNode; title: ReactNode; children?: ReactNode }) {
  return (
    <div className="k-point">
      <IconTile>{icon}</IconTile>
      <div className="k-point__text">
        <div className="k-point__title">{title}</div>
        {children && <div className="k-point__desc">{children}</div>}
      </div>
    </div>
  );
}

/**
 * Dialog-Karte wie die Onboarding-Karte wie in der App-Familie: Mono-Überschrift, Titel 22, Text, Knöpfe rechts
 * (sekundär, primär Tinte). `footer` links neben den Knöpfen (z. B. Kästchen).
 */
export function DialogCard({
  overline,
  title,
  children,
  actions,
  footer,
  className,
  role = "dialog",
}: {
  overline?: ReactNode;
  title: ReactNode;
  children?: ReactNode;
  actions?: ReactNode;
  footer?: ReactNode;
  className?: string;
  role?: "dialog" | "alertdialog";
}) {
  return (
    <div className={cx("k-dialog", className)} role={role} aria-modal="true">
      {overline && <Overline>{overline}</Overline>}
      <h1 className="k-dialog__title">{title}</h1>
      {children && <div className="k-dialog__body">{children}</div>}
      {(actions || footer) && (
        <div className="k-dialog__foot">
          {footer && <div className="k-dialog__extra">{footer}</div>}
          <div className="k-dialog__actions">{actions}</div>
        </div>
      )}
    </div>
  );
}
