import { useEffect, useRef, useState, type ReactNode } from "react";
import { AlertTriangle, ArrowRight, CheckCircle2, Check, ExternalLink, EyeOff, Folder, Info, Keyboard, Lock, Mic, ScanLine, Settings as Cog, Share, CircleDot } from "lucide-react";
import { api, events } from "../shared/ipc";
import { useBootstrap, useItems } from "../shared/hooks";
import { bytes } from "../shared/format";
import type { Bootstrap, HotkeyAction, RedactStyle, Settings as S } from "../shared/types";
import "./settings.css";
import "./mock";
import { Card, Checkbox, Choice, Div, Notice, Pill, Row, SecondsField, Switch } from "./parts";
import RedactPreview from "./RedactPreview";
import { hotkeyTitle, kindExample, kindLongTitle, kindOrder, styleTitle, VK_SNAPSHOT } from "./support";

type Pane = "general" | "shortcuts" | "recording" | "redaction" | "export" | "storage" | "privacy" | "about";

const PANES: { id: Pane; title: string; icon: ReactNode; summary: string }[] = [
  { id: "general", title: "Allgemein", icon: <Cog size={16} />, summary: "Was nach einem Screenshot oder einer Aufnahme passiert." },
  { id: "shortcuts", title: "Tastaturkürzel", icon: <Keyboard size={16} />, summary: "Globale Kürzel für Screenshots und Aufnahmen. Sie funktionieren in jeder App." },
  { id: "recording", title: "Bildschirmaufnahme", icon: <CircleDot size={16} />, summary: "Größe, Format und Darstellung deiner Bildschirmvideos." },
  { id: "redaction", title: "Zensur", icon: <EyeOff size={16} />, summary: "Wie sensible Stellen in Bildern und Videos unkenntlich werden." },
  { id: "export", title: "Export", icon: <Share size={16} />, summary: "Größe und Format von Screenshots, GIFs und Videos." },
  { id: "storage", title: "Ablage", icon: <Folder size={16} />, summary: "Wo deine Aufnahmen liegen und wie lange Originale bleiben." },
  { id: "privacy", title: "Datenschutz", icon: <Lock size={16} />, summary: "Windows-Freigaben und Nutzungsstatistik. Aufnahmen bleiben auf deinem PC." },
  { id: "about", title: "Über Knips", icon: <Info size={16} />, summary: "Screenshots und kurze Bildschirmaufnahmen — mit Zensur für Bilder und Videos." },
];

function initialPane(params: string[]): Pane {
  const p = params[0] as Pane;
  if (PANES.some((x) => x.id === p)) return p;
  try {
    const s = localStorage.getItem("settingsPane") as Pane;
    if (PANES.some((x) => x.id === s)) return s;
  } catch {}
  return "general";
}

export default function Settings({ params }: { params: string[]; query?: URLSearchParams }) {
  const boot = useBootstrap();
  const [pane, setPane] = useState<Pane>(() => initialPane(params));
  useEffect(() => {
    if (PANES.some((x) => x.id === params[0])) setPane(params[0] as Pane);
  }, [params[0]]);
  const choose = (p: Pane) => {
    setPane(p);
    try { localStorage.setItem("settingsPane", p); } catch {}
  };
  const cur = PANES.find((p) => p.id === pane)!;
  const pageRef = useRef<HTMLDivElement>(null);
  useEffect(() => { pageRef.current?.scrollTo(0, 0); }, [pane]);
  useEffect(() => { document.title = "Knips – Einstellungen"; }, []);

  return (
    <div className="st">
      <aside className="st-side">
        <div className="st-brand">
          <img src="/icon.png" alt="" />
          <div><b>Knips</b><span>Einstellungen</span></div>
        </div>
        {PANES.map((p) => (
          <div key={p.id}>
            <button className={`st-nav${p.id === pane ? " sel" : ""}`} onClick={() => choose(p.id)}>
              <span className="ic">{p.icon}</span>
              <span className="lbl">{p.title}</span>
              {p.id === pane && <ArrowRight size={13} strokeWidth={2.5} />}
            </button>
            {(p.id === "shortcuts" || p.id === "export") && <div className="st-sep" />}
          </div>
        ))}
        <div className="st-ver">Version {boot?.version ?? "1.0.0"}</div>
      </aside>
      <div className="st-page" ref={pageRef}>
        <div className="st-head">
          <h1>{cur.title}</h1>
          <p>{cur.summary}</p>
        </div>
        {boot && <div className="st-body">{renderPane(pane, boot)}</div>}
      </div>
    </div>
  );
}

