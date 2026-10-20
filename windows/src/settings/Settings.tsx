// Einstellungen (`#/settings/<bereich>`) wie die Einstellungen (docs/design.md, „Einstellungen“): dunkle
// Seitenleiste mit Zeichen + Wortmarke, Gruppen in Mono-Versalien, unten Bereit-Status und Version; rechts Papier
// mit Seitentitel, Abschnitten und weißen Karten. Erste Seite „Start“ mit Kürzeln und Bereit-Check.
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ArrowRight, EyeOff, Folder, House, Info, Keyboard, Lock, Share, SlidersHorizontal, Video } from "lucide-react";
import { api } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import { Brand } from "../shared/brand";
import type { Bootstrap } from "../shared/types";
import { Badge, cx, Dot, Overline } from "../shared/ui";
import "./settings.css";
import "./mock";
import { About, Export, General, Privacy, Recording, Redaction, Shortcuts, Storage } from "./panes";
import { openSteps, readiness } from "./readiness";
import Start from "./Start";
import { steps, type Pane } from "./support";

const PANES: Record<Pane, { title: string; nav?: string; icon: ReactNode; summary: string }> = {
  start: { title: "So geht’s", nav: "Start", icon: <House size={16} />, summary: "Knips nimmt auf, was du zeigst – und macht Privates unkenntlich, bevor du es teilst." },
  general: { title: "Allgemein", icon: <SlidersHorizontal size={16} />, summary: "Was nach einem Screenshot oder einer Aufnahme passiert." },
  shortcuts: { title: "Tastaturkürzel", icon: <Keyboard size={16} />, summary: "Globale Kürzel für Screenshots und Aufnahmen. Sie funktionieren in jeder App." },
  recording: { title: "Bildschirmaufnahme", icon: <Video size={16} />, summary: "Größe, Format und Darstellung deiner Bildschirmvideos." },
  redaction: { title: "Zensur", icon: <EyeOff size={16} />, summary: "Wie sensible Stellen in Bildern und Videos unkenntlich werden." },
  export: { title: "Export", icon: <Share size={16} />, summary: "Größe und Format von Screenshots, GIFs und Videos." },
  storage: { title: "Ablage", icon: <Folder size={16} />, summary: "Wo deine Aufnahmen liegen und wie lange Originale bleiben." },
  privacy: { title: "Datenschutz", icon: <Lock size={16} />, summary: "Windows-Freigaben und Nutzungsstatistik. Aufnahmen bleiben auf deinem PC." },
  about: { title: "Über Knips", icon: <Info size={16} />, summary: "Screenshots und kurze Bildschirmaufnahmen – mit Zensur für Bilder und Videos." },
};

const GROUPS: [string, Pane[]][] = [
  ["Start", ["start"]],
  ["Aufnahme", ["general", "shortcuts", "recording"]],
  ["Bearbeiten", ["redaction", "export"]],
  ["App", ["storage", "privacy", "about"]],
];

const isPane = (p: unknown): p is Pane => typeof p === "string" && Object.prototype.hasOwnProperty.call(PANES, p);

function initialPane(params: string[]): Pane {
  if (isPane(params[0])) return params[0];
  try {
    const s = localStorage.getItem("settingsPane");
    if (isPane(s)) return s;
  } catch {}
  return "start";
}

/** Ablageordner erreichbar? null = wird geprüft. Neu beim Wechsel des Ordners und wenn das Fenster nach vorn kommt. */
function useFolderOk(folder: string | undefined): boolean | null {
  const [ok, setOk] = useState<boolean | null>(null);
  useEffect(() => {
    if (!folder) return;
    let alive = true;
    const check = () =>
      api
        .saveFolderOk()
        .then((r) => alive && setOk(r !== false))
        .catch(() => alive && setOk(null));
    check();
    window.addEventListener("focus", check);
    return () => {
      alive = false;
      window.removeEventListener("focus", check);
    };
  }, [folder]);
  return ok;
}

export default function Settings({ params }: { params: string[]; query?: URLSearchParams }) {
  const boot = useBootstrap();
  const [pane, setPane] = useState<Pane>(() => initialPane(params));
  useEffect(() => {
    if (isPane(params[0])) setPane(params[0]);
  }, [params[0]]);
  const choose = (p: Pane) => {
    setPane(p);
    try {
      localStorage.setItem("settingsPane", p);
    } catch {}
  };
  const folderOk = useFolderOk(boot?.paths.saveFolder);
  const checks = useMemo(() => (boot ? readiness(boot, folderOk, choose) : []), [boot, folderOk]);
  const open = openSteps(checks);
  const cur = PANES[pane];
  const pageRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    pageRef.current?.scrollTo(0, 0);
  }, [pane]);
  useEffect(() => {
    document.title = "Knips – Einstellungen";
  }, []);

  return (
    <div className="st">
      <aside className="st-side">
        <div className="st-brand">
          <Brand size={22} />
        </div>
        <nav className="st-nav k-scroll" aria-label="Bereiche">
          {GROUPS.map(([group, panes]) => (
            <div key={group} className="st-group">
              <Overline tone="side" className="st-group__title">
                {group}
              </Overline>
              {panes.map((id) => {
                const p = PANES[id];
                const sel = id === pane;
                return (
                  <button key={id} type="button" className={cx("st-item", sel && "sel")} aria-current={sel ? "page" : undefined} onClick={() => choose(id)}>
                    <span className="st-item__icon">{p.icon}</span>
                    <span className="st-item__label">{p.nav ?? p.title}</span>
                    {id === "start" && open > 0 && !sel && <Badge>{open}</Badge>}
                    {sel && <ArrowRight className="st-item__arrow" size={14} strokeWidth={2.2} />}
                  </button>
                );
              })}
            </div>
          ))}
        </nav>
        <footer className="st-foot">
          <button type="button" className="st-status" onClick={() => choose("start")}>
            <Dot tone={!boot || folderOk === null ? "idle" : open > 0 ? "missing" : "ok"} />
            <span>{!boot ? "…" : open > 0 ? `${steps(open)} offen` : "Bereit"}</span>
          </button>
          <div className="st-version">Version {boot?.version ?? "…"}</div>
        </footer>
      </aside>
      <main className="st-page k-scroll" ref={pageRef}>
        <div className="st-inner">
          <header className="st-head">
            <h1>{cur.title}</h1>
            <p>{cur.summary}</p>
          </header>
          {boot && <div className="st-body">{renderPane(pane, boot, checks, choose)}</div>}
        </div>
      </main>
    </div>
  );
}

function renderPane(pane: Pane, boot: Bootstrap, checks: ReturnType<typeof readiness>, go: (p: Pane) => void) {
  switch (pane) {
    case "start":
      return <Start boot={boot} checks={checks} go={go} />;
    case "general":
      return <General boot={boot} />;
    case "shortcuts":
      return <Shortcuts boot={boot} />;
    case "recording":
      return <Recording boot={boot} />;
    case "redaction":
      return <Redaction boot={boot} />;
    case "export":
      return <Export boot={boot} />;
    case "storage":
      return <Storage boot={boot} />;
    case "privacy":
      return <Privacy boot={boot} />;
    case "about":
      return <About boot={boot} />;
  }
}
