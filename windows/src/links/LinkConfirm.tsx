// Fenster „Aufnahme per Link?“ (`#/link-confirm/<fullscreen|last|record>`), wie LinkConfirmView in
// LinkCommands.swift: Jede App und jede Webseite kann knips://-Links öffnen, deshalb fragt Knips nach, bevor
// ein Link sofort aufnimmt. „Aufnehmen“ (⏎) wirkt erst nach der Schutzzeit, „Abbrechen“/Esc/Schließen
// verwirft, „Nicht mehr fragen“ gilt nur zusammen mit „Aufnehmen“.
//
// Schutzzeit: beginnt erst, wenn Rust bestätigt, dass das Fenster sichtbar ist (`linkConfirmShown`), und
// beginnt neu, sobald hier getippt wird (wer gerade in einer anderen App schrieb, als die Rückfrage den Fokus
// bekam, bestätigt nichts mit dem nächsten ⏎). ⏎ zählt nur als frischer Druck: keine Tastenwiederholung,
// und war ⏎ schon vor Ablauf der Schutzzeit unten, muss die Taste erst einmal losgelassen werden. Rust prüft
// die Schutzzeit noch einmal.
import { useEffect, useRef, useState } from "react";
import { Crop, Monitor, Video } from "lucide-react";
import { api } from "../shared/ipc";
import { Button, Checkbox, DialogCard, IconTile } from "../shared/ui";
import "./link-confirm.css";

/** Schutzzeit wie `LinkConfirmWindowController.armDelay` (0,6 s). */
const ARM_DELAY_MS = 600;

const MESSAGES: Record<string, string> = {
  fullscreen: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den ganzen Bildschirm aufnehmen.",
  last: "Eine andere App oder Webseite möchte über einen knips://-Link sofort den zuletzt aufgenommenen Bereich erneut aufnehmen.",
  record: "Eine andere App oder Webseite möchte über einen knips://-Link eine Bildschirmaufnahme (Video) starten.",
};

/** Was der Link tun will — als Kachel über dem Text (nur Anzeige). */
const ACTIONS: Record<string, { title: string; icon: JSX.Element }> = {
  fullscreen: { title: "Ganzen Bildschirm aufnehmen", icon: <Monitor size={17} strokeWidth={2} /> },
  last: { title: "Letzten Bereich wiederholen", icon: <Crop size={17} strokeWidth={2} /> },
  record: { title: "Bildschirmaufnahme starten", icon: <Video size={17} strokeWidth={2} /> },
};

/** Tasten, die die Schutzzeit nicht neu starten (Bedienung der Rückfrage selbst, reine Umschalttasten). */
const CONTROL_KEYS = new Set(["Enter", "Escape", "Tab", "Shift", "Control", "Alt", "AltGraph", "Meta", "CapsLock"]);

export default function LinkConfirm({ params }: { params: string[]; query?: URLSearchParams }) {
  const kind = Object.prototype.hasOwnProperty.call(MESSAGES, params[0] ?? "") ? params[0] : "fullscreen";
  const message = MESSAGES[kind];
  const action = ACTIONS[kind];
  const [armed, setArmed] = useState(false);
  // Nur Anzeige: zählt jeden Start der Schutzzeit, damit der leise Fortschritt im Knopf von vorn beginnt.
  const [armStart, setArmStart] = useState(0);
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
    let alive = true;
    let visible = false;
    let armTimer = 0;
    let pollTimer = 0;
    // Tasten, die gedrückt waren, ohne zu zählen (zu früh oder Wiederholung): erst nach dem Loslassen
    // zählt ein neuer Druck.
    const held = new Set<string>();

    const arm = () => {
      window.clearTimeout(armTimer);
      state.current.armed = false;
      setArmed(false);
      if (!visible) return;
      setArmStart((n) => n + 1);
      armTimer = window.setTimeout(() => {
        state.current.armed = true;
        setArmed(true);
      }, ARM_DELAY_MS);
    };

    // Bis Rust „sichtbar“ bestätigt, alle 100 ms nachfragen (das Fenster entsteht unsichtbar).
    const report = () => {
      void api
        .linkConfirmShown()
        .then((ok) => {
          if (!alive) return;
          if (ok) {
            visible = true;
            arm();
          } else pollTimer = window.setTimeout(report, 100);
        })
        .catch(() => alive && (pollTimer = window.setTimeout(report, 300)));
    };
    report();

    /** Frischer Druck nach Ablauf der Schutzzeit? Sonst bis zum Loslassen gesperrt. */
    const fresh = (e: KeyboardEvent) => {
      if (e.repeat || !state.current.armed || held.has(e.key)) {
        held.add(e.key);
        return false;
      }
      return true;
    };

    const keydown = (e: KeyboardEvent) => {
      const target = e.target instanceof HTMLElement ? e.target : null;
      if (e.key === "Escape") {
        e.preventDefault();
        decide(false);
        return;
      }
      if (e.key === "Enter") {
        e.preventDefault(); // Knöpfe nie vom Browser auslösen lassen (der wiederholt bei gehaltener Taste)
        // Auf einem Knopf mit Fokus löst ⏎ wie unter Windows üblich diesen Knopf aus — „Abbrechen“ immer.
        if (target?.dataset.act === "cancel") {
          decide(false);
          return;
        }
        if (!fresh(e)) return;
        held.add(e.key);
        decide(true);
        return;
      }
      if (e.key === " " && target?.dataset.act) {
        // Leertaste auf einem Knopf: „Abbrechen“ immer, „Aufnehmen“ und „Nicht mehr fragen“ nur als
        // frischer Druck (der Browser klickt beim Loslassen).
        if (target.dataset.act === "cancel") return;
        if (!fresh(e)) e.preventDefault();
        return;
      }
      if (!CONTROL_KEYS.has(e.key)) arm(); // getippt → Schutzzeit von vorn
    };
    const keyup = (e: KeyboardEvent) => {
      if (held.delete(e.key) && e.key === " ") e.preventDefault(); // kein Klick aus gesperrtem Druck
    };
    window.addEventListener("keydown", keydown, true);
    window.addEventListener("keyup", keyup, true);
    return () => {
      alive = false;
      window.clearTimeout(armTimer);
      window.clearTimeout(pollTimer);
      window.removeEventListener("keydown", keydown, true);
      window.removeEventListener("keyup", keyup, true);
    };
  }, []);

  return (
    <div className="lc">
      <DialogCard
        overline="Link von außen"
        title="Aufnahme per Link?"
        footer={
          <Checkbox data-act="dont-ask" checked={dontAskAgain} disabled={!armed} onChange={setDontAskAgain}>
            Nicht mehr fragen
          </Checkbox>
        }
        actions={
          <>
            <Button data-act="cancel" onClick={() => decide(false)}>
              Abbrechen
            </Button>
            <Button variant="primary" className="lc-confirm" data-act="confirm" disabled={!armed} onClick={() => decide(true)}>
              Aufnehmen
              {!armed && armStart > 0 && <span key={armStart} className="lc-arm" style={{ animationDuration: `${ARM_DELAY_MS}ms` }} aria-hidden="true" />}
            </Button>
          </>
        }
      >
        <div className="lc-action">
          <IconTile>{action.icon}</IconTile>
          <div>
            <div className="lc-action__title">{action.title}</div>
            <div className="lc-action__link">knips://{kind}</div>
          </div>
        </div>
        <p>{message}</p>
        <p className="lc-hint">Hast du das nicht selbst ausgelöst, klicke auf „Abbrechen“.</p>
      </DialogCard>
    </div>
  );
}
