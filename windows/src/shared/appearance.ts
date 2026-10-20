// Hell/Dunkel für jedes Fenster (docs/design.md, „Hell und Dunkel“): setzt <html data-theme="light|dark"> aus der
// Einstellung `appearance` (system/light/dark) und folgt bei „system“ dem Windows-Farbmodus. Menü, Pillen und
// Leisten nutzen die immer dunklen Tokens (--k-dark-*) und hängen davon nicht ab.
import { api, events } from "./ipc";
import type { Appearance } from "./types";

const media = window.matchMedia("(prefers-color-scheme: dark)");
let current: Appearance = "system";

function apply() {
  const dark = current === "dark" || (current === "system" && media.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

/** Einmal beim Start jedes Fensters aufrufen (main.tsx). */
export function startAppearance() {
  apply();
  media.addEventListener("change", apply);
  api.getBootstrap().then((b) => {
    current = b?.settings.appearance ?? "system";
    apply();
  });
  events.bootstrapChanged((b) => {
    current = b.settings.appearance ?? "system";
    apply();
  });
}
