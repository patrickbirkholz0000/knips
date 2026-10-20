// Fenster „Knips verbessern?“ (`#/consent`): einmal pro Start, solange die Frage zur anonymen
// Nutzungsstatistik nicht beantwortet ist (nie in Selbsttests, Test-Sandbox oder CI).
// Schließen ohne Wahl = nein, beim nächsten Start wird wieder gefragt. Inhalt wie im Vertrag (Mac gleich),
// gestaltet als Dialog-Karte (docs/design.md, „Dialoge“).
import { useEffect, useState } from "react";
import { BarChart3, EyeOff, SlidersHorizontal } from "lucide-react";
import { api } from "../shared/ipc";
import { Button, DialogCard, Point } from "../shared/ui";
import "./consent.css";

export default function Consent(_: { params: string[]; query: URLSearchParams }) {
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    document.title = "Knips";
  }, []);
  const answer = (yes: boolean) => {
    if (busy) return;
    setBusy(true);
    void api.telemetrySetConsent(yes).finally(() => setBusy(false));
  };
  return (
    <div className="cs">
      <DialogCard
        overline="Statistik"
        title="Knips verbessern?"
        actions={
          <>
            <Button disabled={busy} onClick={() => answer(false)}>
              Nein danke
            </Button>
            <Button variant="primary" disabled={busy} onClick={() => answer(true)}>
              Anonym mitzählen
            </Button>
          </>
        }
      >
        <p>Darf Knips anonym mitzählen, welche Funktionen wie oft genutzt werden?</p>
        <div className="cs-points">
          <Point icon={<BarChart3 size={17} strokeWidth={2} />} title="Nur Zähler">
            Wie „3 Screenshots“, dazu Version und Betriebssystem.
          </Point>
          <Point icon={<EyeOff size={17} strokeWidth={2} />} title="Nie Inhalte">
            Keine Bilder, Texte, Dateinamen oder Fensterinhalte.
          </Point>
          <Point icon={<SlidersHorizontal size={17} strokeWidth={2} />} title="Jederzeit änderbar">
            In den Einstellungen unter Datenschutz.
          </Point>
        </div>
      </DialogCard>
    </div>
  );
}