function renderPane(pane: Pane, boot: Bootstrap) {
  switch (pane) {
    case "general": return <General boot={boot} />;
    case "shortcuts": return <Shortcuts boot={boot} />;
    case "recording": return <Recording boot={boot} />;
    case "redaction": return <Redaction boot={boot} />;
    case "export": return <Export boot={boot} />;
    case "storage": return <Storage boot={boot} />;
    case "privacy": return <Privacy boot={boot} />;
    case "about": return <About boot={boot} />;
  }
}

const set = (patch: Partial<S>) => void api.setSettings(patch);

function General({ boot: { settings: s } }: { boot: Bootstrap }) {
  const timed = s.showQuickAccess && s.quickAccessAutoHide;
  return (
    <>
      <Card title="Nach einer Aufnahme">
        <Row title="In die Zwischenablage kopieren"><Switch on={s.copyToClipboard} onChange={(v) => set({ copyToClipboard: v })} /></Row>
        <Div />
        <Row title="Editor sofort öffnen"><Switch on={s.openEditorAfterCapture} onChange={(v) => set({ openEditorAfterCapture: v })} /></Row>
        <Div />
        <Row title="Auslöser-Ton"><Switch on={s.playSound} onChange={(v) => set({ playSound: v })} /></Row>
      </Card>
      <Card
        title="Karten unten links"
        footer="Ein Klick auf die Karte öffnet die Aufnahme. Über die Knöpfe darauf kopierst du, pinnst an oder kopierst den Text, und du kannst die Karte in eine andere App ziehen. Solange die Maus darauf liegt, bleibt sie stehen."
      >
        <Row title="Karte anzeigen"><Switch on={s.showQuickAccess} onChange={(v) => set({ showQuickAccess: v })} /></Row>
        <Div />
        <Row title="Automatisch ausblenden">
          <Switch on={s.quickAccessAutoHide} disabled={!s.showQuickAccess} onChange={(v) => set({ quickAccessAutoHide: v })} />
        </Row>
        <Div />
        <Row title="Anzeigedauer" subtitle={timed ? "So lange bleibt die Karte stehen" : "Die Karte bleibt, bis du sie schließt"} off={!timed}>
          <SecondsField value={s.quickAccessSeconds} min={1} max={3600} onChange={(n) => set({ quickAccessSeconds: n })} />
        </Row>
      </Card>
      <Card title="Start">
        <Row title="Mit Windows starten"><Switch on={s.launchAtLogin} onChange={(v) => set({ launchAtLogin: v })} /></Row>
      </Card>
      <Card
        title="Befehle per Link"
        footer="Sonst fragt Knips nach, bevor knips://fullscreen, knips://last oder knips://record aufnehmen – solche Links kann jede App und jede Webseite öffnen."
      >
        <Row title="Aufnahmen per Link ohne Rückfrage">
          <Switch on={s.linkCaptureWithoutConfirm} onChange={(v) => set({ linkCaptureWithoutConfirm: v })} />
        </Row>
      </Card>
    </>
  );
}

const GROUPS: [string, HotkeyAction[]][] = [
  ["Bildschirmfotos", ["captureArea", "captureWindow", "captureFullscreen", "captureLastArea", "captureScrolling", "captureText"]],
  ["Bildschirmaufnahme", ["toggleRecording"]],
  ["Sonstiges", ["pinClipboard"]],
];

