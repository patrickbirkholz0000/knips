// Bereit-Check (Einstellungen → Start, Status unten in der Seitenleiste) aus vorhandenen Daten:
// Kürzel registriert (`hotkeyFailures`), Druck-Taste (`snippingKeyEnabled`), Video (`mediaAvailable`),
// Ablageordner erreichbar (`save_folder_ok`), Mikrofon (nur Hinweis — Windows meldet die Freigabe für
// Desktop-Apps nicht zuverlässig). „missing“ zählt als offener Schritt, „optional“ nicht.
import { api } from "../shared/ipc";
import type { Bootstrap } from "../shared/types";
import type { ReadyState } from "../shared/ui";
import { activeHotkeys, hotkeyTitle, usesPrintKey, type Pane } from "./support";

export interface ReadyAction {
  label: string;
  primary?: boolean;
  run: () => void;
}

export interface ReadyCheck {
  id: "capture" | "hotkeys" | "printKey" | "folder" | "microphone";
  state: ReadyState;
  title: string;
  detail: string;
  actions: ReadyAction[];
}

export function readiness(boot: Bootstrap, folderOk: boolean | null, go: (pane: Pane) => void): ReadyCheck[] {
  const s = boot.settings;
  const checks: ReadyCheck[] = [];

  checks.push(
    boot.mediaAvailable
      ? {
          id: "capture",
          state: "ok",
          title: "Bildschirm aufnehmen",
          detail: "Screenshots und Videos. Windows verlangt dafür keine Freigabe.",
          actions: [],
        }
      : {
          id: "capture",
          state: "missing",
          title: "Videos aufnehmen (Media Feature Pack)",
          detail: "Screenshots gehen. Für Videos fehlt dieser Windows-Ausgabe das Media Feature Pack.",
          actions: [{ label: "Installieren …", primary: true, run: () => void api.openUrl("ms-settings:optionalfeatures") }],
        },
  );

  const active = activeHotkeys(s);
  const failed = active.filter((a) => boot.hotkeyFailures.includes(a));
  checks.push(
    failed.length > 0
      ? {
          id: "hotkeys",
          state: "missing",
          title: "Tastaturkürzel",
          detail: `Von einer anderen App belegt: ${failed.map((a) => hotkeyTitle[a]).join(", ")}.`,
          actions: [{ label: "Kürzel ändern", primary: true, run: () => go("shortcuts") }],
        }
      : active.length === 0
        ? {
            id: "hotkeys",
            state: "optional",
            title: "Tastaturkürzel",
            detail: "Alle Kürzel sind aus. Aufnehmen geht dann über das Symbol in der Taskleiste.",
            actions: [{ label: "Einschalten", run: () => go("shortcuts") }],
          }
        : {
            id: "hotkeys",
            state: "ok",
            title: "Tastaturkürzel",
            detail: "Funktionieren in jeder App, auch wenn Knips im Hintergrund läuft.",
            actions: [],
          },
  );

  if (usesPrintKey(s)) {
    checks.push(
      boot.snippingKeyEnabled
        ? {
            id: "printKey",
            state: "missing",
            title: "Druck-Taste",
            detail: "Windows öffnet mit Druck noch den Bildschirmausschnitt. Überlass die Taste ganz Knips.",
            actions: [{ label: "Übernehmen", primary: true, run: () => void api.snippingTakeover() }],
          }
        : {
            id: "printKey",
            state: "ok",
            title: "Druck-Taste",
            detail: "Gehört Knips. Der Bildschirmausschnitt von Windows reagiert nicht darauf.",
            actions: [],
          },
    );
  }

  const folder = boot.paths.saveFolder;
  checks.push(
    folderOk === null
      ? { id: "folder", state: "optional", title: "Ablageordner", detail: "Wird geprüft …", actions: [] }
      : folderOk
        ? {
            id: "folder",
            state: "ok",
            title: "Ablageordner",
            detail: folder,
            actions: [{ label: "Öffnen", run: () => void api.openSaveFolder() }],
          }
        : {
            id: "folder",
            state: "missing",
            title: "Ablageordner",
            detail: `Nicht erreichbar: ${folder}. Dort kann Knips nichts speichern.`,
            actions: [{ label: "Anderen wählen", primary: true, run: () => go("storage") }],
          },
  );

  checks.push(
    s.recordingMicrophone
      ? {
          id: "microphone",
          state: "optional",
          title: "Mikrofon (optional)",
          detail: "Für Videos mit Ton. Windows muss Desktop-Apps den Zugriff erlauben.",
          actions: [{ label: "Windows-Einstellungen …", run: () => void api.openUrl("ms-settings:privacy-microphone") }],
        }
      : {
          id: "microphone",
          state: "optional",
          title: "Mikrofon (optional)",
          detail: "Aus. Nur nötig, wenn du in Videos sprechen willst.",
          actions: [{ label: "Einstellen", run: () => go("recording") }],
        },
  );

  return checks;
}

export const openSteps = (checks: ReadyCheck[]) => checks.filter((c) => c.state === "missing").length;
