// Bild-Editor (Fenster `#/editor/<itemId>?tool=redact`): Port von EditorWindow.swift, Aussehen nach docs/design.md.
import { useCallback, useEffect, useRef, useState } from "react";
import { CircleCheck, Minus, Plus } from "lucide-react";
import { api, events, fileUrl, inTauri, itemTitle } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import type { EditorSession, EditorTool, Settings } from "../shared/types";
import { CanvasController } from "./canvas";
import "./controls.css";
import "./editor.css";
import "./mock";
import { EditorModel, TOOL_KIND, useModel } from "./model";
import { render, type BaseImage } from "./renderer";
import { Toolbar, type EditorActions } from "./Toolbar";

type Action = "save" | "copy" | "pin" | "done";

async function loadImage(path: string): Promise<BaseImage> {
  const load = (cors: boolean) =>
    new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new Image();
      if (cors) img.crossOrigin = "anonymous";
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error(`Bild nicht ladbar: ${path}`));
      img.src = fileUrl(path);
    });
  // Ohne CORS-Header des Asset-Protokolls bliebe das Canvas „tainted“; dann geht es nur ohne.
  return load(true).catch(() => load(false));
}

export default function Editor({ params, query }: { params: string[]; query: URLSearchParams }) {
  const id = params[0];
  const boot = useBootstrap();
  const [session, setSession] = useState<EditorSession | null>(null);
  const [base, setBase] = useState<BaseImage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [model, setModel] = useState<EditorModel | null>(null);

  useEffect(() => {
    let alive = true;
    api.editorOpen(id)
      .then(async (s) => {
        if (!s) throw new Error("Aufnahme nicht gefunden");
        const img = await loadImage(s.originalPath);
        if (alive) {
          setSession(s);
          setBase(img);
        }
      })
      .catch((e) => alive && setError(String(e?.message ?? e)));
    return () => {
      alive = false;
    };
  }, [id]);

  useEffect(() => {
    if (!session || !base || !boot || model) return;
    const tool = (session.initialTool ?? (query.get("tool") as EditorTool | null)) || null;
    setModel(new EditorModel({ ...session, initialTool: tool }, base, boot.settings));
  }, [session, base, boot, model, query]);

  if (error) return <div className="kc-root ed-root ed-error">Bild nicht gefunden — {error}</div>;
  if (!model || !boot) return <div className="kc-root ed-root" />;
  return <EditorView model={model} settings={boot.settings} />;
}

