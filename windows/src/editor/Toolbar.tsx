// Werkzeugleiste oben (EditorToolbar in EditorWindow.swift).
import type { ReactNode } from "react";
import {
  ArrowUpRight, CaseSensitive, Circle, Copy, Crop, Droplet, EyeOff, Grid3x3, Highlighter, MousePointer2, Pin, Redo2, RectangleHorizontal, ScanText, Slash, Square, Undo2, WandSparkles,
} from "lucide-react";
import type { AnnotationKind, EditorTool } from "../shared/types";
import { FrameButton } from "./FramePanel";
import { EditorModel, REDACT_STYLES, REDACT_TITLE, TOOLS, TOOL_KEY, TOOL_KIND, TOOL_TITLE, useModel } from "./model";
import { PALETTE, STROKE_SIZES, STROKE_TITLE, rgbaCss, sameColor } from "./renderer";

export interface EditorActions {
  save: () => void;
  done: () => void;
  copy: () => void;
  copyText: () => void;
  pin: () => void;
}

const ICON = { size: 16, strokeWidth: 1.9 } as const;

function CounterIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="10" />
      <path d="M10 9.5l2-1.5v8" />
    </svg>
  );
}

const TOOL_ICON: Record<EditorTool, ReactNode> = {
  select: <MousePointer2 {...ICON} />,
  arrow: <ArrowUpRight {...ICON} />,
  rectangle: <Square {...ICON} />,
  ellipse: <Circle {...ICON} />,
  line: <Slash {...ICON} />,
  text: <CaseSensitive {...ICON} size={19} />,
  counter: <CounterIcon />,
  highlight: <Highlighter {...ICON} />,
  redact: <EyeOff {...ICON} />,
  crop: <Crop {...ICON} />,
};

const STYLE_ICON = {
  pixelate: <Grid3x3 size={13} strokeWidth={2.4} />,
  blur: <Droplet size={13} strokeWidth={2.2} fill="currentColor" />,
  solid: <RectangleHorizontal size={14} strokeWidth={2} fill="currentColor" />,
};

function IconButton({ icon, title, enabled = true, onClick }: { icon: ReactNode; title: string; enabled?: boolean; onClick: () => void }) {
  return (
    <button className="ed-icon" title={title} disabled={!enabled} onClick={onClick}>
      {icon}
    </button>
  );
}

export function Toolbar({ model, actions, showAutoRedact }: { model: EditorModel; actions: EditorActions; showAutoRedact: boolean }) {
  useModel(model);
  const sel = model.selected;
  const activeKind: AnnotationKind | undefined = sel?.kind ?? TOOL_KIND[model.tool];

  if (model.tool === "crop") {
    return (
      <div className="ed-toolbar">
        <div className="ed-crop-bar">
          <Crop size={16} strokeWidth={1.9} style={{ opacity: 0.8 }} />
          <span>Zuschneiden — Rahmen ziehen, ⏎ übernimmt, Esc bricht ab</span>
          <button className="ed-btn" onClick={() => model.resetCrop()}>Zurücksetzen</button>
          <button className="ed-btn" onClick={() => model.cancelCrop()}>Abbrechen</button>
          <button className="ed-btn prominent" onClick={() => model.applyCrop()}>Übernehmen</button>
        </div>
      </div>
    );
  }

  const redactOn = (s: string) => (sel?.kind === "redact" ? sel.redactStyle : model.redactStyle) === s;

  return (
    <div className="ed-toolbar">
      <div className="ed-group tools">
        {TOOLS.map((t) => (
          <button
            key={t}
            className={`ed-tool${model.tool === t ? " on" : ""}`}
            title={`${TOOL_TITLE[t]} (${TOOL_KEY[t].toUpperCase()})`}
            onClick={() => (t === "crop" ? model.startCrop() : (model.tool = t))}
          >
            {TOOL_ICON[t]}
          </button>
        ))}
      </div>
      <div className="ed-divider" />

      {activeKind === "redact" ? (
        <>
          <span
            className="ed-hint"
            title="Klick auf eine Textzeile legt einen Balken darüber, Alt-Klick nur über ein Wort. Beim Ziehen wird der Balken bis zum Wortende erweitert — Alt beim Ziehen schaltet das ab."
          >
            Klick auf Text = Zeile · Alt = Wort
          </span>
          <div className="ed-group">
            {REDACT_STYLES.map((s) => (
              <button key={s} className={`ed-seg-btn wide${redactOn(s) ? " on" : ""}`} onClick={() => model.setRedactStyle(s)}>
                {STYLE_ICON[s]}
                {REDACT_TITLE[s]}
              </button>
            ))}
          </div>
        </>
      ) : (
        <>
          <div className="ed-colors">
            {PALETTE.map((c, i) => {
              const on = sameColor(sel?.color ?? model.color, c);
              return (
                <button key={i} className={`ed-swatch${on ? " on" : ""}`} onClick={() => model.setColor(c)}>
                  <span style={{ background: rgbaCss(c), borderColor: `rgba(255,255,255,${i === 6 ? 0.35 : 0.15})` }} />
                </button>
              );
            })}
          </div>
          {activeKind !== "highlight" && (
            <>
              <div className="ed-divider" />
              <div className="ed-group">
                {STROKE_SIZES.map((s) => (
                  <button key={s} className={`ed-seg-btn size${(sel?.size ?? model.size) === s ? " on" : ""}`} onClick={() => model.setSize(s)}>
                    {STROKE_TITLE[s]}
                  </button>
                ))}
              </div>
            </>
          )}
          {(activeKind === "rectangle" || activeKind === "ellipse") && (
            <button className="ed-icon fill" title="Gefüllt" onClick={() => model.setFilled(!(sel?.filled ?? model.filled))}>
              <Square size={15} strokeWidth={2} fill={(sel?.filled ?? model.filled) ? "currentColor" : "none"} />
            </button>
          )}
        </>
      )}

      <div style={{ flex: 1, minWidth: 8 }} />

      <div className="ed-right">
        {showAutoRedact && (
          <button
            className="ed-btn"
            disabled={model.busy !== null}
            title="Findet E-Mails, IBANs, Telefonnummern, Kartennummern und API-Schlüssel und zensiert sie — lokal, ohne Cloud."
            onClick={() => void model.autoRedact()}
          >
            <WandSparkles size={14} strokeWidth={2} />
            Auto-Zensur
          </button>
        )}
        <div style={{ display: "flex" }}>
          <IconButton icon={<Undo2 {...ICON} />} title="Widerrufen (Strg+Z)" enabled={model.canUndo} onClick={() => model.undo()} />
          <IconButton icon={<Redo2 {...ICON} />} title="Wiederholen (Strg+Umschalt+Z)" enabled={model.canRedo} onClick={() => model.redo()} />
        </div>
        <FrameButton model={model} />
        <IconButton icon={<ScanText {...ICON} />} title="Text kopieren — zensierte Wörter werden zu █" onClick={actions.copyText} />
        <IconButton icon={<Pin {...ICON} />} title="Anpinnen (schwebt über allen Fenstern)" onClick={actions.pin} />
        <button className="ed-btn" title="Kopieren (Strg+C)" onClick={actions.copy}>
          <Copy size={14} strokeWidth={2} />
          Kopieren
        </button>
        <button className="ed-btn prominent" title="Fertig (Strg+Enter)" onClick={actions.done}>
          Fertig
        </button>
      </div>
    </div>
  );
}
