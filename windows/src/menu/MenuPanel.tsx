import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  AppWindow, ArrowRight, BoxSelect, CircleDot, CircleStop, FileDown, Images, Monitor, Pin, Play, RotateCcw, ScanText,
} from "lucide-react";
import { api, events } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import { duration } from "../shared/format";
import type { CaptureItem, HotkeyAction } from "../shared/types";
import Thumbnail from "../shared/Thumbnail";
import { BrandMark, Wordmark } from "../shared/brand";
import { itemTitle } from "../shared/ipc";
import { useRecordingState } from "../recording/useRecordingState";
import { Keycaps } from "./Keycaps";
import "./menu.css";
import "./mock";

// Menü-Panel (docs/design.md, „Menü-Panel“): immer dunkel (--k-dark-*), unabhängig von Hell/Dunkel.
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
  // In den schmalen Kacheln „Umschalt+“ als ⇧ kürzen; wird es trotzdem eng, kürzt sich das Kürzel, nie der Titel.
  const shortcut = (a: HotkeyAction) => {
    const l = label(a);
    return l ? <span className="mp-shortcut">{l.replace("Umschalt+", "⇧+")}</span> : null;
  };
  const tile = (title: string, icon: React.ReactNode, action: HotkeyAction | null, run: () => void, red = false, off?: string) => (
    <button className={"menu-tile" + (red ? " red" : "") + (off ? " off" : "")} onClick={run} title={off}>
      <span className="ico">{icon}</span>
      <span className="label">{title}</span>
      {action && shortcut(action)}
    </button>
  );
  // Windows N/KN ohne Media Feature Pack: Klick zeigt den Hinweis (Rust), die Kachel ist gedämpft.
  const noVideo = boot?.mediaAvailable === false && !recording ? "Braucht das Media Feature Pack von Windows" : undefined;
  const perform = (a: HotkeyAction) => () => api.perform(a);
  const ic = { size: 15, strokeWidth: 1.8 };
  const areaKey = label("captureArea");

  return (
    <div className="mp" ref={ref}>
      <div className="mp-head">
        <span className="mp-brand">
          <BrandMark size={22} recording={recording} />
          <Wordmark size={18} recording={recording} />
        </span>
        <span className={"mp-status" + (recording ? " rec" : "")}>
          <i className="mp-dot" />
          {recording ? (
            <>
              Aufnahme <span className="mp-mono">{duration(rec.elapsed)}</span>
            </>
          ) : (
            "Bereit"
          )}
        </span>
      </div>

      <button className="mp-primary" onClick={perform("captureArea")}>
        <span className="mp-primary-ico">
          <BoxSelect size={17} strokeWidth={1.9} />
        </span>
        <span className="mp-primary-label">Bereich aufnehmen</span>
        {areaKey && <Keycaps label={areaKey} />}
      </button>

      <div className="mp-grid">
        {tile("Fenster", <AppWindow {...ic} />, "captureWindow", perform("captureWindow"))}
        {tile("Bildschirm", <Monitor {...ic} />, "captureFullscreen", perform("captureFullscreen"))}
        {tile(recording ? "Stoppen" : "Video", recording ? <CircleStop {...ic} /> : <CircleDot {...ic} />, "toggleRecording", perform("toggleRecording"), recording, noVideo)}
        {tile("Letzter Bereich", <RotateCcw {...ic} />, "captureLastArea", perform("captureLastArea"))}
        {tile("Scrollen", <FileDown {...ic} />, "captureScrolling", perform("captureScrolling"))}
        {tile("Text erfassen", <ScanText {...ic} />, "captureText", perform("captureText"))}
        {tile("Anpinnen", <Pin {...ic} />, "pinClipboard", perform("pinClipboard"))}
        {tile("Bild öffnen", <Images {...ic} />, null, () => api.openImageFile())}
      </div>

      {recent.length > 0 && (
        <>
          <div className="mp-divider" />
          <div className="mp-recent">
            <div className="mp-recent-head">
              <span className="mp-overline">Zuletzt</span>
              <button className="mp-all" onClick={() => api.openHistory()}>
                Alle anzeigen <ArrowRight size={12} strokeWidth={2.2} />
              </button>
            </div>
            <div className="mp-thumbs">
              {recent.map((item) => (
                <button
                  key={item.id}
                  className="mp-thumb"
                  title={itemTitle(item)}
                  draggable
                  onClick={() => api.itemOpen(item.id)}
                  onDragStart={(e) => {
                    e.preventDefault();
                    api.itemStartDrag(item.id);
                  }}
                >
                  <Thumbnail item={item} className="th" background="var(--k-dark-raised)" />
                  {item.kind !== "image" && (
                    <span className="kind">
                      {item.kind === "gif" ? <Images size={9} strokeWidth={2.4} /> : <Play size={8} strokeWidth={0} fill="currentColor" />}
                    </span>
                  )}
                </button>
              ))}
            </div>
          </div>
        </>
      )}

      <div className="mp-divider" />
      <div className="mp-foot">
        <button className="mp-foot-btn" onClick={() => api.openSettings()}>
          Einstellungen
        </button>
        <button className="mp-foot-btn" onClick={() => api.openSaveFolder()}>
          Ordner
        </button>
        <span className="sp" />
        <button className="mp-foot-btn" onClick={() => api.quitApp()}>
          Beenden
        </button>
      </div>
    </div>
  );
}
