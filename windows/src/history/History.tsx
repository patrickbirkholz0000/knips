import { useState } from "react";
import { Copy, EyeOff, Folder, Images, Play, Scissors, Trash2 } from "lucide-react";
import { api, itemTitle } from "../shared/ipc";
import { useBootstrap, useItems } from "../shared/hooks";
import { duration } from "../shared/format";
import type { CaptureItem } from "../shared/types";
import Thumbnail from "../shared/Thumbnail";
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
const when = (ms: number) => `${dateFmt.format(ms)}, ${timeFmt.format(ms)}`;

export default function History(_: { params: string[]; query: URLSearchParams }) {
  const all = useItems();
  const boot = useBootstrap();
  const [filter, setFilter] = useState<Filter>("all");
  const items = all.filter(filters.find((f) => f.id === filter)!.match);
  const days = boot?.settings.retentionDays ?? 30;
  const capture = boot?.hotkeyLabels.captureArea;

  return (
    <div className="history">
      <div className="history-head">
        <div>
          <h1>Verlauf</h1>
          <div className="sub">{all.length} Aufnahmen der letzten {days === 0 ? "Zeit" : `${days} Tage`}</div>
        </div>
        <div className="chips">
          {filters.map((f) => (
            <button key={f.id} className={"chip" + (filter === f.id ? " on" : "")} onClick={() => setFilter(f.id)}>
              {f.title}
            </button>
          ))}
        </div>
      </div>
      {items.length === 0 ? (
        <div className="history-empty">
          <Images size={36} strokeWidth={1.5} />
          <div className="t">Noch nichts hier</div>
          <div className="d">{capture ? `Mit ${capture} einen Bereich aufnehmen.` : "Einen Bereich aufnehmen."}</div>
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
        <Thumbnail item={item} background="rgb(237, 237, 237)" className="th" />
        {!image && (
          <div className="badge">
            {item.kind === "gif" ? <Images size={10} strokeWidth={2.6} /> : <Play size={10} strokeWidth={2.6} fill="#fff" />}
            {item.kind === "gif" ? "GIF" : duration(item.duration ?? 0)}
          </div>
        )}
        <div className="over">
          <button className="hbtn" title="Kopieren" onDoubleClick={(e) => e.stopPropagation()} onClick={() => api.itemCopy(item.id)}>
            <Copy size={15} strokeWidth={2.2} />
          </button>
          <button className="hbtn" title={image ? "Zensieren" : "Bearbeiten"} onClick={() => api.itemOpen(item.id, image ? "redact" : undefined)}>
            {image ? <EyeOff size={15} strokeWidth={2.2} /> : <Scissors size={15} strokeWidth={2.2} />}
          </button>
          <button className="hbtn" title="Im Explorer zeigen" onClick={() => api.itemReveal(item.id)}>
            <Folder size={15} strokeWidth={2.2} />
          </button>
          <button className="hbtn" title="Löschen" onClick={() => api.itemDelete(item.id)}>
            <Trash2 size={15} strokeWidth={2.2} />
          </button>
        </div>
      </div>
      <div className="meta">
        <div className="name">{itemTitle(item)}</div>
        <div className="when">{when(item.createdAt)} · {item.pixelWidth}×{item.pixelHeight}</div>
      </div>
    </div>
  );
}