function Shortcuts({ boot }: { boot: Bootstrap }) {
  const { settings: s, hotkeyLabels, hotkeyFailures } = boot;
  const [recording, setRecording] = useState<HotkeyAction | null>(null);

  useEffect(() => {
    const off = events.hotkeyRecorded(() => setRecording(null));
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") { setRecording((r) => (r ? (api.hotkeyRecordCancel(), null) : r)); }
    };
    window.addEventListener("keydown", key);
    return () => {
      off.then((f) => f());
      window.removeEventListener("keydown", key);
      api.hotkeyRecordCancel();
    };
  }, []);

  const active = (a: HotkeyAction) => !!s.hotkeys[a] && !s.disabledHotkeys.includes(a);
  const usesPrint = (Object.keys(s.hotkeys) as HotkeyAction[]).some((a) => active(a) && s.hotkeys[a]!.vk === VK_SNAPSHOT);
  const toggle = (a: HotkeyAction, on: boolean) =>
    set({ disabledHotkeys: on ? s.disabledHotkeys.filter((x) => x !== a) : [...s.disabledHotkeys, a] });
  const startRec = (a: HotkeyAction) => {
    if (recording === a) { api.hotkeyRecordCancel(); setRecording(null); return; }
    setRecording(a);
    api.hotkeyRecord(a);
  };

  return (
    <>
      {boot.snippingKeyEnabled && usesPrint && (
        <Notice tone="orange" icon={<AlertTriangle size={17} fill="currentColor" stroke="#fff" />}
          title="Windows belegt die Druck-Taste noch selbst"
          detail="Windows öffnet mit der Druck-Taste den Bildschirmausschnitt. Knips fängt die Taste trotzdem ab – sauberer ist es, sie Knips ganz zu überlassen.">
          <Pill kind="primary" onClick={() => api.snippingTakeover()}>Druck-Taste für Knips übernehmen</Pill>
        </Notice>
      )}
      {s.tookSnippingKey && (
        <Notice tone="green" icon={<CheckCircle2 size={17} fill="currentColor" stroke="#fff" />}
          title="Knips hat die Druck-Taste übernommen"
          detail="Der Bildschirmausschnitt von Windows reagiert nicht mehr darauf.">
          <Pill onClick={() => api.snippingRestore()}>Druck-Taste an Windows zurückgeben</Pill>
        </Notice>
      )}
      {GROUPS.map(([title, actions]) => (
        <Card key={title} title={title}>
          {actions.map((a, i) => {
            const combo = s.hotkeys[a];
            const on = active(a);
            const rec = recording === a;
            const label = hotkeyLabels[a];
            return (
              <div key={a}>
                {i > 0 && <Div />}
                <div className="st-row st-sc">
                  <Checkbox on={on} disabled={!combo} onChange={(v) => toggle(a, v)} />
                  <div className="tx"><div className={`t${on ? "" : " dim"}`}>{hotkeyTitle[a]}</div></div>
                  {on && hotkeyFailures.includes(a) && (
                    <span className="st-warn" title="Bereits von einer anderen App belegt."><AlertTriangle size={16} color="var(--s-red)" fill="currentColor" stroke="#fff" /></span>
                  )}
                  <button className={`st-cap${rec ? " rec" : ""}${!rec && !label ? " empty" : ""}`} title="Klicken und neue Tastenkombination drücken" onClick={() => startRec(a)}>
                    {rec ? "Tasten drücken …" : label ?? "Nicht belegt"}
                  </button>
                </div>
              </div>
            );
          })}
        </Card>
      ))}
      <div className="st-pills">
        <Pill onClick={() => api.hotkeysResetDefaults()}>Windows-Belegung</Pill>
        <Pill onClick={() => api.hotkeysPresetMac()}>Mac-Belegung</Pill>
        <Pill onClick={() => api.openUrl("ms-settings:easeofaccess-keyboard")}>Tastenkombinationen von Windows …</Pill>
      </div>
      <p className="st-note">Mac-Belegung: Win+Umschalt+4/2/3/5 – mit Mac-Tastatur am PC dieselben Griffe wie am Mac.</p>
      <p className="st-note">Kürzel anklicken und die neue Kombination drücken. Rücktaste entfernt, Esc bricht ab. Standard wie bei Windows: Druck Bereich (Leertaste: Fenster), Alt+Druck Fenster, Strg+Druck Bildschirm, Umschalt+Druck Video.</p>
    </>
  );
}

