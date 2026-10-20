// Video-Editor (Fenster `#/video/<itemId>`): Kürzen und Zensieren; Rust rechnet beim Speichern/Export.
// Aussehen wie der Bild-Editor (docs/design.md, „Video-Editor“): Leiste oben mit Export-Knöpfen rechts, Video auf
// der fill-Fläche, Zeitleiste als Karte mit Königsblau-Spannen für die Zensur, Abspielkopf und Kürzen-Griffe in Tinte.
import { useEffect, useRef, useState } from "react";
import {
  CircleAlert, CircleCheck, Copy, EyeOff, FolderOpen, Grid3x3, Droplet, Images, Pause, Pin, Play, RectangleHorizontal,
  Scan, Trash2, Undo2, WandSparkles,
} from "lucide-react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, events, inTauri, itemTitle } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import { preciseDuration } from "../shared/format";
import type { RedactStyle, VideoSession } from "../shared/types";
import { useVideoState, VideoModel } from "./model";
import Player from "./Player";
import Timeline from "./Timeline";
import "./mock";
import "../editor/controls.css";
import "./video.css";

const STYLES: { id: RedactStyle; title: string; icon: typeof Grid3x3 }[] = [
  { id: "pixelate", title: "Verpixeln", icon: Grid3x3 },
  { id: "blur", title: "Unschärfe", icon: Droplet },
  { id: "solid", title: "Balken", icon: RectangleHorizontal },
];

export default function VideoEditor({ params }: { params: string[] }) {
  const id = params[0];
  const boot = useBootstrap();
  const [session, setSession] = useState<VideoSession | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [model, setModel] = useState<VideoModel | null>(null);

  useEffect(() => {
    api.videoOpen(id).then(setSession).catch((e) => setError(String(e)));
  }, [id]);

  useEffect(() => {
    if (!session || !boot || model) return;
    setModel(new VideoModel(session, boot.settings.redactStyle));
  }, [session, boot, model]);

  useEffect(() => () => model?.shutdown(), [model]);

  if (error)
    return (
      <div className="kc-root vid-root vid-center">
        <div className="vid-error" role="alert">
          <span className="vid-error-icon"><CircleAlert size={20} strokeWidth={2} /></span>
          <span className="kc-overline">Video</span>
          <h2>Video lässt sich nicht öffnen</h2>
          <p>{error}</p>
        </div>
      </div>
    );
  if (!model || !boot) return <div className="kc-root vid-root" />;
  return <Editor model={model} boot={boot} />;
}

