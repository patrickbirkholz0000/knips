// Werkzeugleiste oben (EditorToolbar in EditorWindow.swift), in der Markensprache (docs/design.md, „Editor (Bild)“):
// Werkzeuge als eine Gruppe, daneben die Eigenschaften des Werkzeugs im selben Stil, rechts die Aktionen.
import { Fragment, useCallback, useRef, useState, type ReactNode } from "react";
import {
  ArrowUpRight, CaseSensitive, ChevronDown, Circle, Copy, Crop, Droplet, EyeOff, Grid3x3, Highlighter, MousePointer2, Pin, Redo2, RectangleHorizontal, ScanText, Slash, Square, Undo2, WandSparkles,
} from "lucide-react";
import type { AnnotationKind, EditorTool, Rgba, StrokeSize } from "../shared/types";
import { FrameButton } from "./FramePanel";
import { useDismiss } from "./popover";
import { EditorModel, REDACT_STYLES, REDACT_TITLE, TOOLS, TOOL_KEY, TOOL_KIND, TOOL_TITLE, useModel } from "./model";
import { PALETTE, STROKE_SIZES, STROKE_TITLE, rgbaCss, sameColor } from "./renderer";

export interface EditorActions {
  save: () => void;
  done: () => void;
  copy: () => void;
  copyText: () => void;
  pin: () => void;
}

const ICON = { size: 17, strokeWidth: 1.8 } as const;