function Recording({ boot: { settings: s, hotkeyLabels } }: { boot: Bootstrap }) {
  return (
    <>
      <Card title="Video" footer="Gemessen am Vollbild je 4 Sekunden: Retina-H.264 2,2 MB · 1×-H.264 1,2 MB · 1×-HEVC 0,9 MB. HEVC spielt nicht jeder PC ab.">
        <Row title="Größe">
          <Choice value={s.recordingAtScreenSize} options={[[true, "Bildschirmgröße (1×)"], [false, "Volle Auflösung (2×)"]]} onChange={(v) => set({ recordingAtScreenSize: v })} />
        </Row>
        <Div />
        <Row title="Format">
          <Choice value={s.recordingHevc} options={[[false, "H.264 – überall abspielbar"], [true, "HEVC – kleiner"]]} onChange={(v) => set({ recordingHevc: v })} />
        </Row>
        <Div />
        <Row title="Bildrate">
          <Choice value={s.recordingFps} options={[[30, "30 fps"], [60, "60 fps"]]} onChange={(v) => set({ recordingFps: v })} />
        </Row>
      </Card>
      <Card title="Darstellung">
        <Row title="Mauszeiger aufnehmen"><Switch on={s.recordingShowCursor} onChange={(v) => set({ recordingShowCursor: v })} /></Row>
        <Div />
        <Row title="Mausklicks hervorheben"><Switch on={s.recordingShowClicks} onChange={(v) => set({ recordingShowClicks: v })} /></Row>
        <Div />
        <Row title="Countdown 3 – 2 – 1"><Switch on={s.recordingCountdown} onChange={(v) => set({ recordingCountdown: v })} /></Row>
      </Card>
      <Card title="Ton" footer="Für gesprochene Erklärungen. Beim ersten Mal fragt Windows nach dem Mikrofon.">
        <Row title="Mikrofon aufnehmen"><Switch on={s.recordingMicrophone} onChange={(v) => set({ recordingMicrophone: v })} /></Row>
      </Card>
      <Card title="Stoppen">
        <Row title="Stopp-Leiste, Taskleisten-Symbol oder Kürzel">
          <span className="st-val" style={{ fontWeight: 600 }}>{hotkeyLabels.toggleRecording ?? "—"}</span>
        </Row>
      </Card>
    </>
  );
}

function Redaction({ boot: { settings: s } }: { boot: Bootstrap }) {
  const styles: RedactStyle[] = ["pixelate", "blur", "solid"];
  const toggleKind = (k: (typeof kindOrder)[number], on: boolean) =>
    set({ autoRedactKinds: on ? [...s.autoRedactKinds, k] : s.autoRedactKinds.filter((x) => x !== k) });
  return (
    <>
      <Card title="Standardstil" footer="„Balken“ ist am sichersten. Im Editor: Klick auf Text legt einen Balken über die Zeile, Alt-Klick über ein Wort; gezogene Balken wachsen auf ganze Wörter.">
        <div className="st-styles">
          {styles.map((st) => (
            <button key={st} className={`st-style${s.redactStyle === st ? " sel" : ""}`} onClick={() => set({ redactStyle: st })}>
              <RedactPreview style={st} />
              <span>{styleTitle[st]}</span>
            </button>
          ))}
        </div>
      </Card>
      <Card title="Auto-Zensur" footer="Sucht per Texterkennung nach E-Mails, IBANs, Schlüsseln usw. und legt Balken an. Normalerweise ziehst du Balken selbst — der Knopf ist deshalb aus.">
        <Row title="Knopf „Auto-Zensur“ in den Editoren"><Switch on={s.showAutoRedact} onChange={(v) => set({ showAutoRedact: v })} /></Row>
        {s.showAutoRedact && kindOrder.map((k) => (
          <div key={k}>
            <Div />
            <Row title={kindLongTitle[k]} subtitle={kindExample[k]}>
              <Switch on={s.autoRedactKinds.includes(k)} onChange={(v) => toggleKind(k, v)} />
            </Row>
          </div>
        ))}
      </Card>
    </>
  );
}

