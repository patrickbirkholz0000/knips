// Fenster „Knips verbessern?“ (`#/consent`): einmal pro Start, solange die Frage zur anonymen
// Nutzungsstatistik nicht beantwortet ist (nie in Selbsttests, Test-Sandbox oder CI).
// Schließen ohne Wahl = nein, beim nächsten Start wird wieder gefragt. Texte wie im Vertrag (Mac gleich).
import { useEffect, useState } from "react";
import { api } from "../shared/ipc";
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
      <div className="cs-head">
        <img src="/icon.png" alt="" />
        <h1>Knips verbessern?</h1>
      </div>
      <p>
        Darf Knips anonym mitzählen, welche Funktionen wie oft genutzt werden? Gesendet werden nur Zähler wie
        „3 Screenshots“, dazu Version und Betriebssystem. Nie Bilder, Texte, Dateinamen oder Fensterinhalte. Du
        kannst das jederzeit in den Einstellungen ändern.
      </p>
      <div className="cs-btns">
        <button className="cs-btn" disabled={busy} onClick={() => answer(false)}>
          Nein danke
        </button>
        <button className="cs-btn primary" disabled={busy} onClick={() => answer(true)}>
          Anonym mitzählen
        </button>
      </div>
    </div>
  );
}
