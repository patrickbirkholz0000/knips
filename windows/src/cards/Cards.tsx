import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { CheckCircle2, Copy, Folder, Images, Pin, Play, ScanText, SquareArrowOutUpRight, Trash2, X } from "lucide-react";
import { api, events } from "../shared/ipc";
import { duration } from "../shared/format";
import type { CaptureItem, CardsState, Rect } from "../shared/types";
import Thumbnail from "../shared/Thumbnail";
import { CARD_H, CARD_W, HEADER_H, PADDING, SPACING, cardOrigin, panelSize } from "./layout";
import "./cards.css";
import "./mock";

interface Shown {
  item: CaptureItem;
  leaving: boolean;
  /** letzte Lage (für die Austritts-Animation) */
  pos: { x: number; y: number };
}

const LEAVE_MS = 280;

export default function Cards(_: { params: string[]; query: URLSearchParams }) {
  const [state, setState] = useState<CardsState>({ cards: [], rows: 6 });
  const [shown, setShown] = useState<Shown[]>([]);
  const [hovered, setHovered] = useState<string | null>(null);
  const [headerHover, setHeaderHover] = useState(false);
  const [flashed, setFlashed] = useState<string | null>(null);
  const flashTimer = useRef<number>();

  useEffect(() => {
    let alive = true;
    api.getCards().then((s) => alive && s && setState(s));
    const off = events.cardsChanged((s) => alive && setState(s));
    return () => {
      alive = false;
      off.then((f) => f());
    };
  }, []);

  const { cards, rows } = state;
  const n = cards.length;

  // Abgänge kurz stehen lassen, damit sie hinausgleiten können.
  useEffect(() => {
    setShown((prev) => {
      const ids = new Set(cards.map((c) => c.id));
      const leaving = prev.filter((s) => !ids.has(s.item.id)).map((s) => ({ ...s, leaving: true }));
      const live = cards.map((item, i) => ({ item, leaving: false, pos: cardOrigin(i, n, rows) }));
      return [...live, ...leaving];
    });
    const t = window.setTimeout(() => setShown((p) => p.filter((s) => !s.leaving)), LEAVE_MS);
    return () => window.clearTimeout(t);
  }, [cards, rows, n]);

  const total = shown.length;
  const size = panelSize(total, rows);

  // Größe und klickbare Flächen an Rust melden (Ursprung oben links im Panel).
  useLayoutEffect(() => {
    const hit: Rect[] = shown
      .filter((s) => !s.leaving)
      .map((s) => ({ x: s.pos.x, y: size.height - s.pos.y - CARD_H, width: CARD_W, height: CARD_H }));
    if (n > 1) hit.push({ x: PADDING, y: PADDING, width: CARD_W, height: HEADER_H - SPACING });
    api.cardsLayout(size.width, size.height, hit);
  }, [shown, size.width, size.height, n]);

  const hover = useCallback((id: string | null) => {
    setHovered(id);
    api.cardsHover(id);
  }, []);

  const flash = (id: string) => {
    setFlashed(id);
    window.clearTimeout(flashTimer.current);
    flashTimer.current = window.setTimeout(() => setFlashed((f) => (f === id ? null : f)), 1100);
  };

  if (total === 0) return null;
  const stop = (fn: () => void) => (e: React.MouseEvent) => {
    e.stopPropagation();
    fn();
  };

  return (
    <div className="cards-panel" style={{ width: size.width, height: size.height }} onMouseLeave={() => hover(null)}>
      {shown.map(({ item, leaving, pos }) => (
        <div key={item.id} className="card-pos" style={{ transform: `translate(${pos.x}px, ${-pos.y}px)` }}>
          <div className={"card-anim" + (leaving ? " leaving" : "")}>
            <div
              className="card-wrap"
              onMouseEnter={() => hover(item.id)}
              onMouseLeave={() => hover(null)}
              onClick={() => api.itemOpen(item.id)}
              draggable
              onDragStart={(e) => {
                e.preventDefault();
                api.itemStartDrag(item.id);
              }}
            >
              <div className="card">
                <Thumbnail item={item} className="th" />
                {item.kind !== "image" && (
                  <div className="card-badge">
                    {item.kind === "gif" ? <Images size={10} strokeWidth={2.6} /> : <Play size={10} strokeWidth={2.6} fill="#fff" />}
                    {item.kind === "gif" ? "GIF" : duration(item.duration ?? 0)}
                  </div>
                )}
                <div className="card-hover">
                  <div className="pills">
                    <button className="card-pill" onClick={stop(() => { api.itemCopy(item.id); flash(item.id); })}>
                      <Copy size={14} strokeWidth={2.2} /> Kopieren
                    </button>
                    <button className="card-pill" onClick={stop(() => api.itemOpen(item.id))}>
                      <SquareArrowOutUpRight size={14} strokeWidth={2.2} /> Öffnen
                    </button>
                  </div>
                  <button className="card-corner tl" title="Schließen" onClick={stop(() => api.cardsDismiss(item.id))}>
                    <X size={12} strokeWidth={2.8} />
                  </button>
                  {item.kind === "image" && (
                    <button className="card-corner tr" title="Anpinnen" onClick={stop(() => api.itemPin(item.id))}>
                      <Pin size={12} strokeWidth={2.4} />
                    </button>
                  )}
                  <button className="card-corner bl" title="Im Explorer zeigen" onClick={stop(() => api.itemReveal(item.id))}>
                    <Folder size={12} strokeWidth={2.4} />
                  </button>
                  {item.kind === "image" && (
                    <button className="card-corner bl2" title="Text kopieren (ohne zensierte Stellen)" onClick={stop(() => api.itemCopyText(item.id))}>
                      <ScanText size={12} strokeWidth={2.4} />
                    </button>
                  )}
                  <button className="card-corner br" title="Löschen" onClick={stop(() => api.itemDelete(item.id))}>
                    <Trash2 size={12} strokeWidth={2.4} />
                  </button>
                </div>
                {flashed === item.id && (
                  <div className="card-flash">
                    <CheckCircle2 size={15} strokeWidth={2.4} /> Kopiert
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      ))}
      {n > 1 && (
        <div
          className={"cards-header" + (headerHover || hovered ? " show" : "")}
          onMouseEnter={() => setHeaderHover(true)}
          onMouseLeave={() => setHeaderHover(false)}
        >
          <button onClick={() => api.cardsDismissAll()}>
            <X size={11} strokeWidth={2.8} /> Alle schließen
          </button>
        </div>
      )}
    </div>
  );
}
