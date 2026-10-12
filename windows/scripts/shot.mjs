// Screenshot einer Ansicht im Browser (Attrappe statt Tauri) — zum Prüfen der Oberfläche auf dem Mac.
// Aufruf: pnpm dev (läuft auf :1430), dann
//   node scripts/shot.mjs "<hash ohne #>" <ausgabe.png> [breite] [höhe] [--transparent] [--hover=<css-selektor>] [--wait=<ms>] [--scale=2]
// Beispiel: node scripts/shot.mjs "/menu" shots/menu.png 340 520 --transparent
import { chromium } from "playwright";
import { existsSync, readdirSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const [hash, out, w = "900", h = "640", ...flags] = process.argv.slice(2);
if (!hash || !out) {
  console.error("Aufruf: node scripts/shot.mjs <hash> <out.png> [w] [h] [--transparent] [--hover=sel] [--click=sel] [--wait=ms] [--scale=2]");
  process.exit(2);
}
const flag = (name) => flags.find((f) => f.startsWith(`--${name}`))?.split("=").slice(1).join("=");

// Vorhandenes Chromium aus dem Playwright-Cache nehmen, falls die passende Version fehlt.
function findChromium() {
  const cache = join(homedir(), "Library/Caches/ms-playwright");
  if (!existsSync(cache)) return undefined;
  for (const d of readdirSync(cache).filter((d) => d.startsWith("chromium-")).sort().reverse()) {
    const p = join(cache, d, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    const p2 = join(cache, d, "chrome-mac/Chromium.app/Contents/MacOS/Chromium");
    if (existsSync(p)) return p;
    if (existsSync(p2)) return p2;
  }
  return undefined;
}

let browser;
try {
  browser = await chromium.launch();
} catch {
  browser = await chromium.launch({ executablePath: findChromium() });
}
const page = await browser.newPage({
  viewport: { width: Number(w), height: Number(h) },
  deviceScaleFactor: Number(flag("scale") ?? 2),
});
page.on("console", (m) => {
  if (m.type() === "error" || m.type() === "warning") console.log(`[${m.type()}] ${m.text()}`);
});
page.on("pageerror", (e) => console.log(`[pageerror] ${e.message}`));
await page.goto(`http://localhost:1430/#${hash.replace(/^#/, "")}`);
await page.waitForTimeout(Number(flag("wait") ?? 600));
const hover = flag("hover");
if (hover) await page.hover(hover);
const click = flag("click");
if (click) await page.click(click);
if (hover || click) await page.waitForTimeout(300);
mkdirSync(dirname(out), { recursive: true });
await page.screenshot({ path: out, omitBackground: flags.includes("--transparent") });
await browser.close();
console.log(`→ ${out}`);
