// Attrappen für Menü und Leisten (nur ohne Tauri).
import { inTauri, registerMock } from "../shared/ipc";

if (!inTauri) {
  // Zustand je nach Ansicht: Leiste = läuft, Countdown = 3, Menü nur mit ?rec=1 laufend.
  registerMock("get_recording_state", () => {
    const h = window.location.hash;
    if (h.startsWith("#/rec-countdown")) return { phase: "countdown", countdown: 3, elapsed: 0 };
    if (h.startsWith("#/rec-controls") || h.includes("rec=1")) return { phase: "recording", countdown: 0, elapsed: 83 };
    return { phase: "idle", countdown: 0, elapsed: 0 };
  });
  for (const c of ["recording_stop", "scroll_finish"]) registerMock(c, () => undefined);
}
