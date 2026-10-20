// Fenster „Aufnahme per Link?“ (`#/link-confirm/<fullscreen|last|record>`), wie LinkConfirmView in
// LinkCommands.swift: Jede App und jede Webseite kann knips://-Links öffnen, deshalb fragt Knips nach, bevor
// ein Link sofort aufnimmt. „Aufnehmen“ (⏎) wirkt erst nach der Schutzzeit, „Abbrechen“/Esc/Schließen
// verwirft, „Nicht mehr fragen“ gilt nur zusammen mit „Aufnehmen“. Rust prüft die Schutzzeit noch einmal.
import { useEffect, useRef, useState } from "react";
import { api } from "../shared/ipc";
import "./link-confirm.css";

/** Schutzzeit wie `LinkConfirmWindowController.armDelay` (0,6 s). */
const ARM_DELAY_MS = 600;

const MESSAGES: Record<string, string> = {
  fullscreen: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den ganzen Bildschirm aufnehmen.",
  last: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den zuletzt aufgenommenen Bereich erneut aufnehmen.",
  record: "Eine andere App oder Webseite möchte über einen knips://-Link eine Bildschirmaufnahme (Video) starten.",
};

export default function LinkConfirm({ params }: { params: string[]; query?: URLSearchParams }) {
  const message = MESSAGES[params[0]] ?? MESSAGES.fullscreen;
  const [armed, setArmed] = useState(false);
  const [dontAskAgain, setDontAskAgain] = useState(false);
  const busy = useRef(false);
  const state = useRef({ armed, dontAskAgain });
  state.current = { armed, dontAskAgain };

  const decide = (approved: boolean) => {
    if (busy.current || (approved && !state.current.armed)) return;
    busy.current = true;
    void api
      .linkConfirmDecide(approved, approved && state.current.dontAskAgain)
      .finally(() => {
        busy.current = false;
      });
  };

  useEffect(() => {
    document.title = "Aufnahme per Link?";
    const timer = window.setTimeout(() => setArmed(true), ARM_DELAY_MS);
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        decide(false);
      } else if (e.key === "Enter") {
        // Auf einem Knopf mit Fokus löst ⏎ wie unter Windows üblich diesen Knopf aus (z. B. „Abbrechen“).
        if (e.target instanceof HTMLButtonElement) return;
        e.preventDefault();
        decide(true);
      }
    };
    window.addEventListener("keydown", key);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("keydown", key);
    };
  }, []);

  return (
    <div className="lc">
      <div className="lc-head">
        <img src="/icon.png" alt="" />
        <h1>Aufnahme per Link?</h1>
      </div>
      <p className="lc-msg">{message}</p>
      <p className="lc-hint">Hast du das nicht selbst ausgelöst, klicke auf „Abbrechen“.</p>
      <div className="lc-row">
        <label className="lc-check">
          <input type="checkbox" data-act="dont-ask" checked={dontAskAgain} onChange={(e) => setDontAskAgain(e.target.checked)} />
          Nicht mehr fragen
        </label>
        <button className="lc-btn" data-act="cancel" onClick={() => decide(false)}>
          Abbrechen
        </button>
        <button className="lc-btn primary" data-act="confirm" disabled={!armed} onClick={() => decide(true)}>
          Aufnehmen
        </button>
      </div>
    </div>
  );
}