function CounterIcon() {
  return (
    <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
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
  text: <CaseSensitive {...ICON} size={20} />,
  counter: <CounterIcon />,
  highlight: <Highlighter {...ICON} />,
  redact: <EyeOff {...ICON} />,
  crop: <Crop {...ICON} />,
};

const STYLE_ICON = {
  pixelate: <Grid3x3 size={14} strokeWidth={2.2} />,
  blur: <Droplet size={14} strokeWidth={2} fill="currentColor" fillOpacity={0.25} />,
  solid: <RectangleHorizontal size={15} strokeWidth={2} fill="currentColor" />,
};

/** Strichstärke als Strich (S/M/L). */
const SIZE_PX: Record<StrokeSize, number> = { small: 2, medium: 3.5, large: 5.5 };

function IconButton({ icon, title, enabled = true, onClick }: { icon: ReactNode; title: string; enabled?: boolean; onClick: () => void }) {
  return (
    <button className="kc-tool ed-icon" title={title} disabled={!enabled} onClick={onClick}>
      {icon}
    </button>
  );
}

function Swatches({ model, current }: { model: EditorModel; current: Rgba }) {
  return (
    <>
      {PALETTE.map((c, i) => {
        const on = sameColor(current, c);
        return (
          <button key={i} className={`ed-swatch${on ? " on" : ""}`} aria-pressed={on} onClick={() => model.setColor(c)}>
            <span style={{ background: rgbaCss(c) }} />
          </button>
        );
      })}
    </>
  );
}

/** Farben: breit als Reihe in der Leiste, schmal als ein Knopf mit Popover (gleiche Farben). */
function ColorPicker({ model, current }: { model: EditorModel; current: Rgba }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const close = useCallback(() => setOpen(false), []);
  useDismiss(open, close, ref);
  return (
    <>
      <div className="ed-colors">
        <Swatches model={model} current={current} />
      </div>
      <div className="ed-pop-wrap ed-color-pick" ref={ref}>
        <button className={`kc-tool ed-color-btn${open ? " on" : ""}`} title="Farbe" aria-expanded={open} onClick={() => setOpen(!open)}>
          <span className="ed-color-dot" style={{ background: rgbaCss(current) }} />
          <ChevronDown size={12} strokeWidth={2.4} />
        </button>
        {open && (
          <div className="kc-popover ed-popover ed-color-pop" onClick={close}>
            <Swatches model={model} current={current} />
          </div>
        )}
      </div>
    </>
  );
}

export function Toolbar({ model, actions, showAutoRedact }: { model: EditorModel; actions: EditorActions; showAutoRedact: boolean }) {
  useModel(model);
  const sel = model.selected;
  const activeKind: AnnotationKind | undefined = sel?.kind ?? TOOL_KIND[model.tool];

  if (model.tool === "crop") {
    return (
      <div className="ed-toolbar">
        <div className="kc-group ed-crop-info">
          <Crop size={17} strokeWidth={1.9} />
          <strong>Zuschneiden</strong>
          <span className="ed-crop-steps">
            Rahmen ziehen · <kbd className="kc-kbd kc-kbd--sym">⏎</kbd> übernimmt · <kbd className="kc-kbd">Esc</kbd> bricht ab
          </span>
        </div>
        <div className="ed-spacer" />
        <div className="ed-actions">
          <button className="kc-btn kc-btn--quiet" onClick={() => model.resetCrop()}>Zurücksetzen</button>
          <button className="kc-btn kc-btn--secondary" onClick={() => model.cancelCrop()}>Abbrechen</button>
          <button className="kc-btn kc-btn--primary" onClick={() => model.applyCrop()}>Übernehmen</button>
        </div>
      </div>
    );
  }

  const redactOn = (s: string) => (sel?.kind === "redact" ? sel.redactStyle : model.redactStyle) === s;

  return (
    <div className="ed-toolbar">
      <div className="kc-group ed-tools" role="toolbar" aria-label="Werkzeuge">
        {TOOLS.map((t) => {
          const redact = t === "redact";
          return (
            <Fragment key={t}>
              {redact && <div className="kc-divider" />}
              <button
                className={`kc-tool${redact ? " wide ed-tool-redact" : ""}${model.tool === t ? " on" : ""}`}
                title={`${TOOL_TITLE[t]} (${TOOL_KEY[t].toUpperCase()})`}
                aria-pressed={model.tool === t}
                onClick={() => (t === "crop" ? model.startCrop() : (model.tool = t))}
              >
                {TOOL_ICON[t]}
                {redact && <span className="ed-label">{TOOL_TITLE[t]}</span>}
              </button>
              {redact && <div className="kc-divider" />}
            </Fragment>
          );
        })}
      </div>

      <div className="kc-group ed-props" aria-label="Eigenschaften">
        {activeKind === "redact" ? (
          <div className="kc-seg">
            {REDACT_STYLES.map((s) => (
              <button key={s} className={redactOn(s) ? "on" : ""} title={REDACT_TITLE[s]} onClick={() => model.setRedactStyle(s)}>
                {STYLE_ICON[s]}
                <span className="ed-label">{REDACT_TITLE[s]}</span>
              </button>
            ))}
          </div>
        ) : (
          <>
            <ColorPicker model={model} current={sel?.color ?? model.color} />
            {activeKind !== "highlight" && (
              <>
                <div className="kc-divider" />
                <div className="kc-seg">
                  {STROKE_SIZES.map((s) => (
                    <button key={s} className={`ed-size${(sel?.size ?? model.size) === s ? " on" : ""}`} title={`Stärke ${STROKE_TITLE[s]}`} onClick={() => model.setSize(s)}>
                      <i style={{ height: SIZE_PX[s] }} />
                    </button>
                  ))}
                </div>
              </>
            )}
            {(activeKind === "rectangle" || activeKind === "ellipse") && (
              <button
                className={`kc-tool${(sel?.filled ?? model.filled) ? " on" : ""}`}
                title="Gefüllt"
                aria-pressed={sel?.filled ?? model.filled}
                onClick={() => model.setFilled(!(sel?.filled ?? model.filled))}
              >
                <Square size={16} strokeWidth={2} fill={(sel?.filled ?? model.filled) ? "currentColor" : "none"} />
              </button>
            )}
          </>
        )}
      </div>

      <div className="ed-spacer" />

      <div className="ed-actions">
        {showAutoRedact && (
          <button
            className="kc-btn kc-btn--accent ed-auto"
            disabled={model.busy !== null}
            title="Findet E-Mails, IBANs, Telefonnummern, Kartennummern und API-Schlüssel und zensiert sie — lokal, ohne Cloud."
            onClick={() => void model.autoRedact()}
          >
            <WandSparkles size={15} strokeWidth={2} />
            <span className="ed-label">Auto-Zensur</span>
          </button>
        )}
        <div className="kc-group ed-history">
          <IconButton icon={<Undo2 {...ICON} />} title="Widerrufen (Strg+Z)" enabled={model.canUndo} onClick={() => model.undo()} />
          <IconButton icon={<Redo2 {...ICON} />} title="Wiederholen (Strg+Umschalt+Z)" enabled={model.canRedo} onClick={() => model.redo()} />
          <div className="kc-divider" />
          <FrameButton model={model} />
          <IconButton icon={<Pin {...ICON} />} title="Anpinnen (schwebt über allen Fenstern)" onClick={actions.pin} />
        </div>
        <button className="kc-btn kc-btn--secondary ed-copy-text" title="Text kopieren — zensierte Wörter werden zu █" onClick={actions.copyText}>
          <ScanText size={15} strokeWidth={2} />
          <span className="ed-label-text">Text kopieren</span>
        </button>
        <button className="kc-btn kc-btn--secondary ed-copy" title="Kopieren (Strg+C)" onClick={actions.copy}>
          <Copy size={15} strokeWidth={2} />
          <span className="ed-label-copy">Kopieren</span>
        </button>
        <button className="kc-btn kc-btn--primary" title="Fertig (Strg+Enter)" onClick={actions.done}>
          Fertig
        </button>
      </div>
    </div>
  );
}
