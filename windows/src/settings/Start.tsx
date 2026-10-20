// Erste Seite der Einstellungen („So geht's“, wie in der App-Familie): deine Kürzel als Tastenkappen, drei Schritte
// und der Bereit-Check. Fehlt etwas, steht der Bereit-Check oben.
import type { Bootstrap, HotkeyAction } from "../shared/types";
import { Button, Card, Keys, Row, Section, StatusIcon } from "../shared/ui";
import type { ReadyCheck } from "./readiness";
import { openSteps } from "./readiness";
import { steps, type Pane } from "./support";

const SHOWN: [HotkeyAction, string][] = [
  ["captureArea", "Bereich"],
  ["captureFullscreen", "Bildschirm"],
  ["captureWindow", "Fenster"],
  ["toggleRecording", "Video starten/stoppen"],
];

const STEPS: [string, string][] = [
  ["Aufnehmen", "Bereich ziehen, Leertaste für ein Fenster"],
  ["Zensieren", "Balken über Privates, ein Klick auf Text genügt"],
  ["Teilen", "Kopieren und einfügen, immer die zensierte Fassung"],
];

export default function Start({ boot, checks, go }: { boot: Bootstrap; checks: ReadyCheck[]; go: (p: Pane) => void }) {
  const open = openSteps(checks);
  const s = boot.settings;
  const label = (a: HotkeyAction) => (s.hotkeys[a] && !s.disabledHotkeys.includes(a) ? boot.hotkeyLabels[a] : undefined);

  const shortcuts = (
    <Card className="st-howto">
      <div className="st-howto__head">
        <div>
          <div className="st-howto__title">Deine Kürzel</div>
          <div className="st-howto__sub">Funktionieren in jeder App. Knips wartet im Hintergrund.</div>
        </div>
        <Button onClick={() => go("shortcuts")}>Kürzel ändern</Button>
      </div>
      <div className="st-keygrid">
        {SHOWN.map(([a, title]) => {
          const combo = label(a);
          return (
            <div key={a} className="st-keytile">
              <div className="st-keytile__keys">{combo ? <Keys combo={combo} size="lg" /> : <span className="st-keytile__none">Nicht belegt</span>}</div>
              <div className="st-keytile__label">{title}</div>
            </div>
          );
        })}
      </div>
      <ol className="st-steps">
        {STEPS.map(([title, hint], i) => (
          <li key={title}>
            <div className="st-steps__head">
              <span className="st-steps__n">{i + 1}</span>
              <span className="st-steps__title">{title}</span>
            </div>
            <div className="st-steps__hint">{hint}</div>
          </li>
        ))}
      </ol>
    </Card>
  );

  const ready = (
    <Section title={open === 0 ? "Alles bereit" : open === 1 ? "Noch ein Schritt" : `Noch ${steps(open)}`}>
      {checks.map((c) => (
        <Row key={c.id} className={`st-check st-check--${c.id}`} lead={<StatusIcon state={c.state} />} title={c.title} description={c.detail}>
          {c.actions.map((a) => (
            <Button key={a.label} variant={a.primary ? "primary" : "secondary"} onClick={a.run}>
              {a.label}
            </Button>
          ))}
        </Row>
      ))}
    </Section>
  );

  return open > 0 ? (
    <>
      {ready}
      {shortcuts}
    </>
  ) : (
    <>
      {shortcuts}
      {ready}
    </>
  );
}
