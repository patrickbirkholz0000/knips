// Interaktionstest des Video-Editors im Browser (Attrappen): Feld aufziehen, auswählen, springen, Stil, Folgen, Kürzen.
// Aufruf: pnpm dev (Port 1430), dann `node scripts/video-interact.mjs [ausgabeordner]`
import { chromium } from "playwright";
import { existsSync, readdirSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const out = process.argv[2] ?? "shots/video";
mkdirSync(out, { recursive: true });

function findChromium() {
  const cache = join(homedir(), "Library/Caches/ms-playwright");
  if (!existsSync(cache)) return undefined;
  for (const d of readdirSync(cache).filter((d) => d.startsWith("chromium-")).sort().reverse()) {
    for (const p of [
      join(cache, d, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
      join(cache, d, "chrome-mac/Chromium.app/Contents/MacOS/Chromium"),
    ]) if (existsSync(p)) return p;
  }
}
let browser;
try { browser = await chromium.launch(); } catch { browser = await chromium.launch({ executablePath: findChromium() }); }
const page = await browser.newPage({ viewport: { width: 1180, height: 760 }, deviceScaleFactor: 2 });
page.on("console", (m) => ["error", "warning"].includes(m.type()) && console.log(`[${m.type()}] ${m.text()}`));
page.on("pageerror", (e) => console.log(`[pageerror] ${e.message}`));
await page.goto("http://localhost:1430/#/video/00000000-0000-4000-8000-000000000002?auto=1");
await page.waitForTimeout(1500);

const shot = async (name) => { await page.waitForTimeout(350); await page.screenshot({ path: join(out, `${name}.png`) }); console.log("→", name); };
const canvas = await page.locator(".vid-stage canvas").boundingBox();
const vbox = await page.locator(".vid-stage video").boundingBox();
const at = (fx, fy) => [vbox.x + vbox.width * fx, vbox.y + vbox.height * fy];

// 1) Feld über die E-Mail-Zeile aufziehen (Balken)
await page.mouse.move(...at(0.33, 0.395));
await page.mouse.down();
await page.mouse.move(...at(0.62, 0.43), { steps: 6 });
await shot("1-ziehen");
await page.mouse.up();
await shot("2-ausgewaehlt");

// 2) Stil Unschärfe, dann Verpixeln
await page.click(".vid-segment button:nth-child(2)");
await shot("3-unschaerfe");
await page.click(".vid-segment button:nth-child(1)");
await shot("4-verpixeln");

// 3) Springen: Klick in die Zeitleiste bei ~40 %
const strip = await page.locator(".vid-strip").boundingBox();
await page.mouse.click(strip.x + strip.width * 0.4, strip.y + 20);
await shot("5-seek");

// 4) Folgen, danach weiterspringen
await page.click("text=Folgen");
await page.waitForTimeout(400);
await shot("6-folgen-busy");
await page.waitForTimeout(1200);
await page.mouse.click(strip.x + strip.width * 0.7, strip.y + 20);
await shot("7-folgt");

// 5) Kürzen: linker Griff nach rechts, Start hier, Auto-Zensur
const h = await page.locator(".vid-trim-handle.left").boundingBox();
await page.mouse.move(h.x + 6, h.y + 20);
await page.mouse.down();
await page.mouse.move(h.x + 6 + strip.width * 0.12, h.y + 20, { steps: 5 });
await page.mouse.up();
await page.click("text=Auto-Zensur");
await page.waitForTimeout(500);
await shot("8-auto-busy");
await page.waitForTimeout(1500);
await shot("9-gekuerzt-auto");

// 6) Entf löscht Auswahl, Strg+Z holt zurück
await page.keyboard.press("Delete");
await shot("10-geloescht");
await page.keyboard.press("Control+z");
await shot("11-undo");

// 7) Abspielen (Leertaste) kurz, dann anhalten
await page.keyboard.press(" ");
await page.waitForTimeout(900);
await page.keyboard.press(" ");
await shot("12-play");
await browser.close();