function Export({ boot: { settings: s } }: { boot: Bootstrap }) {
  const hint = s.exportAtScreenSize
    ? s.imageFormat === "png" ? "ca. 0,7–2 MB" : "ca. 0,25–0,6 MB"
    : s.imageFormat === "png" ? "ca. 2–7 MB" : "ca. 0,6–1,6 MB";
  return (
    <>
      <Card title="Screenshots" footer="Bildschirmgröße: so groß wie auf dem Bildschirm, beim Einfügen nicht doppelt so groß. Das Original bleibt für spätere Bearbeitung in voller Auflösung.">
        <Row title="Größe">
          <Choice value={s.exportAtScreenSize} options={[[true, "Bildschirmgröße (1×)"], [false, "Volle Auflösung (2×)"]]} onChange={(v) => set({ exportAtScreenSize: v })} />
        </Row>
        <Div />
        <Row title="Format">
          <Choice value={s.imageFormat} options={[["png", "PNG (verlustfrei)"], ["jpeg", "JPEG (kleiner)"]]} onChange={(v) => set({ imageFormat: v })} />
        </Row>
        <Div />
        <Row title="Vollbild-Screenshot"><span className="st-val">{hint}</span></Row>
      </Card>
      <Card title="GIF" footer="Ruhige Stellen werden zusammengefasst — das hält GIFs klein.">
        <Row title="Bildrate">
          <Choice value={s.gifFps} options={[[10, "10 fps"], [15, "15 fps"], [20, "20 fps"], [25, "25 fps"]]} onChange={(v) => set({ gifFps: v })} />
        </Row>
        <Div />
        <Row title="Maximale Breite">
          <Choice value={s.gifWidth} options={[[640, "640 px"], [800, "800 px"], [960, "960 px"], [1280, "1280 px"]]} onChange={(v) => set({ gifWidth: v })} />
        </Row>
      </Card>
      <Card title="Video">
        <Row title="Zensur und Kürzung" subtitle="werden beim Speichern eingerechnet, das Format bleibt erhalten" />
      </Card>
    </>
  );
}

