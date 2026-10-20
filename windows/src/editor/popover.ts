// Kleine Popover der Werkzeugleiste (Rahmen, Farbe): schließen bei Klick daneben und bei Esc. Esc wird abgefangen,
// sonst schlösse der Editor (Esc ohne Auswahl = Fenster zu).
import { useEffect, type RefObject } from "react";

export function useDismiss(open: boolean, close: () => void, ref: RefObject<HTMLElement | null>) {
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) close();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        close();
      }
    };
    window.addEventListener("mousedown", down);
    window.addEventListener("keydown", key, true);
    return () => {
      window.removeEventListener("mousedown", down);
      window.removeEventListener("keydown", key, true);
    };
  }, [open, close, ref]);
}
