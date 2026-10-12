// Video-Editor (Fenster `#/video/<itemId>`): Kürzen und Zensieren; Rust rechnet beim Speichern/Export.
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

  if (error) return <div className="vid-root vid-center">Video konnte nicht geöffnet werden: {error}</div>;
  if (!model || !boot) return <div className="vid-root" />;
  return <Editor model={model} boot={boot} />;
}

function Editor({ model, boot }: { model: VideoModel; boot: NonNullable<ReturnType<typeof useBootstrap>> }) {
  const s = useVideoState(model);
  const [askClose, setAskClose] = useState(false);
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
    <div className="vid-root" onMouseDown={(e) => (e.target as HTMLElement).closest("button") && e.preventDefault()}>
      <div className="vid-toolbar">
        <EyeOff size={16} className="vid-dim-icon" />
        <span className="vid-hint">Rechteck ziehen = zensieren</span>
        <div className="vid-segment">
          {STYLES.map(({ id, title, icon: Icon }) => (
            <button key={id} className={activeStyle === id ? "on" : ""} onClick={() => model.setStyle(id)}>
              <Icon size={13} fill={id === "solid" ? "currentColor" : "none"} /> {title}
            </button>
          ))}
        </div>
        <div className="vid-spacer" />
        {settings.showAutoRedact && (
          <button
            className="vid-btn"
            disabled={busy}
            title="Erkennt E-Mails, IBANs, Telefonnummern, Schlüssel usw. in Einzelbildern (alle 0,5 s) und legt Zensurfelder an."
            onClick={() => void model.autoRedact(settings.autoRedactKinds)}
          >
            <WandSparkles size={14} /> Auto-Zensur
          </button>
        )}
        <button className="vid-btn" disabled={!s.canUndo} onClick={() => model.undo()} title="Rückgängig (Strg+Z)">
          <Undo2 size={14} />
        </button>
        <button
          className="vid-btn"
          disabled={busy}
          onClick={() => void model.exportGif()}
          title={`Als GIF exportieren (${settings.gifFps} fps, max. ${settings.gifWidth} px breit)`}
        >
          <Images size={14} /> GIF
        </button>
        <button className="vid-btn" onClick={() => void api.itemReveal(model.id)} title="Im Explorer zeigen">
          <FolderOpen size={14} />
        </button>
        <button className="vid-btn" disabled={busy} onClick={() => void model.copyFile()}>
          <Copy size={14} /> Kopieren
        </button>
        <button className="vid-btn prominent" disabled={busy} onClick={() => void saveAndClose()} title="Strg+Enter">
          Fertig
        </button>
      </div>
      <div className="vid-divider" />

      <div className="vid-stage-wrap">
        <Player model={model} />
        <div className="vid-overlay-slot">
          {busy ? (
            <div className="vid-pill busy">
              <div className="vid-progress">
                <div style={{ width: `${Math.round(s.progress * 100)}%` }} />
              </div>
              <span>{s.busy}</span>
              <button className="vid-cancel" onClick={() => model.cancel()}>Abbrechen</button>
            </div>
          ) : s.toast ? (
            <div className="vid-pill">
              {s.toast.error ? <CircleAlert size={15} color="rgb(255,69,58)" /> : <CircleCheck size={15} color="rgb(51,184,102)" />}
              <span>{s.toast.text}</span>
            </div>
          ) : null}
        </div>
      </div>

      <div className="vid-bottom">
        <div className="vid-row">
          <button className="vid-play" onClick={() => model.togglePlay()} title="Leertaste">
            {s.isPlaying ? <Pause size={15} fill="currentColor" /> : <Play size={15} fill="currentColor" style={{ marginLeft: 2 }} />}
          </button>
          <span className="vid-time">
            {preciseDuration(s.currentTime)} / {preciseDuration(model.duration)}
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
              <span className="vid-mono">
                {preciseDuration(sel.start)} – {preciseDuration(sel.end)}
              </span>
              <button className="vid-btn" onClick={() => model.selectedStartHere()} title="Zensur beginnt an der aktuellen Abspielposition">Ab hier</button>
              <button className="vid-btn" onClick={() => model.selectedEndHere()} title="Zensur endet an der aktuellen Abspielposition">Bis hier</button>
              <button className="vid-btn" onClick={() => model.selectedWholeClip()}>Ganze Länge</button>
              {!sel.track ? (
                <button
                  className="vid-btn"
                  disabled={busy}
                  onClick={() => void model.followSelected()}
                  title="Balken folgt dem Inhalt darunter, z. B. beim Scrollen — ab der aktuellen Position vor und zurück."
                >
                  <Scan size={14} /> Folgen
                </button>
              ) : (
                <button className="vid-btn" onClick={() => model.unfollowSelected()} title="Balken bleibt an der aktuellen Stelle stehen">
                  <Pin size={14} /> Fest
                </button>
              )}
              <button className="vid-btn" onClick={() => model.deleteSelected()}>
                <Trash2 size={14} /> Löschen
              </button>
            </>
          ) : (
            <span className="vid-note">
              {s.redactions.length === 0
                ? "Gelbe Griffe kürzen das Video. Leertaste spielt ab, ← → springen einzelne Bilder."
                : `${s.redactions.length} Zensurfeld${s.redactions.length === 1 ? "" : "er"} — anklicken, um Zeitraum oder Stil zu ändern.`}
            </span>
          )}
          <div className="vid-spacer" />
          {trimmed && <span className="vid-trimmed">Gekürzt auf {preciseDuration(s.trimEnd - s.trimStart)}</span>}
        </div>
      </div>

      {askClose && (
        <div className="vid-modal-back">
          <div className="vid-modal">
            <h3>Änderungen am Video speichern?</h3>
            <p>Zensur und Kürzung werden erst beim Speichern ins Video geschrieben.</p>
            <div className="vid-modal-actions">
              <button className="vid-btn prominent" onClick={() => { setAskClose(false); void saveAndClose(); }}>Speichern</button>
              <button className="vid-btn" onClick={closeWindow}>Verwerfen</button>
              <button className="vid-btn" onClick={() => setAskClose(false)}>Abbrechen</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
