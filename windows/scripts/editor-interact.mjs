// Interaktionstest des Editors im Browser (Attrappe): zeichnet, zensiert, schneidet zu, zoomt — mit Screenshots.
// Aufruf: node scripts/editor-interact.mjs [ausgabeordner=shots/editor-interact]
import { chromium } from "playwright";
import { existsSync, readdirSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const out = process.argv[2] ?? "shots/editor-interact";
mkdirSync(out, { recursive: true });
function findChromium() {
  const cache = join(homedir(), "Library/Caches/ms-playwright");
  if (!existsSync(cache)) return undefined;
  for (const d of readdirSync(cache).filter((d) => d.startsWith("chromium-")).sort().reverse()) {
    for (const p of [join(cache, d, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"), join(cache, d, "chrome-mac/Chromium.app/Contents/MacOS/Chromium")])
      if (existsSync(p)) return p;
  }
}
let browser;
try { browser = await chromium.launch(); } catch { browser = await chromium.launch({ executablePath: findChromium() }); }
const page = await browser.newPage({ viewport: { width: 1200, height: 640 }, deviceScaleFactor: 2 });
page.on("console", (m) => { if (["error", "warning", "info"].includes(m.type())) console.log(`[${m.type()}] ${m.text()}`); });
page.on("pageerror", (e) => console.log(`[pageerror] ${e.message}`));
await page.goto("http://localhost:1430/#/editor/00000000-0000-4000-8000-000000000001");
await page.waitForSelector(".ed-stage canvas");
await page.waitForTimeout(800);

// Bild (1400×880, Scale 2) → Seitenkoordinaten bei „Einpassen“
async function geom() {
  const b = await page.locator(".ed-stage").boundingBox();
  const s = Math.min((b.width - 64) / 1400, (b.height - 64) / 880, 0.5);
  const ox = b.x + Math.round((b.width - 1400 * s) / 2), oy = b.y + Math.round((b.height - 880 * s) / 2);
  return { s, pt: (x, y) => [ox + x * s, oy + y * s], b };
}
const shot = (n) => page.screenshot({ path: `${out}/${n}.png` });
const key = (k) => page.keyboard.press(k);
const toast = () => page.locator(".ed-pill").innerText().catch(() => "");
let g = await geom();

// 1. Schlaue Zensur: Klick auf Text = Zeile, Alt-Klick = Wort
await key("x");
await page.mouse.click(...g.pt(500, 250)); // E-Mail-Zeile (y ≈ 124 pt = 248 px)
await page.mouse.move(...g.pt(900, 330));
await shot("1-klick-zeile");
await page.keyboard.down("Alt");
await page.mouse.click(...g.pt(1000, 312)); // Telefon-Zeile, Wort (y 152 pt = 304 px)
await page.keyboard.up("Alt");
await shot("2-alt-wort");
// Ziehen schnappt an Wörter: Balken über Teil der IBAN
await page.mouse.move(...g.pt(560, 366));
await page.mouse.down();
await page.mouse.move(...g.pt(700, 370), { steps: 5 });
await page.mouse.up();
await shot("3-ziehen-schnappt");

// 2. Formen
await key("a");
await page.mouse.move(...g.pt(1260, 120)); await page.mouse.down(); await page.mouse.move(...g.pt(1040, 230), { steps: 6 }); await page.mouse.up();
await key("r");
await page.mouse.move(...g.pt(380, 490)); await page.mouse.down(); await page.mouse.move(...g.pt(1300, 580), { steps: 6 }); await page.mouse.up();
await key("n");
await page.mouse.click(...g.pt(360, 200)); await page.mouse.click(...g.pt(360, 256));
await key("h");
await page.mouse.move(...g.pt(386, 500)); await page.mouse.down(); await page.mouse.move(...g.pt(900, 532), { steps: 6 }); await page.mouse.up();
await key("t");
await page.mouse.click(...g.pt(820, 660));
await page.keyboard.type("Hier klicken!");
await key("Enter");
await shot("4-formen");
console.log("Toolbar-Hinweis/Undo aktiv:", await page.locator(".ed-icon:not([disabled])").count());

// 3. Auswahl verschieben, Undo/Redo
await key("v");
await page.mouse.move(...g.pt(1100, 175)); await page.mouse.down(); await page.mouse.move(...g.pt(1000, 150), { steps: 4 }); await page.mouse.up();
await shot("5-verschoben");
await page.keyboard.press("Control+z");
await page.keyboard.press("Control+z");
await page.keyboard.press("Control+Shift+z");
await shot("6-undo-redo");

// 4. Rahmen-Popover
await page.click('button[title="Hintergrund und Rahmen"]');
await page.click(".ed-grads button:nth-child(2)");
await shot("7-rahmen-popover");
await page.keyboard.press("Escape");
await page.mouse.click(600, 30);
await page.waitForTimeout(300);
await shot("8-rahmen");
await page.click('button[title="Hintergrund und Rahmen"]');
await page.locator(".ed-popover input.ed-switch").first().uncheck();
await page.mouse.click(300, 30);

// 5. Zuschneiden
await key("c");
await page.waitForTimeout(200);
g = await geom();
await shot("9-crop-start");
await page.mouse.move(...g.pt(0, 0)); await page.mouse.down(); await page.mouse.move(...g.pt(340, 60), { steps: 6 }); await page.mouse.up();
await page.mouse.move(...g.pt(1400, 880)); await page.mouse.down(); await page.mouse.move(...g.pt(1340, 480), { steps: 6 }); await page.mouse.up();
await shot("10-crop-ziehen");
await key("Enter");
await page.waitForTimeout(300);
await shot("11-zugeschnitten");

// 6. Zoom
await page.keyboard.press("Control+1");
await page.waitForTimeout(200);
await shot("12-zoom100");
await page.keyboard.press("Control+0");
await page.keyboard.press("Control+=");
await page.waitForTimeout(200);
await shot("13-zoom-plus");
await page.keyboard.press("Control+0");

// 7. Speichern / Kopieren / Text kopieren
await page.keyboard.press("Control+s");
await page.waitForTimeout(500);
console.log("Toast Speichern:", await toast());
await page.click('button[title^="Kopieren"]');
await page.waitForTimeout(500);
console.log("Toast Kopieren:", await toast());
await page.click('button[title^="Text kopieren"]');
await page.waitForTimeout(500);
console.log("Toast Text:", await toast());
console.log("Zwischenablage:", JSON.stringify(await page.evaluate(() => window.__clipboardText)));
console.log("Commits:", JSON.stringify(await page.evaluate(() => window.__commits)));
await shot("14-toast");
await browser.close();
