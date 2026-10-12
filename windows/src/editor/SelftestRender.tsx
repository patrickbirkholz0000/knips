// Route `#/selftest-render`: Port von SelfTest.render — drei Dokumente auf dem Mac-Beispielbild.
import { useEffect, useState } from "react";
import type { Annotation, AnnotationKind, ImageDocument, Point, StrokeSize, Rgba } from "../shared/types";
import { COLORS, EffectsCache, render } from "./renderer";

export interface RenderResult {
  name: string;
  width: number;
  height: number;
  png: string;
}

function ann(kind: AnnotationKind, start: Point, end: Point, color: Rgba = COLORS.red, size: StrokeSize = "medium"): Annotation {
  return { id: `${kind}-${start.x}-${start.y}`, kind, start, end, color, size, filled: false, text: "", number: 1, redactStyle: "pixelate", auto: false };
}

function loadSample(): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("sample.png fehlt"));
    img.src = "/mock/sample.png";
  });
}

export async function runSelftestRender(): Promise<RenderResult[]> {
  const base = await loadSample();
  const scale = 2;
  const zero = { x: 0, y: 0 };
  const doc: ImageDocument = { version: 1, annotations: [], crop: null, frame: null };
  const list = doc.annotations;
  list.push(ann("arrow", { x: 1260, y: 120 }, { x: 1040, y: 230 }));
  list.push(ann("rectangle", { x: 380, y: 490 }, { x: 1300, y: 580 }, COLORS.blue));
  list.push(ann("ellipse", { x: 380, y: 620 }, { x: 700, y: 720 }, COLORS.green, "small"));
  list.push(ann("line", { x: 760, y: 680 }, { x: 1200, y: 760 }, COLORS.purple, "large"));
  list.push(ann("highlight", { x: 386, y: 500 }, { x: 900, y: 532 }, COLORS.yellow));
  const c1 = ann("counter", { x: 360, y: 200 }, zero);
  c1.number = 1;
  const c2 = ann("counter", { x: 360, y: 256 }, zero, COLORS.orange);
  c2.number = 2;
  list.push(c1, c2);
  const t = ann("text", { x: 820, y: 640 }, zero, COLORS.red, "large");
  t.text = "Hier klicken!";
  list.push(t);
  const r1 = ann("redact", { x: 520, y: 236 }, { x: 1130, y: 272 });
  r1.redactStyle = "pixelate";
  const r2 = ann("redact", { x: 498, y: 348 }, { x: 1010, y: 384 });
  r2.redactStyle = "blur";
  const r3 = ann("redact", { x: 600, y: 404 }, { x: 1300, y: 440 });
  r3.redactStyle = "solid";
  list.push(r1, r2, r3);

  const effects = new EffectsCache(base, scale);
  const out: RenderResult[] = [];
  const push = (name: string, c: HTMLCanvasElement) => out.push({ name, width: c.width, height: c.height, png: c.toDataURL("image/png") });
  push("original", render(base, { version: 1, annotations: [], crop: null, frame: null }, scale, effects));
  push("annotiert", render(base, doc, scale, effects));
  doc.crop = { x: 340, y: 60, width: 1000, height: 420 };
  push("zugeschnitten", render(base, doc, scale, effects));
  return out;
}

export default function SelftestRender() {
  const [results, setResults] = useState<RenderResult[]>([]);
  useEffect(() => {
    (window as unknown as { __knipsSelftestRender: typeof runSelftestRender }).__knipsSelftestRender = runSelftestRender;
    void runSelftestRender().then(setResults);
  }, []);
  return (
    <div style={{ padding: 16, background: "#222", color: "#eee", height: "100%", overflow: "auto", userSelect: "text" }}>
      {results.map((r) => (
        <div key={r.name} style={{ marginBottom: 20 }}>
          <div style={{ marginBottom: 6 }}>{r.name} · {r.width}×{r.height}</div>
          <img src={r.png} alt={r.name} style={{ maxWidth: "100%", display: "block" }} />
        </div>
      ))}
    </div>
  );
}
