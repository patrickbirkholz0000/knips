// Bild-Editor (Fenster `#/editor/<itemId>?tool=redact`): Port von EditorWindow.swift.
import { useCallback, useEffect, useRef, useState } from "react";
import { CircleCheck, Minus, Plus } from "lucide-react";
import { api, events, fileUrl, inTauri, itemTitle } from "../shared/ipc";
import { useBootstrap } from "../shared/hooks";
import type { EditorSession, EditorTool, Settings } from "../shared/types";
import { CanvasController } from "./canvas";
import "./editor.css";
import "./mock";
import { EditorModel, useModel } from "./model";
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

  if (error) return <div className="ed-root" style={{ padding: 24, color: "#ff6961" }}>Bild nicht gefunden — {error}</div>;
  if (!model || !boot) return <div className="ed-root" />;
  return <EditorView model={model} settings={boot.settings} />;
}

function EditorView({ model, settings }: { model: EditorModel; settings: Settings }) {
  useModel(model);
  model.settings = settings;
  const stageRef = useRef<HTMLDivElement>(null);
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
        model.dirty = was;
        model.showToast("Speichern fehlgeschlagen");
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
        () => {
          model.dirty = was;
          model.showToast("Kopieren fehlgeschlagen");
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
    const c = new CanvasController(canvasRef.current!, stageRef.current!, model, { close: () => void closeWindow() });
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
  return (
    <div className="ed-root" onContextMenu={(e) => e.preventDefault()}>
      <Toolbar model={model} actions={actions} showAutoRedact={settings.showAutoRedact} />
      <div className="ed-stage" ref={stageRef}>
        <canvas ref={canvasRef} />
        {model.busy ? (
          <div className="ed-pill"><span className="ed-spin" />{model.busy}</div>
        ) : model.toast ? (
          <div className="ed-pill" key={model.toast}><CircleCheck size={15} fill="currentColor" stroke="#000" strokeWidth={1.6} />{model.toast}</div>
        ) : null}
        <div className="ed-zoom">
          <button className="step" title="Verkleinern (Strg+−)" onClick={() => c?.zoomOut()}><Minus size={12} strokeWidth={3} /></button>
          <button
            className="pct"
            title={model.zoom === null ? "Originalgröße (Strg+1)" : "Einpassen (Strg+0) · Leertaste + Ziehen verschiebt"}
            onClick={() => (model.zoom === null ? c?.zoomActualSize() : c?.zoomToFit())}
          >
            {model.zoom === null ? `Einpassen · ${model.zoomPercent} %` : `${model.zoomPercent} %`}
          </button>
          <button className="step" title="Vergrößern (Strg++) · auch Strg + Mausrad" onClick={() => c?.zoomIn()}><Plus size={12} strokeWidth={3} /></button>
        </div>
      </div>
    </div>
  );
}