function EditorView({ model, settings }: { model: EditorModel; settings: Settings }) {
  useModel(model);
  model.settings = settings;
  const stageRef = useRef<HTMLDivElement>(null);
  const sheetRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const controller = useRef<CanvasController | null>(null);
  const closing = useRef(false);
  const saving = useRef<Promise<unknown>>(Promise.resolve());
  const item = model.item;

  // Rendern in voller Auflösung → Rust (speichern / kopieren / anpinnen / fertig).
  const commit = useCallback(
    (action: Action) => {
      const run = async () => {
        model.commitPendingEdits();
        const doc = model.document;
        await api.editorStage(item.id, doc);
        const canvas = render(model.base, doc, model.scale, model.effects);
        const data = canvas.getContext("2d")!.getImageData(0, 0, canvas.width, canvas.height);
        return api.editorCommit(item.id, action, canvas.width, canvas.height, new Uint8Array(data.data.buffer));
      };
      const p = saving.current.then(run, run);
      saving.current = p.catch(() => {});
      return p;
    },
    [model, item.id],
  );

  const closeWindow = useCallback(async () => {
    if (inTauri) {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      await getCurrentWindow().close();
    } else window.close();
  }, []);

  const persist = useCallback(
    async (action: Action = "save") => {
      const was = model.dirty;
      model.dirty = false;
      try {
        await commit(action);
      } catch (e) {
        // Rust zeigt den Grund in einem Dialog; die Datei im Ablageordner hat noch den alten Stand.
        model.dirty = was;
        model.showToast("Nicht gespeichert – Datei im Ablageordner unverändert");
        throw e;
      }
    },
    [model, commit],
  );

  const actions: EditorActions = {
    save: () => {
      model.commitPendingEdits();
      if (model.dirty) void persist("save").then(() => model.showToast("Gespeichert"), () => {});
    },
    done: () => {
      model.commitPendingEdits();
      if (model.dirty) {
        closing.current = true;
        void persist("done").catch(() => (closing.current = false));
      } else void closeWindow();
    },
    copy: () => {
      model.commitPendingEdits();
      const was = model.dirty;
      model.dirty = false;
      commit("copy").then(
        () => model.showToast("In die Zwischenablage kopiert"),
        (e) => {
          model.dirty = was;
          // „Nicht gespeichert“: kopiert ist das Bild trotzdem, nur die Datei ist nicht aktualisiert.
          model.showToast(String(e).includes("Nicht gespeichert") ? "Kopiert, aber nicht gespeichert" : "Kopieren fehlgeschlagen");
        },
      );
    },
    copyText: () => {
      model.commitPendingEdits();
      void (async () => {
        await model.waitForText();
        const text = model.visibleText();
        if (!text) {
          model.showToast("Kein Text gefunden");
          void api.hud({ text: "Kein Text gefunden", icon: "search" });
          return;
        }
        await api.clipboardText(text);
        const n = text.split("\n").length;
        const msg = `Text kopiert · ${n} Zeile${n === 1 ? "" : "n"}`;
        model.showToast(msg);
        void api.hud({ text: msg, icon: "text" });
      })();
    },
    pin: () => {
      model.commitPendingEdits();
      void commit("pin").catch(() => model.showToast("Anpinnen fehlgeschlagen"));
    },
  };
  const actionsRef = useRef(actions);
  actionsRef.current = actions;

  // Canvas
  useEffect(() => {
    const c = new CanvasController(canvasRef.current!, stageRef.current!, model, { close: () => void closeWindow() }, sheetRef.current);
    controller.current = c;
    return () => c.dispose();
  }, [model, closeWindow]);

  // Fenstertitel
  useEffect(() => {
    const title = itemTitle(item);
    document.title = title;
    if (inTauri) void import("@tauri-apps/api/window").then(({ getCurrentWindow }) => getCurrentWindow().setTitle(title));
  }, [item]);

  // Schließen: wie windowShouldClose — bei Änderungen erst speichern.
  useEffect(() => {
    if (!inTauri) return;
    let off: (() => void) | undefined;
    void import("@tauri-apps/api/window").then(async ({ getCurrentWindow }) => {
      const win = getCurrentWindow();
      off = await win.onCloseRequested(async (e) => {
        if (closing.current) return;
        model.commitPendingEdits();
        if (!model.dirty) return;
        e.preventDefault();
        closing.current = true;
        try {
          await persist("save");
        } catch {
          closing.current = false;
          return;
        }
        await win.destroy();
      });
    });
    return () => off?.();
  }, [model, persist]);

  // Speicheranforderung aus Rust (z. B. Schließen über die Taskleiste)
  useEffect(() => {
    const off = events.editorSaveRequest((rid) => {
      if (rid === item.id && model.dirty) void persist("save").catch(() => {});
    });
    return () => void off.then((f) => f());
  }, [model, item.id, persist]);

  // Tastenkürzel mit Strg
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t?.tagName === "INPUT") return;
      if (!(e.ctrlKey || e.metaKey) || e.altKey) return;
      const k = e.key.toLowerCase();
      const a = actionsRef.current;
      if (k === "z") { e.preventDefault(); e.shiftKey ? model.redo() : model.undo(); }
      else if (k === "y") { e.preventDefault(); model.redo(); }
      else if (k === "c") { e.preventDefault(); a.copy(); }
      else if (k === "s") { e.preventDefault(); a.save(); }
      else if (k === "enter") { e.preventDefault(); a.done(); }
      else if (k === "e" && e.shiftKey) {
        e.preventDefault(); // „Im Explorer zeigen“
        void persist("save").catch(() => {}).then(() => api.itemReveal(item.id));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [model, item.id, persist]);

  const c = controller.current;
  // Maße des Ergebnisses (wie `render`: Zuschnitt plus Rahmen), in Bildschirmgröße (1×, Standard) oder voller Auflösung.
  const vp = model.crop ?? model.fullRect;
  const pad = model.frame ? Math.trunc(2 * model.frame.padding * model.scale) : 0;
  const k = settings.exportAtScreenSize ? model.scale : 1;
  const outW = Math.round((Math.floor(vp.width) + pad) / k), outH = Math.round((Math.floor(vp.height) + pad) / k);
  const redactHint = (model.selected?.kind ?? TOOL_KIND[model.tool]) === "redact" && model.tool !== "crop";
  return (
    <div className="kc-root ed-root" onContextMenu={(e) => e.preventDefault()}>
      <Toolbar model={model} actions={actions} showAutoRedact={settings.showAutoRedact} />
      <div className="ed-stage" ref={stageRef}>
        <div className="ed-sheet" ref={sheetRef} />
        <canvas ref={canvasRef} />
        <div className="ed-pill-slot">
          {model.busy ? (
            <div className="kc-pill ed-pill"><span className="kc-spin" />{model.busy}</div>
          ) : model.toast ? (
            <div className="kc-pill ed-pill" key={model.toast}><CircleCheck className="kc-ok" size={16} strokeWidth={2} />{model.toast}</div>
          ) : null}
        </div>
      </div>
      <div className="ed-footer">
        <div className="kc-group kc-group--sm ed-zoom">
          <button className="kc-tool step" title="Verkleinern (Strg+−)" onClick={() => c?.zoomOut()}><Minus size={13} strokeWidth={2.4} /></button>
          <button
            className="kc-tool pct"
            title={model.zoom === null ? "Originalgröße (Strg+1)" : "Einpassen (Strg+0) · Leertaste + Ziehen verschiebt"}
            onClick={() => (model.zoom === null ? c?.zoomActualSize() : c?.zoomToFit())}
          >
            {model.zoomPercent} %
          </button>
          <button className="kc-tool step" title="Vergrößern (Strg++) · auch Strg + Mausrad" onClick={() => c?.zoomIn()}><Plus size={13} strokeWidth={2.4} /></button>
        </div>
        {model.zoom === null && <span className="ed-fit">Eingepasst</span>}
        <span className="ed-dot" />
        <span className="kc-mono ed-dims" title={settings.exportAtScreenSize ? "Größe beim Speichern (Bildschirmgröße)" : "Größe beim Speichern"}>
          {outW} × {outH}
        </span>
        <div className="ed-spacer" />
        {redactHint && (
          <span
            className="ed-hint"
            title="Klick auf eine Textzeile legt einen Balken darüber, Alt-Klick nur über ein Wort. Beim Ziehen wird der Balken bis zum Wortende erweitert — Alt beim Ziehen schaltet das ab."
          >
            Klick auf Text = Zeile · <kbd className="kc-kbd">Alt</kbd> = Wort
          </span>
        )}
      </div>
    </div>
  );
}
