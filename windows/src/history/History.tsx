// Verlauf (`#/history`, docs/design.md „Verlauf“): Kopfzeile mit Titel, Satz mit Anzahl und Filter als
// Segment-Schalter; Raster aus Karten (Vorschau auf fill, Name, Meta in Mono). Doppelklick öffnet, Ziehen
// gibt die Datei an andere Apps; beim Darüberfahren Königsblau-Linie und kleine Knöpfe.
import { useEffect, useState } from "react";
import { Copy, EyeOff, Folder, Images, Play, Scissors, Trash2 } from "lucide-react";
import { api, itemTitle } from "../shared/ipc";
import { useBootstrap, useItems } from "../shared/hooks";
import { duration } from "../shared/format";
import type { CaptureItem } from "../shared/types";
import Thumbnail from "../shared/Thumbnail";
import { Keys, Segmented } from "../shared/ui";
import "./history.css";
import "./mock";

type Filter = "all" | "images" | "videos" | "gifs";
const filters: { id: Filter; title: string; match: (i: CaptureItem) => boolean }[] = [
  { id: "all", title: "Alle", match: () => true },
  { id: "images", title: "Screenshots", match: (i) => i.kind === "image" },
  { id: "videos", title: "Videos", match: (i) => i.kind === "video" },
  { id: "gifs", title: "GIFs", match: (i) => i.kind === "gif" },
];

const dateFmt = new Intl.DateTimeFormat("de-DE", { day: "numeric", month: "short" });
const timeFmt = new Intl.DateTimeFormat("de-DE", { hour: "2-digit", minute: "2-digit" });
/** „12. Okt · 16:03“ — ohne Punkt hinter dem Monat, wie auf dem Mac. */
const when = (ms: number) => `${dateFmt.format(ms).replace(/\.$/, "")} · ${timeFmt.format(ms)}`;

export default function History(_: { params: string[]; query: URLSearchParams }) {
  const all = useItems();
  const boot = useBootstrap();
  const [filter, setFilter] = useState<Filter>("all");
  const items = all.filter(filters.find((f) => f.id === filter)!.match);
  const days = boot?.settings.retentionDays ?? 30;
  const capture = boot?.hotkeyLabels.captureArea;
  useEffect(() => {
    document.title = "Knips – Verlauf";
  }, []);

  const count = all.length === 1 ? "1 Aufnahme" : `${all.length} Aufnahmen`;
  return (
    <div className="history k-scroll">
      <header className="history-head">
        <div>
          <h1>Verlauf</h1>
          <p className="sub">{days === 0 ? `${count} – Originale bleiben, bis du sie löschst.` : `${count} der letzten ${days} Tage.`}</p>
        </div>
        <Segmented
          label="Filter"
          value={filter}
          options={filters.map((f) => [f.id, f.title] as [Filter, string])}
          onChange={setFilter}
        />
      </header>
      {items.length === 0 ? (
        <div className="history-empty">
          <span className="history-empty__icon">
            <Images size={26} strokeWidth={1.7} />
          </span>
          <div className="t">{all.length === 0 ? "Noch nichts hier" : "Nichts in diesem Filter"}</div>
          {all.length === 0 && (
            <div className="d">
              {capture ? (
                <>
                  Mit <Keys combo={capture} /> einen Bereich aufnehmen.
                </>
              ) : (
                "Einen Bereich aufnehmen – über das Symbol in der Taskleiste."
              )}
            </div>
          )}
        </div>
      ) : (
        <div className="history-grid">
          {items.map((item) => (
            <Card key={item.id} item={item} />
          ))}
        </div>
      )}
    </div>
  );
}

function Card({ item }: { item: CaptureItem }) {
  const image = item.kind === "image";
  return (
    <div
      className="hcard"
      draggable
      onDoubleClick={() => api.itemOpen(item.id)}
      onDragStart={(e) => {
        e.preventDefault();
        api.itemStartDrag(item.id);
      }}
    >
      <div className="media">
        <Thumbnail item={item} background="transparent" className="th" />
        {!image && (
          <div className="badge">
            {item.kind === "gif" ? <Images size={10} strokeWidth={2.6} /> : <Play size={9} strokeWidth={2.6} fill="currentColor" />}
            {item.kind === "gif" ? "GIF" : duration(item.duration ?? 0)}
          </div>
        )}
        <div className="acts" onDoubleClick={(e) => e.stopPropagation()}>
          <button className="hbtn" title="Kopieren" aria-label="Kopieren" onClick={() => api.itemCopy(item.id)}>
            <Copy size={14} strokeWidth={2.2} />
          </button>
          <button
            className="hbtn"
            title={image ? "Zensieren" : "Bearbeiten"}
            aria-label={image ? "Zensieren" : "Bearbeiten"}
            onClick={() => api.itemOpen(item.id, image ? "redact" : undefined)}
          >
            {image ? <EyeOff size={14} strokeWidth={2.2} /> : <Scissors size={14} strokeWidth={2.2} />}
          </button>
          <button className="hbtn" title="Im Explorer zeigen" aria-label="Im Explorer zeigen" onClick={() => api.itemReveal(item.id)}>
            <Folder size={14} strokeWidth={2.2} />
          </button>
          <button className="hbtn" title="Löschen" aria-label="Löschen" onClick={() => api.itemDelete(item.id)}>
            <Trash2 size={14} strokeWidth={2.2} />
          </button>
        </div>
      </div>
      <div className="meta">
        <div className="name" title={itemTitle(item)}>
          {itemTitle(item)}
        </div>
        <div className="when">
          {when(item.createdAt)} · {item.pixelWidth} × {item.pixelHeight}
        </div>
      </div>
    </div>
  );
}