function Editor({ model, boot }: { model: VideoModel; boot: NonNullable<ReturnType<typeof useBootstrap>> }) {
  const s = useVideoState(model);
  // Im Browser (Attrappe) zeigt `?ask=1` die Rückfrage beim Schließen, die sonst nur Tauri auslöst.
  const [askClose, setAskClose] = useState(() => !inTauri && location.hash.includes("ask=1"));
  const allowClose = useRef(false);
  const settings = boot.settings;
  const sel = model.selected;
  const busy = s.busy !== null;

  const closeWindow = () => {
    allowClose.current = true;
    if (inTauri) void getCurrentWindow().close();
  };
  const saveAndClose = async () => {
    if (await model.save()) closeWindow();
  };

  // Titel und Schließen mit Rückfrage bei ungespeicherten Änderungen
  useEffect(() => {
    document.title = itemTitle(s.item) || "Video";
    if (!inTauri) return;
    const win = getCurrentWindow();
    void win.setTitle(document.title).catch(() => {});
    const off = win.onCloseRequested((e) => {
      if (allowClose.current || !model.s.dirty) return;
      e.preventDefault();
      setAskClose(true);
    });
    return () => void off.then((f) => f());
  }, [model, s.item]);

  // Speicheranforderung von außen (z. B. Schließen über die Taskleiste)
  useEffect(() => {
    const off = events.editorSaveRequest((id) => id === model.id && void model.save());
    return () => void off.then((f) => f());
  }, [model]);

  // Tastatur: Leertaste, Entf, Esc, Pfeile, Strg+Z / S / Enter
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === "z") {
        e.preventDefault();
        model.undo();
      } else if (mod && e.key.toLowerCase() === "s") {
        e.preventDefault();
        void model.save();
      } else if (mod && e.key === "Enter") {
        e.preventDefault();
        if (!model.s.busy) void saveAndClose();
      } else if (mod || e.altKey) {
        return;
      } else if (e.key === " ") {
        e.preventDefault();
        model.togglePlay();
      } else if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault();
        model.deleteSelected();
      } else if (e.key === "Escape") {
        if (askClose) setAskClose(false);
        else model.select(null);
      } else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        const step = e.shiftKey ? 1 : 1 / 30;
        model.seek(model.s.currentTime + (e.key === "ArrowLeft" ? -step : step));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [model, askClose]);

  const trimmed = s.trimStart > 0.001 || s.trimEnd < model.duration - 0.001;
  const index = sel ? s.redactions.findIndex((r) => r.id === sel.id) : -1;
  const activeStyle = sel?.style ?? s.style;

  return (
    <div className="kc-root vid-root" onMouseDown={(e) => (e.target as HTMLElement).closest("button") && e.preventDefault()}>
      <div className="vid-toolbar">
        <div className="kc-group vid-props">
          <span className="vid-tool-icon" title="Rechteck ziehen = zensieren"><EyeOff size={17} strokeWidth={1.8} /></span>
          <span className="vid-hint">Rechteck ziehen = zensieren</span>
          <div className="kc-seg vid-segment">
            {STYLES.map(({ id, title, icon: Icon }) => (
              <button key={id} className={activeStyle === id ? "on" : ""} title={title} onClick={() => model.setStyle(id)}>
                <Icon size={14} strokeWidth={2.1} fill={id === "solid" ? "currentColor" : id === "blur" ? "currentColor" : "none"} fillOpacity={id === "blur" ? 0.25 : 1} />
                <span className="vid-label">{title}</span>
              </button>
            ))}
          </div>
        </div>
        <div className="vid-spacer" />
        <div className="vid-actions">
          {settings.showAutoRedact && (
            <button
              className="kc-btn kc-btn--accent vid-auto"
              disabled={busy}
              title="Erkennt E-Mails, IBANs, Telefonnummern, Schlüssel usw. in Einzelbildern (alle 0,5 s) und legt Zensurfelder an."
              onClick={() => void model.autoRedact(settings.autoRedactKinds)}
            >
              <WandSparkles size={15} strokeWidth={2} /> <span className="vid-label">Auto-Zensur</span>
            </button>
          )}
          <div className="kc-group">
            <button className="kc-tool" disabled={!s.canUndo} onClick={() => model.undo()} title="Rückgängig (Strg+Z)">
              <Undo2 size={17} strokeWidth={1.8} />
            </button>
            <button className="kc-tool" onClick={() => void api.itemReveal(model.id)} title="Im Explorer zeigen">
              <FolderOpen size={17} strokeWidth={1.8} />
            </button>
          </div>
          <button
            className="kc-btn kc-btn--secondary"
            disabled={busy}
            onClick={() => void model.exportGif()}
            title={`Als GIF exportieren (${settings.gifFps} fps, max. ${settings.gifWidth} px breit)`}
          >
            <Images size={15} strokeWidth={2} /> GIF
          </button>
          <button className="kc-btn kc-btn--secondary" disabled={busy} onClick={() => void model.copyFile()} title="Kopieren">
            <Copy size={15} strokeWidth={2} /> Kopieren
          </button>
          <button className="kc-btn kc-btn--primary" disabled={busy} onClick={() => void saveAndClose()} title="Strg+Enter">
            Fertig
          </button>
        </div>
      </div>

      <div className="vid-stage-wrap">
        <Player model={model} />
        <div className="vid-overlay-slot">
          {busy ? (
            <div className="kc-pill vid-pill busy">
              <div className="vid-progress">
                <div style={{ width: `${Math.round(s.progress * 100)}%` }} />
              </div>
              <span>{s.busy}</span>
              <span className="kc-mono vid-percent">{Math.round(s.progress * 100)} %</span>
              <button className="kc-btn kc-btn--quiet kc-btn--sm vid-cancel" onClick={() => model.cancel()}>Abbrechen</button>
            </div>
          ) : s.toast ? (
            <div className={`kc-pill vid-pill${s.toast.error ? " error" : ""}`} role={s.toast.error ? "alert" : "status"}>
              {s.toast.error ? <CircleAlert className="kc-err" size={16} strokeWidth={2} /> : <CircleCheck className="kc-ok" size={16} strokeWidth={2} />}
              <span>{s.toast.text}</span>
            </div>
          ) : null}
        </div>
      </div>

      <div className="vid-bottom">
        <div className="vid-row">
          <button className="vid-play" onClick={() => model.togglePlay()} title="Leertaste">
            {s.isPlaying ? <Pause size={15} fill="currentColor" strokeWidth={0} /> : <Play size={15} fill="currentColor" strokeWidth={0} style={{ marginLeft: 2 }} />}
          </button>
          <span className="kc-mono vid-time">
            <b>{preciseDuration(s.currentTime)}</b> / {preciseDuration(model.duration)}
          </span>
          <Timeline model={model} />
        </div>
        <div className="vid-selbar">
          {sel ? (
            <>
              <strong>
                Zensur {index + 1}
                {sel.auto ? " (auto)" : ""}
                {sel.track ? " · folgt" : ""}
              </strong>
              <span className="kc-mono vid-mono">
                {preciseDuration(sel.start)} – {preciseDuration(sel.end)}
              </span>
              <button className="kc-btn kc-btn--secondary kc-btn--sm" onClick={() => model.selectedStartHere()} title="Zensur beginnt an der aktuellen Abspielposition">Ab hier</button>
              <button className="kc-btn kc-btn--secondary kc-btn--sm" onClick={() => model.selectedEndHere()} title="Zensur endet an der aktuellen Abspielposition">Bis hier</button>
              <button className="kc-btn kc-btn--secondary kc-btn--sm" onClick={() => model.selectedWholeClip()}>Ganze Länge</button>
              {!sel.track ? (
                <button
                  className="kc-btn kc-btn--secondary kc-btn--sm"
                  disabled={busy}
                  onClick={() => void model.followSelected()}
                  title="Balken folgt dem Inhalt darunter, z. B. beim Scrollen — ab der aktuellen Position vor und zurück."
                >
                  <Scan size={14} /> Folgen
                </button>
              ) : (
                <button className="kc-btn kc-btn--secondary kc-btn--sm" onClick={() => model.unfollowSelected()} title="Balken bleibt an der aktuellen Stelle stehen">
                  <Pin size={14} /> Fest
                </button>
              )}
              <button className="kc-btn kc-btn--quiet kc-btn--sm" onClick={() => model.deleteSelected()}>
                <Trash2 size={14} /> Löschen
              </button>
            </>
          ) : (
            <span className="vid-note">
              {s.redactions.length === 0
                ? "Die Griffe an den Enden kürzen das Video. Leertaste spielt ab, ← → springen einzelne Bilder."
                : `${s.redactions.length} Zensurfeld${s.redactions.length === 1 ? "" : "er"} — anklicken, um Zeitraum oder Stil zu ändern.`}
            </span>
          )}
          <div className="vid-spacer" />
          {trimmed && (
            <span className="vid-trimmed">
              Gekürzt auf <span className="kc-mono">{preciseDuration(s.trimEnd - s.trimStart)}</span>
            </span>
          )}
        </div>
      </div>

      {askClose && (
        <div className="vid-modal-back">
          <div className="vid-modal" role="dialog" aria-modal="true" aria-labelledby="vid-modal-title">
            <span className="kc-overline">Ungespeichert</span>
            <h3 id="vid-modal-title">Änderungen am Video speichern?</h3>
            <p>Zensur und Kürzung werden erst beim Speichern ins Video geschrieben.</p>
            <div className="vid-modal-actions">
              <button className="kc-btn kc-btn--quiet" onClick={closeWindow}>Verwerfen</button>
              <div className="vid-spacer" />
              <button className="kc-btn kc-btn--secondary" onClick={() => setAskClose(false)}>Abbrechen</button>
              <button className="kc-btn kc-btn--primary" onClick={() => { setAskClose(false); void saveAndClose(); }}>Speichern</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
