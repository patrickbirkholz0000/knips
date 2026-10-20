// Kürzel als Mono-Tastenkappen auf dunklem Grund („Alt+Druck“ → [Alt] [Druck]); docs/design.md, Menü-Panel.
import "./keycaps.css";

export function Keycaps({ label }: { label: string }) {
  // „+“ trennt die Tasten; ein einzelnes „+“ als Taste (Strg++) bleibt erhalten.
  const keys = label.split(/\+(?!$)/).filter(Boolean);
  return (
    <span className="kc" aria-label={label}>
      {keys.map((k, i) => (
        <kbd key={i} className="kc-key">
          {k}
        </kbd>
      ))}
    </span>
  );
}
