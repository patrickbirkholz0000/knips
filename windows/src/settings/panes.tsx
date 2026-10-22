// Bereiche der Einstellungen außer „Start“ (Start.tsx). Inhalte und Funktionen wie bisher, Gestaltung nach
// docs/design.md: Abschnitte mit Titel, weiße Karten mit Zeilen, Bedienelemente rechts.
import { useEffect, useRef, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  Check,
  Cpu,
  ExternalLink,
  EyeOff,
  Film,
  Folder,
  Info,
  Keyboard,
  ScanText,
  ShieldCheck,
  SquareDashed,
  Type,
  UserX,
} from "lucide-react";
import { api, events } from "../shared/ipc";
import { useItems } from "../shared/hooks";
import { bytes } from "../shared/format";
import { BrandMark, Wordmark } from "../shared/brand";
import type { Bootstrap, HotkeyAction, RedactStyle, Settings as S } from "../shared/types";
import { Button, Card, DialogCard, Dot, IconTile, Keys, Notice, Point, Row, Section, Segmented, Select, StatusIcon, Switch } from "../shared/ui";
import { KeyButton, SecondsField } from "./parts";
import RedactPreview from "./RedactPreview";
import { hotkeyTitle, kindExample, kindLongTitle, kindOrder, styleTitle, usesPrintKey } from "./support";

const set = (patch: Partial<S>) => void api.setSettings(patch);

const TELEMETRY_INFO_URL = "https://github.com/patrickbirkholz0000/knips#datenschutz";
const SOURCE_URL = "https://github.com/patrickbirkholz0000/knips";
const FONT_LICENSES: [string, string, string][] = [
  ["Outfit", "© 2021 The Outfit Project Authors", "https://github.com/patrickbirkholz0000/knips/blob/main/windows/public/fonts/OFL-Outfit.txt"],
  ["JetBrains Mono", "© 2020 The JetBrains Mono Project Authors", "https://github.com/patrickbirkholz0000/knips/blob/main/windows/public/fonts/OFL-JetBrainsMono.txt"],
];

const warnIcon = <AlertTriangle size={17} strokeWidth={2.2} />;

// ---------------------------------------------------------------- Allgemein

