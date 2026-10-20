// Hell/Dunkel für jedes Fenster (docs/design.md, „Hell und Dunkel“): setzt <html data-theme="light|dark"> aus der
// Einstellung `appearance` (system/light/dark) und folgt bei „system“ dem Windows-Farbmodus. Menü, Pillen und
// Leisten nutzen die immer dunklen Tokens (--k-dark-*) und hängen davon nicht ab.
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, events } from "./ipc";
import type { Appearance } from "./types";

const media = window.matchMedia("(prefers-color-scheme: dark)");
let current: Appearance = "system";

function apply() {
  const dark = current === "dark" || (current === "system" && media.matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  // Titelleiste passend (sonst folgt sie dem Windows-Farbmodus). Nur Fenster mit „titlebar-theme“ dürfen das;
  // „system“ = null, damit Windows selbst entscheidet. Im Browser (Attrappe) gibt es kein Tauri-Fenster.
  if ("__TAURI_INTERNALS__" in window) {
    getCurrentWindow()
      .setTheme(current === "system" ? null : dark ? "dark" : "light")
      .catch(() => {});
  }
}

/** Einmal beim Start jedes Fensters aufrufen (main.tsx). */
export function startAppearance() {
  apply();
  media.addEventListener("change", apply);
  // Fenster ohne Berechtigung für `get_bootstrap` (Pins, Leisten — immer dunkel) bleiben beim Systemmodus.
  api
    .getBootstrap()
    .then((b) => {
      current = b?.settings.appearance ?? "system";
      apply();
    })
    .catch(() => {});
  events.bootstrapChanged((b) => {
    current = b.settings.appearance ?? "system";
    apply();
  });
}