function Storage({ boot }: { boot: Bootstrap }) {
  const s = boot.settings;
  const items = useItems();
  const [size, setSize] = useState<number | null>(null);
  const [confirm, setConfirm] = useState(false);
  const refresh = () => api.storageSize().then((n) => setSize(n ?? 0));
  useEffect(() => { refresh(); }, []);
  const folder = boot.paths.saveFolder;
  const name = folder.split(/[\\/]/).filter(Boolean).pop() ?? folder;
  const change = async () => {
    const f = await api.chooseSaveFolder();
    if (f) set({ saveFolder: f });
  };
  return (
    <>
      <Card title="Ablageordner" footer="Dort liegt immer die bearbeitete Fassung — zensierte Stellen sind darin endgültig unkenntlich.">
        <div className="st-folder">
          <svg width="30" height="30" viewBox="0 0 30 30"><path d="M3 8a2.5 2.5 0 0 1 2.5-2.5h6l2.5 3h10.5A2.5 2.5 0 0 1 27 11v11.5a2.5 2.5 0 0 1-2.5 2.5h-19A2.5 2.5 0 0 1 3 22.5Z" fill="#5ab0f2" /><path d="M3 12.5a2.5 2.5 0 0 1 2.5-2.5h19a2.5 2.5 0 0 1 2.5 2.5v10a2.5 2.5 0 0 1-2.5 2.5h-19A2.5 2.5 0 0 1 3 22.5Z" fill="#8fd0ff" /></svg>
          <div className="tx">
            <div className="n">{name}</div>
            <div className="p" title={folder}>{folder}</div>
          </div>
          <Pill onClick={change}>Ändern …</Pill>
          <Pill kind="primary" onClick={() => api.openSaveFolder()}>Öffnen</Pill>
        </div>
      </Card>
      <Card title="Originale" footer="Mit dem Original lässt sich eine Zensur später ändern. Es liegt getrennt in der App-Ablage und wird nie geteilt.">
        <Row title="Aufbewahren">
          <Choice value={s.retentionDays} options={[[7, "7 Tage"], [30, "30 Tage"], [90, "90 Tage"], [365, "1 Jahr"], [0, "Unbegrenzt"]]} onChange={(v) => set({ retentionDays: v })} />
        </Row>
        <Div />
        <Row title="Belegt"><span className="st-val">{size === null ? "…" : `${bytes(size)} · ${items.length} Aufnahmen`}</span></Row>
        <Div />
        <Row title="Alle Originale löschen" subtitle="Dateien im Ablageordner bleiben">
          <Pill kind="danger" onClick={() => setConfirm(true)}>Löschen …</Pill>
        </Row>
      </Card>
      {confirm && (
        <div className="st-scrim" onClick={() => setConfirm(false)}>
          <div className="st-sheet" onClick={(e) => e.stopPropagation()}>
            <h4>Alle Originale löschen?</h4>
            <p>Bereits gespeicherte Zensuren lassen sich danach nicht mehr ändern.</p>
            <div className="btns">
              <Pill onClick={() => setConfirm(false)}>Abbrechen</Pill>
              <Pill kind="danger" onClick={async () => { setConfirm(false); await api.purgeOriginals(); refresh(); }}>Löschen</Pill>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

function Perm({ icon, title, detail, children }: { icon: ReactNode; title: string; detail: string; children: ReactNode }) {
  return (
    <div className="st-perm">
      <span className="circ">{icon}</span>
      <div className="tx" style={{ flex: 1 }}>
        <div style={{ fontSize: 14 }}>{title}</div>
        <div style={{ fontSize: 12, color: "var(--s-muted)", marginTop: 2 }}>{detail}</div>
      </div>
      {children}
    </div>
  );
}

const Info1 = ({ text }: { text: string }) => (
  <div className="st-info"><Check size={14} strokeWidth={3} /><span>{text}</span></div>
);

const TELEMETRY_INFO_URL = "https://github.com/patrickbirkholz0000/knips#datenschutz";
const SOURCE_URL = "https://github.com/patrickbirkholz0000/knips";

function Privacy({ boot }: { boot: Bootstrap }) {
  return (
    <>
      <Card title="Nutzungsstatistik">
        <Row title="Anonyme Nutzungsstatistik" subtitle="Zählt nur, wie oft Funktionen genutzt werden – nie Bilder, Texte oder Dateinamen.">
          <Switch on={boot.telemetryConsent === true} onChange={(v) => void api.telemetrySetConsent(v)} />
        </Row>
        <Div />
        <button className="st-link" onClick={() => api.openUrl(TELEMETRY_INFO_URL)}>
          Was wird gesendet?<ExternalLink size={13} strokeWidth={2.2} />
        </button>
      </Card>
      <Card title="Freigaben">
        <Perm icon={<ScanLine size={16} />} title="Bildschirmaufnahme" detail="Windows verlangt für Bildschirmaufnahmen keine Freigabe.">
          <span className="st-ok"><CheckCircle2 size={15} />Erlaubt</span>
        </Perm>
        <Div />
        <Perm icon={<Mic size={16} />} title="Mikrofon" detail="Nur für Aufnahmen mit Kommentar">
          <Pill kind="primary" onClick={() => api.openUrl("ms-settings:privacy-microphone")}>Einstellungen öffnen …</Pill>
        </Perm>
      </Card>
      <Card title="So arbeitet Knips">
        <Info1 text="Texterkennung läuft auf diesem PC" /><Div />
        <Info1 text="Kein Konto. Nur wenn du zustimmst, sendet Knips anonyme Nutzungszähler" /><Div />
        <Info1 text="Geteilte Dateien sind immer die zensierte Fassung" /><Div />
        <Info1 text="„Text kopieren“ lässt zensierte Wörter weg" />
      </Card>
    </>
  );
}

function About({ boot }: { boot: Bootstrap }) {
  return (
    <>
      <Card>
        <div className="st-about">
          <img src="/icon.png" alt="" />
          <b>Knips</b>
          <span>Version {boot.version}</span>
        </div>
      </Card>
      <Card title="Funktionen">
        <Info1 text="Bereich, Fenster oder Bildschirm — Auswahl auf eingefrorenem Bild" /><Div />
        <Info1 text="Zensur-Balken mit Text-Erkennung, auch in Videos" /><Div />
        <Info1 text="Bildschirmvideos als MP4 oder GIF" /><Div />
        <Info1 text="Text aus Screenshots kopieren" />
      </Card>
      <Card title="Für Raycast & Co." footer="Bildschirm, letzter Bereich und Videostart fragen vorher nach (Allgemein → Befehle per Link).">
        <Row title="Befehle"><span className="st-mono">knips://area · window · fullscreen · record · text · last · menu</span></Row>
      </Card>
      <Card title="Lizenz">
        <Row title="© 2026 Patrick Birkholz" subtitle="Freie Software unter der GNU GPL v3 oder neuer — ohne jede Gewährleistung.">
          <Pill onClick={() => api.openUrl(SOURCE_URL)}>
            <span className="st-pill-ic">Quellcode<ExternalLink size={12} strokeWidth={2.4} /></span>
          </Pill>
        </Row>
      </Card>
    </>
  );
}