export function General({ boot: { settings: s } }: { boot: Bootstrap }) {
  const timed = s.showQuickAccess && s.quickAccessAutoHide;
  return (
    <>
      <Section title="Nach einer Aufnahme">
        <Row title="In die Zwischenablage kopieren" description="Gleich einfügen, wo du willst.">
          <Switch on={s.copyToClipboard} onChange={(v) => set({ copyToClipboard: v })} label="In die Zwischenablage kopieren" />
        </Row>
        <Row title="Editor sofort öffnen">
          <Switch on={s.openEditorAfterCapture} onChange={(v) => set({ openEditorAfterCapture: v })} label="Editor sofort öffnen" />
        </Row>
        <Row title="Auslöser-Ton">
          <Switch on={s.playSound} onChange={(v) => set({ playSound: v })} label="Auslöser-Ton" />
        </Row>
      </Section>
      <Section
        title="Karten unten links"
        footer="Ein Klick auf die Karte öffnet die Aufnahme. Über die Knöpfe darauf kopierst du, pinnst an oder kopierst den Text, und du kannst die Karte in eine andere App ziehen. Solange die Maus darauf liegt, bleibt sie stehen."
      >
        <Row title="Karte anzeigen">
          <Switch on={s.showQuickAccess} onChange={(v) => set({ showQuickAccess: v })} label="Karte anzeigen" />
        </Row>
        <Row title="Automatisch ausblenden">
          <Switch on={s.quickAccessAutoHide} disabled={!s.showQuickAccess} onChange={(v) => set({ quickAccessAutoHide: v })} label="Automatisch ausblenden" />
        </Row>
        <Row title="Anzeigedauer" description={timed ? "So lange bleibt die Karte stehen." : "Die Karte bleibt, bis du sie schließt."} off={!timed}>
          <SecondsField value={s.quickAccessSeconds} min={1} max={3600} onChange={(n) => set({ quickAccessSeconds: n })} />
        </Row>
      </Section>
      <Section title="Darstellung und Start">
        <Row title="Darstellung" description="Gilt für alle Fenster. Menü und Leisten bleiben dunkel.">
          <Segmented
            label="Darstellung"
            value={s.appearance ?? "system"}
            options={[
              ["system", "System"],
              ["light", "Hell"],
              ["dark", "Dunkel"],
            ]}
            onChange={(v) => set({ appearance: v })}
          />
        </Row>
        <Row title="Mit Windows starten" description="Knips wartet still im Infobereich der Taskleiste.">
          <Switch on={s.launchAtLogin} onChange={(v) => set({ launchAtLogin: v })} label="Mit Windows starten" />
        </Row>
      </Section>
      <Section
        title="Befehle per Link"
        footer="Sonst fragt Knips nach, bevor knips://fullscreen, knips://last oder knips://record aufnehmen – solche Links kann jede App und jede Webseite öffnen."
      >
        <Row title="Aufnahmen per Link ohne Rückfrage">
          <Switch on={s.linkCaptureWithoutConfirm} onChange={(v) => set({ linkCaptureWithoutConfirm: v })} label="Aufnahmen per Link ohne Rückfrage" />
        </Row>
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Tastaturkürzel

const GROUPS: [string, HotkeyAction[]][] = [
  ["Bildschirmfotos", ["captureArea", "captureWindow", "captureFullscreen", "captureLastArea", "captureScrolling", "captureText"]],
  ["Bildschirmaufnahme", ["toggleRecording"]],
  ["Sonstiges", ["pinClipboard"]],
];

/** Unter dem Kürzel, solange Knips auf die neue Taste wartet. */
function RecordHint({ action, invalid }: { action: HotkeyAction; invalid?: string }) {
  return (
    <span className="st-rechint" data-hotkey-hint={action} role="status" aria-live="polite">
      {invalid && (
        <span className="st-fail st-rechint__bad">
          <Dot tone="missing" />
          {invalid}
        </span>
      )}
      <span>
        Taste oder Kombination drücken. <kbd>Esc</kbd> bricht ab, <kbd>Rücktaste</kbd> entfernt.
      </span>
    </span>
  );
}

export function Shortcuts({ boot }: { boot: Bootstrap }) {
  const { settings: s, hotkeyLabels, hotkeyFailures, hotkeyNotes } = boot;
  const [recording, setRecordingState] = useState<HotkeyAction | null>(null);
  const [rejected, setRejected] = useState<string | null>(null);
  // Letzte ungültige Taste der laufenden Aufnahme; `n` zählt mit, damit jeder Druck sichtbar antwortet.
  const [invalid, setInvalid] = useState<{ action: HotkeyAction; message: string; n: number } | null>(null);
  const recordingRef = useRef<HotkeyAction | null>(null);
  const setRecording = (a: HotkeyAction | null) => {
    recordingRef.current = a;
    setRecordingState(a);
    setInvalid(null);
  };
  const cancelRec = () => {
    if (!recordingRef.current) return;
    api.hotkeyRecordCancel();
    setRecording(null);
  };

  useEffect(() => {
    const off = events.hotkeyRecorded((r) => {
      if (r.result === "invalid") {
        // Die Aufnahme läuft weiter. Eine verspätete Meldung nach dem Ende zeigt nichts mehr an.
        if (recordingRef.current === r.action) {
          setInvalid((prev) => ({ action: r.action, message: r.message ?? "Diese Taste geht nicht.", n: (prev?.n ?? 0) + 1 }));
        }
        return;
      }
      setRecording(null);
      setRejected(r.result === "rejected" ? r.message ?? "Diese Kombination geht nicht." : null);
    });
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") cancelRec();
    };
    // Der Tastatur-Hook schluckt während der Aufnahme jede Taste, auch in anderen Apps — verliert das Fenster
    // den Fokus, endet die Aufnahme deshalb.
    window.addEventListener("keydown", key);
    window.addEventListener("blur", cancelRec);
    return () => {
      off.then((f) => f());
      window.removeEventListener("keydown", key);
      window.removeEventListener("blur", cancelRec);
      api.hotkeyRecordCancel();
    };
  }, []);

  const active = (a: HotkeyAction) => !!s.hotkeys[a] && !s.disabledHotkeys.includes(a);
  const toggle = (a: HotkeyAction, on: boolean) =>
    set({ disabledHotkeys: on ? s.disabledHotkeys.filter((x) => x !== a) : [...s.disabledHotkeys, a] });
  const startRec = (a: HotkeyAction) => {
    if (recording === a) {
      cancelRec();
      return;
    }
    setRecording(a);
    setRejected(null);
    api.hotkeyRecord(a);
  };

  return (
    <>
      {rejected && (
        <Notice tone="warn" icon={warnIcon} title="Kürzel nicht übernommen">
          {rejected}
        </Notice>
      )}
      {boot.snippingKeyEnabled && usesPrintKey(s) && (
        <Notice
          tone="warn"
          icon={warnIcon}
          title="Windows belegt die Druck-Taste noch selbst"
          actions={
            <Button variant="primary" onClick={() => api.snippingTakeover()}>
              Druck-Taste für Knips übernehmen
            </Button>
          }
        >
          Windows öffnet mit der Druck-Taste den Bildschirmausschnitt. Knips fängt die Taste trotzdem ab – sauberer ist es, sie Knips
          ganz zu überlassen.
        </Notice>
      )}
      {s.tookSnippingKey && (
        <Notice
          tone="success"
          icon={<CheckCircle2 size={17} strokeWidth={2.2} />}
          title="Knips hat die Druck-Taste übernommen"
          actions={<Button onClick={() => api.snippingRestore()}>Druck-Taste an Windows zurückgeben</Button>}
        >
          Der Bildschirmausschnitt von Windows reagiert nicht mehr darauf.
        </Notice>
      )}
      {GROUPS.map(([title, actions]) => (
        <Section key={title} title={title}>
          {actions.map((a) => {
            const combo = s.hotkeys[a];
            const on = active(a);
            const failed = on && hotkeyFailures.includes(a);
            const note = on ? hotkeyNotes[a] : undefined;
            const rec = recording === a;
            const bad = rec && invalid?.action === a ? invalid : null;
            return (
              <Row
                key={a}
                className={on ? "st-sc" : "st-sc st-sc--off"}
                title={hotkeyTitle[a]}
                description={
                  rec ? (
                    <RecordHint action={a} invalid={bad?.message} />
                  ) : failed ? (
                    <span className="st-fail">
                      <Dot tone="missing" />
                      Von einer anderen App belegt – wähl ein anderes Kürzel.
                    </span>
                  ) : note ? (
                    <span className="st-note" data-hotkey-note={a}>
                      <Info size={14} strokeWidth={2.2} aria-hidden="true" />
                      {note}
                    </span>
                  ) : undefined
                }
              >
                <KeyButton action={a} label={hotkeyLabels[a]} recording={rec} nudge={bad?.n ?? 0} dim={!on} onClick={() => startRec(a)} />
                <Switch on={on} disabled={!combo} onChange={(v) => toggle(a, v)} label={`${hotkeyTitle[a]} an`} />
              </Row>
            );
          })}
        </Section>
      ))}
      <Section
        title="Belegung"
        footer="Kürzel anklicken und die neue Taste oder Kombination drücken. Rücktaste entfernt, Esc bricht ab. Windows-Belegung: Druck Bereich (Leertaste: Fenster), Alt+Druck Fenster, Strg+Druck Bildschirm, Umschalt+Druck Video. Mac-Belegung: Win+Umschalt+4/2/3/5 – mit Mac-Tastatur am PC dieselben Griffe wie am Mac."
      >
        <Row title="Vorlage" description="Setzt alle Kürzel auf einmal.">
          <Button onClick={() => api.hotkeysResetDefaults()}>Windows-Belegung</Button>
          <Button onClick={() => api.hotkeysPresetMac()}>Mac-Belegung</Button>
        </Row>
        <Row title="Kürzel von Windows" description="Was Windows selbst belegt, siehst du in den Windows-Einstellungen.">
          <Button onClick={() => api.openUrl("ms-settings:easeofaccess-keyboard")}>
            Öffnen <ExternalLink size={14} strokeWidth={2.2} />
          </Button>
        </Row>
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Bildschirmaufnahme

export function Recording({ boot: { settings: s, hotkeyLabels, hevcAvailable, mediaAvailable } }: { boot: Bootstrap }) {
  return (
    <>
      {!mediaAvailable && (
        <Notice
          tone="warn"
          icon={warnIcon}
          title="Videos brauchen das Media Feature Pack"
          actions={
            <Button variant="primary" onClick={() => api.openUrl("ms-settings:optionalfeatures")}>
              Optionale Features öffnen …
            </Button>
          }
        >
          Diese Windows-Ausgabe (N/KN) enthält es nicht – Bildschirmaufnahmen und der Video-Editor sind deshalb aus. Screenshots
          funktionieren wie gewohnt. Nach der Installation Windows neu starten.
        </Notice>
      )}
      <Section
        title="Video"
        footer={
          hevcAvailable
            ? "Gemessen am Vollbild je 4 Sekunden: Retina-H.264 2,2 MB · 1×-H.264 1,2 MB · 1×-HEVC 0,9 MB. HEVC spielt nicht jeder PC ab."
            : "Gemessen am Vollbild je 4 Sekunden: Retina-H.264 2,2 MB · 1×-H.264 1,2 MB. HEVC gibt es mit der „HEVC-Videoerweiterung“ aus dem Microsoft Store."
        }
      >
        <Row title="Größe">
          <Select
            label="Größe"
            value={s.recordingAtScreenSize}
            options={[
              [true, "Bildschirmgröße (1×)"],
              [false, "Volle Auflösung (2×)"],
            ]}
            onChange={(v) => set({ recordingAtScreenSize: v })}
          />
        </Row>
        {hevcAvailable ? (
          <Row title="Format">
            <Select
              label="Format"
              value={s.recordingHevc}
              options={[
                [false, "H.264 – überall abspielbar"],
                [true, "HEVC – kleiner"],
              ]}
              onChange={(v) => set({ recordingHevc: v })}
            />
          </Row>
        ) : (
          <Row title="Format" description="HEVC ist auf diesem PC nicht verfügbar.">
            <span className="st-val">H.264</span>
          </Row>
        )}
        <Row title="Bildrate">
          <Segmented
            label="Bildrate"
            value={s.recordingFps}
            options={[
              [30, "30 fps"],
              [60, "60 fps"],
            ]}
            onChange={(v) => set({ recordingFps: v })}
          />
        </Row>
      </Section>
      <Section title="Im Video">
        <Row title="Mauszeiger aufnehmen">
          <Switch on={s.recordingShowCursor} onChange={(v) => set({ recordingShowCursor: v })} label="Mauszeiger aufnehmen" />
        </Row>
        <Row title="Mausklicks hervorheben">
          <Switch on={s.recordingShowClicks} onChange={(v) => set({ recordingShowClicks: v })} label="Mausklicks hervorheben" />
        </Row>
        <Row title="Countdown 3 – 2 – 1">
          <Switch on={s.recordingCountdown} onChange={(v) => set({ recordingCountdown: v })} label="Countdown" />
        </Row>
      </Section>
      <Section
        title="Ton"
        footer="Desktop-Apps fragt Windows meist nicht nach: Unter Datenschutz → Mikrofon müssen „Zugriff auf das Mikrofon“ und „Desktop-Apps den Zugriff erlauben“ an sein. Fehlt der Zugriff, sagt Knips Bescheid und das Video bleibt ohne Ton."
      >
        <Row title="Mikrofon aufnehmen" description="Für gesprochene Erklärungen.">
          <Switch on={s.recordingMicrophone} onChange={(v) => set({ recordingMicrophone: v })} label="Mikrofon aufnehmen" />
        </Row>
      </Section>
      <Section title="Stoppen">
        <Row title="Stopp-Leiste, Taskleisten-Symbol oder Kürzel">
          {hotkeyLabels.toggleRecording ? <Keys combo={hotkeyLabels.toggleRecording} /> : <span className="st-val">—</span>}
        </Row>
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Zensur

export function Redaction({ boot: { settings: s } }: { boot: Bootstrap }) {
  const styles: RedactStyle[] = ["pixelate", "blur", "solid"];
  const toggleKind = (k: (typeof kindOrder)[number], on: boolean) =>
    set({ autoRedactKinds: on ? [...s.autoRedactKinds, k] : s.autoRedactKinds.filter((x) => x !== k) });
  return (
    <>
      <Section
        title="Standardstil"
        plain
        footer="„Balken“ ist am sichersten. Im Editor: Klick auf Text legt einen Balken über die Zeile, Alt-Klick über ein Wort; gezogene Balken wachsen auf ganze Wörter."
      >
        <Card className="st-styles">
          {styles.map((st) => (
            <button
              key={st}
              type="button"
              role="radio"
              aria-checked={s.redactStyle === st}
              className={`st-style${s.redactStyle === st ? " sel" : ""}`}
              onClick={() => set({ redactStyle: st })}
            >
              <RedactPreview style={st} />
              <span>{styleTitle[st]}</span>
            </button>
          ))}
        </Card>
      </Section>
      <Section
        title="Auto-Zensur"
        footer="Sucht per Texterkennung nach E-Mails, IBANs, Schlüsseln usw. und legt Balken an. Normalerweise ziehst du Balken selbst – der Knopf ist deshalb aus."
      >
        <Row title="Knopf „Auto-Zensur“ in den Editoren">
          <Switch on={s.showAutoRedact} onChange={(v) => set({ showAutoRedact: v })} label="Knopf Auto-Zensur" />
        </Row>
        {s.showAutoRedact &&
          kindOrder.map((k) => (
            <Row key={k} title={kindLongTitle[k]} description={kindExample[k]}>
              <Switch on={s.autoRedactKinds.includes(k)} onChange={(v) => toggleKind(k, v)} label={kindLongTitle[k]} />
            </Row>
          ))}
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Export

export function Export({ boot: { settings: s } }: { boot: Bootstrap }) {
  const hint = s.exportAtScreenSize
    ? s.imageFormat === "png"
      ? "ca. 0,7–2 MB"
      : "ca. 0,25–0,6 MB"
    : s.imageFormat === "png"
      ? "ca. 2–7 MB"
      : "ca. 0,6–1,6 MB";
  return (
    <>
      <Section
        title="Screenshots"
        footer="Bildschirmgröße: so groß wie auf dem Bildschirm, beim Einfügen nicht doppelt so groß. Das Original bleibt für spätere Bearbeitung in voller Auflösung."
      >
        <Row title="Größe">
          <Select
            label="Größe"
            value={s.exportAtScreenSize}
            options={[
              [true, "Bildschirmgröße (1×)"],
              [false, "Volle Auflösung (2×)"],
            ]}
            onChange={(v) => set({ exportAtScreenSize: v })}
          />
        </Row>
        <Row title="Format">
          <Segmented
            label="Format"
            value={s.imageFormat}
            options={[
              ["png", "PNG"],
              ["jpeg", "JPEG"],
            ]}
            onChange={(v) => set({ imageFormat: v })}
          />
        </Row>
        <Row title="Vollbild-Screenshot" description={s.imageFormat === "png" ? "PNG ist verlustfrei." : "JPEG ist kleiner."}>
          <span className="st-val">{hint}</span>
        </Row>
      </Section>
      <Section title="GIF" footer="Ruhige Stellen werden zusammengefasst – das hält GIFs klein.">
        <Row title="Bildrate">
          <Select
            label="Bildrate"
            value={s.gifFps}
            options={[
              [10, "10 fps"],
              [15, "15 fps"],
              [20, "20 fps"],
              [25, "25 fps"],
            ]}
            onChange={(v) => set({ gifFps: v })}
          />
        </Row>
        <Row title="Maximale Breite">
          <Select
            label="Maximale Breite"
            value={s.gifWidth}
            options={[
              [640, "640 px"],
              [800, "800 px"],
              [960, "960 px"],
              [1280, "1280 px"],
            ]}
            onChange={(v) => set({ gifWidth: v })}
          />
        </Row>
      </Section>
      <Section title="Video">
        <Row title="Zensur und Kürzung" description="werden beim Speichern eingerechnet, das Format bleibt erhalten." />
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Ablage

export function Storage({ boot }: { boot: Bootstrap }) {
  const s = boot.settings;
  const items = useItems();
  const [size, setSize] = useState<number | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [folderError, setFolderError] = useState<string | null>(null);
  const refresh = () => api.storageSize().then((n) => setSize(n ?? 0));
  useEffect(() => {
    refresh();
  }, []);
  useEffect(() => {
    if (!confirm) return;
    const key = (e: KeyboardEvent) => e.key === "Escape" && setConfirm(false);
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [confirm]);
  const folder = boot.paths.saveFolder;
  const name = folder.split(/[\\/]/).filter(Boolean).pop() ?? folder;
  const change = async () => {
    const f = await api.chooseSaveFolder();
    if (!f) return;
    // Rust prüft den Ordner (Laufwerkspfad, kein Netzwerk- oder Gerätepfad, existiert) und lehnt sonst ab.
    try {
      await api.setSettings({ saveFolder: f });
      setFolderError(null);
    } catch (e) {
      setFolderError(String(e));
    }
  };
  return (
    <>
      <Section title="Ablageordner" footer="Dort liegt immer die bearbeitete Fassung – zensierte Stellen sind darin endgültig unkenntlich.">
        <Row
          className="st-folder"
          lead={
            <IconTile>
              <Folder size={17} strokeWidth={2} />
            </IconTile>
          }
          title={name}
          description={
            <span className="st-path" title={folder}>
              {folder}
            </span>
          }
        >
          <Button onClick={change}>Ändern …</Button>
          <Button variant="primary" onClick={() => api.openSaveFolder()}>
            Öffnen
          </Button>
        </Row>
        {folderError && (
          <div className="st-folder-error" role="alert">
            <AlertTriangle size={15} strokeWidth={2.2} />
            <span>{folderError}</span>
          </div>
        )}
      </Section>
      <Section title="Originale" footer="Mit dem Original lässt sich eine Zensur später ändern. Es liegt getrennt in der App-Ablage und wird nie geteilt.">
        <Row title="Aufbewahren">
          <Select
            label="Aufbewahren"
            value={s.retentionDays}
            options={[
              [7, "7 Tage"],
              [30, "30 Tage"],
              [90, "90 Tage"],
              [365, "1 Jahr"],
              [0, "Unbegrenzt"],
            ]}
            onChange={(v) => set({ retentionDays: v })}
          />
        </Row>
        <Row title="Belegt">
          <span className="st-val">{size === null ? "…" : `${bytes(size)} · ${items.length} Aufnahmen`}</span>
        </Row>
        <Row title="Alle Originale löschen" description="Dateien im Ablageordner bleiben.">
          <Button onClick={() => setConfirm(true)}>Löschen …</Button>
        </Row>
      </Section>
      {confirm && (
        <div className="k-scrim" onClick={() => setConfirm(false)}>
          <div onClick={(e) => e.stopPropagation()} style={{ width: "min(420px, 100%)" }}>
            <DialogCard
              role="alertdialog"
              overline="Originale"
              title="Alle Originale löschen?"
              actions={
                <>
                  <Button autoFocus onClick={() => setConfirm(false)}>
                    Abbrechen
                  </Button>
                  <Button
                    variant="primary"
                    onClick={async () => {
                      setConfirm(false);
                      await api.purgeOriginals();
                      refresh();
                    }}
                  >
                    Löschen
                  </Button>
                </>
              }
            >
              <p>Bereits gespeicherte Zensuren lassen sich danach nicht mehr ändern. Die Dateien im Ablageordner bleiben.</p>
            </DialogCard>
          </div>
        </div>
      )}
    </>
  );
}

// ---------------------------------------------------------------- Datenschutz

export function Privacy({ boot }: { boot: Bootstrap }) {
  const exclusion = boot.captureExclusionSupported;
  return (
    <>
      <Section title="Nutzungsstatistik">
        <Row title="Anonyme Nutzungsstatistik" description="Zählt nur, wie oft Funktionen genutzt werden – nie Bilder, Texte oder Dateinamen.">
          <Switch on={boot.telemetryConsent === true} onChange={(v) => void api.telemetrySetConsent(v)} label="Anonyme Nutzungsstatistik" />
        </Row>
        <Row title="Was wird gesendet?" description="Vertrag, Felder und Server stehen offen im Quellcode.">
          <Button onClick={() => api.openUrl(TELEMETRY_INFO_URL)}>
            Nachlesen <ExternalLink size={14} strokeWidth={2.2} />
          </Button>
        </Row>
      </Section>
      <Section title="Freigaben">
        <Row lead={<StatusIcon state="ok" />} title="Bildschirm aufnehmen" description="Windows verlangt für Bildschirmaufnahmen keine Freigabe.">
          <span className="st-ok">
            <Check size={15} strokeWidth={2.6} />
            Erlaubt
          </span>
        </Row>
        <Row
          lead={<StatusIcon state="optional" />}
          title="Mikrofon"
          description="Nur für Aufnahmen mit Kommentar – dort auch „Desktop-Apps den Zugriff erlauben“."
        >
          <Button onClick={() => api.openUrl("ms-settings:privacy-microphone")}>Windows-Einstellungen …</Button>
        </Row>
      </Section>
      <Section title="Bildschirm teilen" footer="Knips' eigene Bildschirmfotos zeigen nie Knips-Fenster.">
        <Row
          title="In Bildschirmübertragungen verbergen"
          description={
            exclusion
              ? "Teams, Discord, OBS und andere Apps, die deinen Bildschirm teilen oder aufnehmen, sehen Knips dann nicht – auch keine Originale im Editor."
              : "Geht erst ab Windows 10 Version 2004."
          }
          off={!exclusion}
        >
          <Switch
            on={boot.settings.hideFromScreenSharing}
            disabled={!exclusion}
            onChange={(v) => set({ hideFromScreenSharing: v })}
            label="In Bildschirmübertragungen verbergen"
          />
        </Row>
      </Section>
      <Section title="So arbeitet Knips" plain>
        <Card className="st-points">
          <Point icon={<Cpu size={17} strokeWidth={2} />} title="Texterkennung auf diesem PC">
            Nichts geht dafür ins Internet.
          </Point>
          <Point icon={<UserX size={17} strokeWidth={2} />} title="Kein Konto">
            Nur wenn du zustimmst, sendet Knips anonyme Nutzungszähler.
          </Point>
          <Point icon={<EyeOff size={17} strokeWidth={2} />} title="Geteilt wird die zensierte Fassung">
            Ablageordner, Kopieren und Herausziehen geben nie das Original weiter.
          </Point>
          <Point icon={<Type size={17} strokeWidth={2} />} title="„Text kopieren“ lässt Zensiertes weg">
            Wörter unter einem Balken kommen nicht mit.
          </Point>
        </Card>
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Über Knips

export function About({ boot }: { boot: Bootstrap }) {
  return (
    <>
      <Card className="st-about">
        <span className="st-about__icon" aria-hidden="true">
          <BrandMark size={52} ink="var(--k-dark-button)" accent="var(--k-dark-accent)" />
        </span>
        <Wordmark size={34} onPaper />
        <span className="st-about__ver">Version {boot.version}</span>
        <p>Freie Software (GPL) – ohne Konto, Aufnahmen bleiben auf deinem PC.</p>
      </Card>
      <Section title="Funktionen" plain>
        <Card className="st-points">
          <Point icon={<SquareDashed size={17} strokeWidth={2} />} title="Bereich, Fenster oder Bildschirm">
            Auswahl auf eingefrorenem Bild.
          </Point>
          <Point icon={<EyeOff size={17} strokeWidth={2} />} title="Zensur-Balken mit Texterkennung">
            In Bildern und in Videos.
          </Point>
          <Point icon={<Film size={17} strokeWidth={2} />} title="Bildschirmvideos">
            Als MP4 oder GIF.
          </Point>
          <Point icon={<ScanText size={17} strokeWidth={2} />} title="Text aus Screenshots kopieren" />
        </Card>
      </Section>
      <Section title="Für Raycast & Co." footer="Bildschirm, letzter Bereich und Videostart fragen vorher nach (Allgemein → Befehle per Link).">
        <Row title="Befehle" stack>
          <span className="st-mono">knips://area · window · fullscreen · record · text · last · menu</span>
        </Row>
      </Section>
      <Section title="Lizenz">
        <Row
          lead={
            <IconTile>
              <ShieldCheck size={17} strokeWidth={2} />
            </IconTile>
          }
          title="© 2026 Patrick Birkholz"
          description="Freie Software unter der GNU GPL v3 oder neuer – ohne jede Gewährleistung."
        >
          <Button onClick={() => api.openUrl(SOURCE_URL)}>
            Quellcode <ExternalLink size={14} strokeWidth={2.2} />
          </Button>
        </Row>
      </Section>
      <Section title="Schriften" footer="Beide unter der SIL Open Font License 1.1. Die Lizenztexte liegen neben den Schriften.">
        {FONT_LICENSES.map(([font, copyright, url]) => (
          <Row
            key={font}
            lead={
              <IconTile>
                {font === "Outfit" ? <Type size={17} strokeWidth={2} /> : <Keyboard size={17} strokeWidth={2} />}
              </IconTile>
            }
            title={<span className={font === "Outfit" ? undefined : "st-mono-title"}>{font}</span>}
            description={`${copyright} · SIL OFL 1.1`}
          >
            <Button onClick={() => api.openUrl(url)}>
              Lizenz <ExternalLink size={14} strokeWidth={2.2} />
            </Button>
          </Row>
        ))}
      </Section>
    </>
  );
}
