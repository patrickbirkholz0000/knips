// Attrappen für den Editor ohne Tauri (Browser, Screenshots auf dem Mac).
import { inTauri, registerMock } from "../shared/ipc";
import { mockItems } from "../shared/mock";
import type { EditorSession, Finding, TextLine, TextWord } from "../shared/types";

// Erfundener Stripe-Schlüssel wie im Testbild. Absichtlich zusammengesetzt: Im Quelltext steht so nie „sk_“ +
// „live_“ direkt vor Buchstaben/Ziffern, damit Secret-Scanner (GitHub-Push-Schutz) nicht anschlagen.
const STRIPE_KEY = "sk_" + "live_KnipsBeispiel42";

if (!inTauri) {
  const S = 2;
  // Position und Breite der Beispieltexte (Pt) aus SelfTest.sampleImage; Breite grob nach 14-pt-Systemschrift.
  const rows: { text: string; y: number; size: number; bold?: boolean }[] = [
    { text: "Kundendaten", y: 52, size: 22, bold: true },
    { text: "Name: Erika Mustermann", y: 96, size: 14 },
    { text: "E-Mail: erika.mustermann@example.com", y: 124, size: 14 },
    { text: "Telefon: +49 170 1234567", y: 152, size: 14 },
    { text: "IBAN: DE89 3704 0044 0532 0130 00", y: 180, size: 14 },
    { text: "Stripe-Key: " + STRIPE_KEY, y: 208, size: 13 },
    { text: "Bestellung #48213 wurde am 03.10. versendet und ist unterwegs.", y: 252, size: 14 },
    { text: "Hinweis: Lieferzeit 2–3 Werktage, Sendungsverfolgung folgt per Mail.", y: 280, size: 14 },
  ];
  const measure = (() => {
    let ctx: CanvasRenderingContext2D | null = null;
    return (t: string, px: number, bold?: boolean) => {
      ctx ??= document.createElement("canvas").getContext("2d")!;
      ctx.font = `${bold ? 700 : 400} ${px}px system-ui, "Segoe UI", sans-serif`;
      return ctx.measureText(t).width;
    };
  })();
  const lines: TextLine[] = rows.map((r) => {
    const px = r.size * S;
    const x0 = 196 * S;
    const h = Math.round(px * 1.0);
    const y = r.y * S + px * 0.1;
    const words: TextWord[] = [];
    let cursor = x0;
    const space = measure(" ", px, r.bold);
    for (const w of r.text.split(" ")) {
      const ww = measure(w, px, r.bold);
      words.push({ text: w, rect: { x: cursor, y, width: ww, height: h } });
      cursor += ww + space;
    }
    const last = words[words.length - 1];
    return { text: r.text, rect: { x: x0, y, width: last.rect.x + last.rect.width - x0, height: h }, words };
  });

  registerMock("editor_open", ({ id }): EditorSession => {
    const item = mockItems.find((i) => i.id === id) ?? mockItems[0];
    return {
      item,
      document: { version: 1, annotations: [], crop: null, frame: null },
      originalPath: "/mock/sample.png",
      scale: 2,
      initialTool: null,
    };
  });
  registerMock("editor_text_lines", () => lines);
  registerMock("editor_detect", (): Finding[] => {
    const find = (row: number, from: string, kind: Finding["kind"]): Finding => {
      const l = lines[row];
      const w = l.words.filter((x) => from && l.text.includes(from) && from.split(" ").includes(x.text));
      const first = w[0].rect, last = w[w.length - 1].rect;
      return { kind, text: from, rect: { x: first.x, y: first.y, width: last.x + last.width - first.x, height: first.height } };
    };
    return [
      find(2, "erika.mustermann@example.com", "email"),
      find(4, "DE89 3704 0044 0532 0130 00", "iban"),
      find(5, STRIPE_KEY, "secret"),
    ];
  });
  registerMock("editor_stage", () => undefined);
  registerMock("editor_commit", ({ id, action, width, height, rgba }) => {
    console.info(`[mock] editor_commit ${action} ${width}x${height} (${rgba?.length ?? 0} Bytes)`);
    (window as unknown as { __commits?: unknown[] }).__commits ??= [];
    (window as unknown as { __commits: unknown[] }).__commits.push({ id, action, width, height, bytes: rgba?.length ?? 0 });
    return mockItems.find((i) => i.id === id) ?? mockItems[0];
  });
  registerMock("set_editor_prefs", () => undefined);
  registerMock("clipboard_text", ({ text }) => {
    (window as unknown as { __clipboardText?: string }).__clipboardText = text;
  });
  registerMock("hud", () => undefined);
  registerMock("item_reveal", () => undefined);
}
