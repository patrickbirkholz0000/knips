import { useEffect, useRef } from "react";
import type { RedactStyle } from "../shared/types";

// Vorschau wie RedactPreview.swift: Beispieltext, Zensur über E-Mail und Telefon.
// Könnte auf den gemeinsamen Renderer (editor/renderer.ts) umgestellt werden.
const W = 448;
const H = 264;
const RECT = { x: 24, y: 126, w: 400, h: 122 };

function sample(): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = W;
  c.height = H;
  const g = c.getContext("2d")!;
  g.fillStyle = "rgb(247,247,250)";
  g.fillRect(0, 0, W, H);
  g.fillStyle = "rgb(219,222,230)";
  g.fillRect(0, 0, W, 44);
  g.fillStyle = "#000";
  g.textBaseline = "top";
  const f = '"Segoe UI", system-ui, -apple-system, sans-serif';
  g.font = `700 40px ${f}`;
  g.fillText("Kontakt", 32, 60);
  g.font = `500 40px ${f}`;
  g.fillText("max@example.com", 32, 124);
  g.fillText("+49 170 123456", 32, 184);
  return c;
}

export function drawPreview(canvas: HTMLCanvasElement, style: RedactStyle) {
  const base = sample();
  canvas.width = W;
  canvas.height = H;
  const g = canvas.getContext("2d")!;
  g.drawImage(base, 0, 0);
  const { x, y, w, h } = RECT;
  if (style === "solid") {
    g.fillStyle = "rgb(15,15,15)";
    g.beginPath();
    g.roundRect(x, y, w, h, 6);
    g.fill();
  } else if (style === "pixelate") {
    const block = 10;
    const small = document.createElement("canvas");
    small.width = Math.ceil(w / block);
    small.height = Math.ceil(h / block);
    small.getContext("2d")!.drawImage(base, x, y, w, h, 0, 0, small.width, small.height);
    g.save();
    g.beginPath();
    g.rect(x, y, w, h);
    g.clip();
    g.imageSmoothingEnabled = false;
    g.drawImage(small, 0, 0, small.width, small.height, x, y, small.width * block, small.height * block);
    g.restore();
  } else {
    g.save();
    g.beginPath();
    g.rect(x, y, w, h);
    g.clip();
    g.filter = "blur(9px)";
    g.drawImage(base, 0, 0);
    g.restore();
  }
}

export default function RedactPreview({ style }: { style: RedactStyle }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (ref.current) drawPreview(ref.current, style);
  }, [style]);
  return <canvas ref={ref} />;
}
