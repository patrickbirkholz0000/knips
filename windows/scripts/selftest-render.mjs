// Rendert die drei Selbsttest-Dokumente im Browser und speichert sie als PNG (zum Vergleich mit tests/vergleich/mac-render-*.png).
// Aufruf: node scripts/selftest-render.mjs [ausgabeordner=shots/selftest]
import { chromium } from "playwright";
import { existsSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
const out = process.argv[2] ?? "shots/selftest";
mkdirSync(out, { recursive: true });
function findChromium() {
  const cache = join(homedir(), "Library/Caches/ms-playwright");
  if (!existsSync(cache)) return undefined;
  for (const d of readdirSync(cache).filter((d) => d.startsWith("chromium-")).sort().reverse())
    for (const p of [join(cache, d, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"), join(cache, d, "chrome-mac/Chromium.app/Contents/MacOS/Chromium")])
      if (existsSync(p)) return p;
}
let browser;
try { browser = await chromium.launch(); } catch { browser = await chromium.launch({ executablePath: findChromium() }); }
const page = await browser.newPage();
await page.goto("http://localhost:1430/#/selftest-render");
await page.waitForFunction(() => window.__knipsSelftestRender);
const res = await page.evaluate(() => window.__knipsSelftestRender());
for (const r of res) {
  writeFileSync(`${out}/render-${r.name}.png`, Buffer.from(r.png.split(",")[1], "base64"));
  console.log(r.name, r.width, r.height);
}
await browser.close();
