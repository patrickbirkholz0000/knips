import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  AppWindow, ArrowRight, BoxSelect, CircleDot, CircleStop, FileDown, Folder, Images, Monitor, Pin, Play, Power,
  RotateCcw, ScanText, Scan, Settings as Gear,
} from "lucide-react";
import { api, events } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import type { CaptureItem, HotkeyAction } from "../shared/types";
import Thumbnail from "../shared/Thumbnail";
import { itemTitle } from "../shared/ipc";
import { useRecordingState } from "../recording/useRecordingState";
import "./menu.css";
import "./mock";

export default function MenuPanel(_: { params: string[]; query: URLSearchParams }) {
  const boot = useBootstrap();
  const rec = useRecordingState();
  const recording = rec.phase === "recording" || rec.phase === "countdown";
  const [recent, setRecent] = useState<CaptureItem[]>([]);
  const ref = useRef<HTMLDivElement>(null);

  // Zuletzt-Liste beim Öffnen und bei Änderungen neu laden.
  useEffect(() => {
    let alive = true;
    const load = () => api.listItems().then((i) => alive && setRecent((i ?? []).slice(0, 4)));
    load();
    const offs = [events.menuOpened(load), events.itemsChanged((i) => alive && setRecent(i.slice(0, 4)))];
    return () => {
      alive = false;
      offs.forEach((o) => o.then((f) => f()));
    };
  }, []);

  // Höhe an Rust melden.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const report = () => api.menuResize(Math.ceil(el.getBoundingClientRect().height));
    report();
    const ro = new ResizeObserver(report);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && api.menuClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const label = (a: HotkeyAction) => boot?.hotkeyLabels[a];
  const shortcut = (a: HotkeyAction, compact = false) => {
    const l = label(a);
    // In den schmalen Kacheln „Umschalt+“ als ⇧ kürzen, damit der Titel nie abgeschnitten wird.
    return l ? <span className="menu-shortcut">{compact ? l.replace("Umschalt+", "⇧+") : l}</span> : null;
  };
  const tile = (title: string, icon: React.ReactNode, action: HotkeyAction | null, run: () => void, red = false) => (
    <button className={"menu-tile" + (red ? " red" : "")} onClick={run}>
      <span className="ico">{icon}</span>
      <span className="label">{title}</span>
      {action && shortcut(action, true)}
    </button>
  );
  const perform = (a: HotkeyAction) => () => api.perform(a);
  const ic = { size: 14, strokeWidth: 1.9 };

  return (
    <div className="menu" ref={ref}>
      <div className="menu-header">
        <Scan size={14} strokeWidth={2.4} color="rgba(255,255,255,0.85)" />
        <span className="title">Knips</span>
        {recording && <span className="rec">Aufnahme läuft</span>}
      </div>

      <button className="menu-primary" onClick={perform("captureArea")}>
        <BoxSelect size={15} strokeWidth={2} />
        <span>Bereich aufnehmen</span>
        <span className="grow" />
        {shortcut("captureArea")}
      </button>

      <div className="menu-grid">
        {tile("Fenster", <AppWindow {...ic} />, "captureWindow", perform("captureWindow"))}
        {tile("Bildschirm", <Monitor {...ic} />, "captureFullscreen", perform("captureFullscreen"))}
        {tile(recording ? "Stoppen" : "Video", recording ? <CircleStop {...ic} /> : <CircleDot {...ic} />, "toggleRecording", perform("toggleRecording"), recording)}
        {tile("Letzter Bereich", <RotateCcw {...ic} />, "captureLastArea", perform("captureLastArea"))}
        {tile("Scrollen", <FileDown {...ic} />, "captureScrolling", perform("captureScrolling"))}
        {tile("Text erfassen", <ScanText {...ic} />, "captureText", perform("captureText"))}
        {tile("Anpinnen", <Pin {...ic} />, "pinClipboard", perform("pinClipboard"))}
        {tile("Bild öffnen", <Images {...ic} />, null, () => api.openImageFile())}
      </div>

      {recent.length > 0 && (
        <>
          <div className="menu-divider" />
          <div className="menu-recent">
            <div className="menu-recent-head">
              <span className="t">Zuletzt</span>
              <button className="menu-all" onClick={() => api.openHistory()}>
                Alle anzeigen <ArrowRight size={11} strokeWidth={2.4} />
              </button>
            </div>
            <div className="menu-thumbs">
              {recent.map((item) => (
                <button
                  key={item.id}
                  className="menu-thumb"
                  title={itemTitle(item)}
                  draggable
                  onClick={() => api.itemOpen(item.id)}
                  onDragStart={(e) => {
                    e.preventDefault();
                    api.itemStartDrag(item.id);
                  }}
                >
                  <Thumbnail item={item} className="th" />
                  {item.kind !== "image" && (
                    <span className="kind">
                      {item.kind === "gif" ? <Images size={8} strokeWidth={2.6} color="#fff" /> : <Play size={8} strokeWidth={2.6} fill="#fff" color="#fff" />}
                    </span>
                  )}
                </button>
              ))}
            </div>
          </div>
        </>
      )}

      <div className="menu-divider" />
      <div className="menu-footer">
        <button className="menu-foot" onClick={() => api.openSettings()}>
          <Gear size={12} strokeWidth={2} /> Einstellungen
        </button>
        <button className="menu-foot" onClick={() => api.openSaveFolder()}>
          <Folder size={12} strokeWidth={2} /> Ordner
        </button>
        <span className="sp" />
        <button className="menu-foot" onClick={() => api.quitApp()}>
          <Power size={12} strokeWidth={2} /> Beenden
        </button>
      </div>
    </div>
  );
}
