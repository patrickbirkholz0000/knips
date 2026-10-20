// Knips-Telemetrie (Cloudflare Worker): nimmt anonyme Nutzungszähler an und zeigt sie auf /stats.
// Gespeichert werden nie IP-Adresse, User-Agent oder die install_id selbst — nur ihr gesalzener Hash.
// Liefert außerdem das Windows-Installationsskript aus (GET /install.ps1).

// Beim Bündeln als Text eingelesen (wrangler.toml, [[rules]]): die Datei aus dem Repo, keine Kopie.
import INSTALL_PS1 from "../../windows/install.ps1";

const REPO = "https://github.com/patrickbirkholz0000/knips";
const MAX_BODY = 4096;
const MAX_COUNT = 10000;
const MAX_PINGS_PER_DAY = 48;
const MAX_NEW_INSTALLS_PER_DAY = 5000;
const RETENTION_DAYS = 400;
// Ohne BOM: `irm … | iex` bekäme sonst ein unsichtbares Zeichen vor dem Skript.
const INSTALL_SCRIPT = INSTALL_PS1.replace(/^\uFEFF/, "");

// Auf jeder Antwort (nur dieser Worker, nicht zonenweit).
const SECURITY_HEADERS = {
  "Strict-Transport-Security": "max-age=31536000",
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};
const DEFAULT_CSP = "default-src 'none'; frame-ancestors 'none'";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Erlaubte Ereignisse mit Beschriftung für /stats. Alles andere wird verworfen.
const EVENTS = {
  app_launch: "App gestartet",
  capture_area: "Bereich",
  capture_window: "Fenster",
  capture_fullscreen: "Vollbild",
  capture_last_area: "Letzter Bereich",
  capture_scroll: "Scroll-Screenshot",
  capture_text: "Text erfassen",
  recording_start: "Aufnahme gestartet",
  recording_saved: "Aufnahme gespeichert",
  editor_open: "Bild-Editor",
  video_editor_open: "Video-Editor",
  censor_manual: "Zensur von Hand",
  censor_auto: "Auto-Zensur",
  censor_smart: "Schlaue Zensur",
  export_png: "Export PNG",
  export_jpeg: "Export JPEG",
  export_mp4: "Export MP4",
  export_gif: "Export GIF",
  copy_image: "Bild kopiert",
  copy_text: "Text kopiert",
  pin: "Angepinnt",
  drag_out: "Herausgezogen",
  history_open: "Verlauf",
  settings_open: "Einstellungen",
};

export default {
  async fetch(request, env) {
    return secure(await route(request, env));
  },

  // Täglich: alles älter als 400 Tage löschen.
  async scheduled(_controller, env) {
    const cutoff = isoDay(-RETENTION_DAYS);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM daily_events WHERE day < ?").bind(cutoff),
      env.DB.prepare("DELETE FROM daily WHERE day < ?").bind(cutoff),
      env.DB.prepare("DELETE FROM daily_new WHERE day < ?").bind(cutoff),
    ]);
  },
};

async function route(request, env) {
  const { pathname, searchParams } = new URL(request.url);
  try {
    if (pathname === "/v1/ping") {
      return request.method === "POST" ? await ping(request, env) : plain("Nur POST", 405, { Allow: "POST" });
    }
    if (pathname === "/v1/health") return plain("ok");
    if (pathname === "/install.ps1") {
      return request.method === "GET" || request.method === "HEAD"
        ? installScript(request)
        : plain("Nur GET", 405, { Allow: "GET, HEAD" });
    }
    if (pathname === "/stats") return await stats(request, env, searchParams);
    if (pathname === "/") return new Response(null, { status: 302, headers: { Location: REPO } });
    return plain("Nicht gefunden", 404);
  } catch {
    return plain("Vorübergehender Fehler", 503);
  }
}

function secure(response) {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) headers.set(name, value);
  const csp = headers.get("Content-Security-Policy");
  if (!csp) headers.set("Content-Security-Policy", DEFAULT_CSP);
  else if (!/frame-ancestors/.test(csp)) headers.set("Content-Security-Policy", `${csp}; frame-ancestors 'none'`);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

// Ratenbegrenzung je IP-Adresse über das Rate-Limiting-Binding. Die Adresse dient nur als Schlüssel im
// flüchtigen Zähler von Cloudflare und wird weder gespeichert noch geloggt. Ohne Binding oder Adresse
// (lokale Tests) wird nicht begrenzt, bei einem Fehler des Bindings ebenfalls nicht.
async function withinLimit(limiter, request) {
  const ip = request.headers.get("cf-connecting-ip");
  if (!limiter || !ip) return true;
  try {
    const { success } = await limiter.limit({ key: ip });
    return success;
  } catch {
    return true;
  }
}

// ---------- Installationsskript ----------

function installScript(request) {
  return new Response(request.method === "HEAD" ? null : INSTALL_SCRIPT, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "public, max-age=300",
      "Content-Disposition": 'inline; filename="install.ps1"',
    },
  });
}

// ---------- Annahme ----------

async function ping(request, env) {
  // 429 statt 204: Die Apps behalten ihre Zähler dann und senden später noch einmal.
  if (!(await withinLimit(env.PING_LIMITER, request))) return plain("Zu viele Anfragen", 429, { "Retry-After": "60" });
  const raw = await readLimited(request, MAX_BODY);
  if (raw === null) return plain("Zu groß", 413);
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return plain("Kein JSON", 400);
  }
  const p = parsePing(body);
  // Unbekannte App, falsche UUID usw.: still verwerfen, damit kein Client endlos neu sendet.
  if (!p) return new Response(null, { status: 204 });
  if (!env.SALT) return plain("Nicht eingerichtet", 503);

  const day = isoDay(0);
  const hash = await installHash(p.installId, env.SALT);
  const cc = request.cf?.country;
  const country = typeof cc === "string" && /^[A-Z0-9]{2}$/.test(cc) ? cc : null;

  // Höchstens 5000 neue Installationen pro UTC-Tag (Schutz gegen massenhaft erfundene IDs); darüber still
  // verwerfen. Zählt nur, wer noch nie gesendet hat.
  if (!(await acceptNewInstall(env, day, hash))) return new Response(null, { status: 204 });

  // Zeile des Tages anlegen bzw. auffrischen (fehlende Angaben überschreiben bekannte nicht);
  // ab 48 Pings pro Tag passiert nichts mehr.
  const row = await env.DB.prepare(
    `INSERT INTO daily (day, install_hash, platform, channel, app_version, build, os_version, arch, lang, country, pings, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, ?11)
     ON CONFLICT (day, install_hash) DO UPDATE SET
       platform = excluded.platform, channel = excluded.channel,
       app_version = COALESCE(excluded.app_version, daily.app_version), build = COALESCE(excluded.build, daily.build),
       os_version = COALESCE(excluded.os_version, daily.os_version), arch = COALESCE(excluded.arch, daily.arch),
       lang = COALESCE(excluded.lang, daily.lang), country = COALESCE(excluded.country, daily.country),
       pings = daily.pings + 1, updated_at = excluded.updated_at
     WHERE daily.pings < ?12
     RETURNING pings`,
  )
    .bind(day, hash, p.platform, p.channel, p.appVersion, p.build, p.osVersion, p.arch, p.lang, country,
      new Date().toISOString().slice(0, 19) + "Z", MAX_PINGS_PER_DAY)
    .first();

  if (row && p.events.length) {
    await env.DB.batch(p.events.map(([name, count]) =>
      env.DB.prepare(
        `INSERT INTO daily_events (day, install_hash, name, count) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (day, install_hash, name) DO UPDATE SET count = daily_events.count + excluded.count`,
      ).bind(day, hash, name, count)));
  }
  return new Response(null, { status: 204 });
}

async function acceptNewInstall(env, day, hash) {
  try {
    const known = await env.DB.prepare("SELECT 1 FROM daily WHERE install_hash = ?1 LIMIT 1").bind(hash).first();
    if (known) return true;
    // Hochzählen nur unter der Grenze; ohne Rückgabezeile ist sie erreicht.
    const counted = await env.DB.prepare(
      `INSERT INTO daily_new (day, installs) VALUES (?1, 1)
       ON CONFLICT (day) DO UPDATE SET installs = daily_new.installs + 1
       WHERE daily_new.installs < ?2
       RETURNING installs`,
    ).bind(day, MAX_NEW_INSTALLS_PER_DAY).first();
    return counted !== null;
  } catch {
    // Fehlt z. B. die Tabelle daily_new (schema.sql nicht eingespielt), lieber annehmen als alles verlieren.
    return true;
  }
}

function parsePing(b) {
  if (!b || typeof b !== "object" || Array.isArray(b)) return null;
  if (b.v !== 1 || b.app !== "knips") return null;
  if (b.platform !== "macos" && b.platform !== "windows") return null;
  if (b.channel !== "release" && b.channel !== "dev") return null;
  if (typeof b.install_id !== "string" || !UUID.test(b.install_id)) return null;

  const events = [];
  if (b.events && typeof b.events === "object" && !Array.isArray(b.events)) {
    for (const [name, n] of Object.entries(b.events)) {
      if (!Object.hasOwn(EVENTS, name) || typeof n !== "number" || !Number.isFinite(n)) continue;
      const count = Math.min(MAX_COUNT, Math.max(0, Math.floor(n)));
      if (count > 0) events.push([name, count]);
    }
  }
  return {
    platform: b.platform,
    channel: b.channel,
    installId: b.install_id.toLowerCase(),
    appVersion: token(b.app_version),
    build: token(b.build),
    osVersion: token(b.os_version),
    arch: b.arch === "arm64" || b.arch === "x86_64" ? b.arch : null,
    lang: typeof b.lang === "string" && /^[a-z]{2}$/i.test(b.lang) ? b.lang.toLowerCase() : null,
    events,
  };
}

// Versionsangaben: nur kurze, harmlose Zeichenketten.
function token(s) {
  return typeof s === "string" && /^[0-9A-Za-z._+-]{1,32}$/.test(s) ? s : null;
}

async function installHash(id, salt) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id + salt));
  return hex(digest).slice(0, 32);
}

// Liest höchstens `limit` Bytes; null, wenn der Body größer ist.
async function readLimited(request, limit) {
  if (Number(request.headers.get("content-length")) > limit) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

// ---------- Statistikseite ----------

async function authorized(request, env) {
  const header = request.headers.get("authorization") ?? "";
  if (!env.STATS_PASSWORD || !header.startsWith("Basic ")) return false;
  let decoded;
  try {
    decoded = atob(header.slice(6).trim());
  } catch {
    return false;
  }
  const i = decoded.indexOf(":");
  if (i < 0 || decoded.slice(0, i) !== "knips") return false;
  // Über Hashes vergleichen: gleiche Länge, konstante Zeit.
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(decoded.slice(i + 1))),
    crypto.subtle.digest("SHA-256", enc.encode(env.STATS_PASSWORD)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

async function stats(request, env, params) {
  // Anmeldeversuche je IP begrenzen. Das Binding kann den Stand nur zählend abfragen, deshalb zählt jede Anfrage
  // mit Zugangsdaten (auch erfolgreiche) — sonst ließe sich nach Erreichen der Grenze weiter raten.
  if (request.headers.has("authorization") && !(await withinLimit(env.STATS_LIMITER, request))) {
    return plain("Zu viele Anmeldeversuche, bitte in einer Minute noch einmal.", 429, { "Retry-After": "60" });
  }
  if (!(await authorized(request, env))) {
    return plain("Anmeldung nötig", 401, { "WWW-Authenticate": 'Basic realm="Knips-Statistik", charset="UTF-8"' });
  }
  const channel = params.get("channel") === "dev" ? "dev" : "release";
  const today = isoDay(0);
  const from7 = isoDay(-6);
  const from30 = isoDay(-29);
  const days = Array.from({ length: 30 }, (_, i) => isoDay(i - 29));

  // Aufteilungen: jede in 30 Tagen aktive Installation mit ihrem jüngsten Stand.
  const latest = `WITH last AS (SELECT install_hash, MAX(day) AS day FROM daily
    WHERE channel = ?1 AND day >= ?2 GROUP BY install_hash) `;
  const split = (key) => env.DB.prepare(
    `${latest}SELECT ${key} AS k, COUNT(*) AS n FROM daily d JOIN last USING (install_hash, day) GROUP BY k ORDER BY n DESC, k`,
  ).bind(channel, from30);

  const results = await env.DB.batch([
    env.DB.prepare(
      `SELECT COUNT(DISTINCT CASE WHEN day = ?3 THEN install_hash END) AS d1,
              COUNT(DISTINCT CASE WHEN day >= ?4 THEN install_hash END) AS d7,
              COUNT(DISTINCT install_hash) AS d30
       FROM daily WHERE channel = ?1 AND day >= ?2`,
    ).bind(channel, from30, today, from7),
    env.DB.prepare("SELECT day AS k, COUNT(*) AS n FROM daily WHERE channel = ?1 AND day >= ?2 GROUP BY day")
      .bind(channel, from30),
    env.DB.prepare(
      `SELECT first AS k, COUNT(*) AS n FROM (SELECT install_hash, MIN(day) AS first FROM daily
         WHERE channel = ?1 GROUP BY install_hash) WHERE first >= ?2 GROUP BY first`,
    ).bind(channel, from30),
    split("d.platform"),
    split("d.app_version || COALESCE(' (' || d.build || ')', '')"),
    split("d.platform || COALESCE(' ' || d.os_version, '')"),
    split("d.arch"),
    split("d.country"),
    split("d.lang"),
    env.DB.prepare(
      `SELECT e.day, e.name, SUM(e.count) AS n FROM daily_events e JOIN daily d USING (day, install_hash)
       WHERE d.channel = ?1 AND e.day >= ?2 GROUP BY e.day, e.name`,
    ).bind(channel, from30),
    env.DB.prepare(
      `SELECT e.name AS k, COUNT(DISTINCT e.install_hash) AS n FROM daily_events e JOIN daily d USING (day, install_hash)
       WHERE d.channel = ?1 AND e.day >= ?2 GROUP BY e.name`,
    ).bind(channel, from30),
  ]);
  const [active, perDay, fresh, platform, version, os, arch, country, lang, events, reach] = results.map((r) => r.results);

  const html = renderStats({
    channel, today, days,
    active: active[0] ?? { d1: 0, d7: 0, d30: 0 },
    perDay: toMap(perDay), fresh: toMap(fresh),
    splits: [
      ["Plattform", platform, platformLabel],
      ["Version", version, (k) => k],
      ["Betriebssystem", os, osLabel],
      ["Architektur", arch, (k) => k],
      ["Land", country, countryLabel],
      ["Sprache", lang, langLabel],
    ],
    events, reach: toMap(reach),
  });
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
    },
  });
}

function renderStats({ channel, today, days, active, perDay, fresh, splits, events, reach }) {
  const freshTotal = days.reduce((s, d) => s + (fresh.get(d) ?? 0), 0);

  // Ereignisse: Summe, Tageswerte, Reichweite.
  const byName = new Map();
  for (const { day, name, n } of events) {
    if (!Object.hasOwn(EVENTS, name)) continue;
    const e = byName.get(name) ?? { total: 0, perDay: new Map() };
    e.total += n;
    e.perDay.set(day, n);
    byName.set(name, e);
  }
  const used = [...byName.entries()].sort((a, b) => b[1].total - a[1].total);
  const unused = Object.keys(EVENTS).filter((n) => !byName.has(n));

  const eventRows = used.map(([name, e]) => `<tr>
      <td><span class="label">${esc(EVENTS[name])}</span> <code>${name}</code></td>
      <td class="num">${fmt(e.total)}</td>
      <td class="num">${fmt(reach.get(name) ?? 0)}<span class="pct">${pct(reach.get(name) ?? 0, active.d30)}</span></td>
      <td class="spark-cell">${columns(days, e.perDay, { max: Math.max(...e.perDay.values()), small: true, unit: EVENTS[name] })}</td>
    </tr>`).join("");

  const tableHead = used.map(([name]) => `<th scope="col" class="num">${esc(EVENTS[name])}</th>`).join("");
  const tableRows = [...days].reverse().map((d) => `<tr><th scope="row">${shortDate(d)}</th>
      <td class="num">${fmt(perDay.get(d) ?? 0)}</td><td class="num">${fmt(fresh.get(d) ?? 0)}</td>
      ${used.map(([, e]) => `<td class="num">${fmt(e.perDay.get(d) ?? 0)}</td>`).join("")}</tr>`).join("");

  const other = channel === "dev" ? ["/stats", "Release"] : ["/stats?channel=dev", "Entwickler-Builds"];

  return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Knips-Statistik</title>
<style>${CSS}</style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>Knips · Nutzung</h1>
      <p class="sub">${channel === "dev" ? "Entwickler-Builds" : "Release"} · Stand ${esc(new Date().toISOString().slice(0, 16).replace("T", " "))} UTC · Tage in UTC</p>
    </div>
    <a class="switch" href="${other[0]}">${other[1]} zeigen</a>
  </header>

  <section class="kpis" aria-label="Aktive Installationen">
    <div class="kpi"><span class="k">Aktiv heute</span><span class="v">${fmt(active.d1)}</span></div>
    <div class="kpi"><span class="k">Aktiv 7 Tage</span><span class="v">${fmt(active.d7)}</span></div>
    <div class="kpi"><span class="k">Aktiv 30 Tage</span><span class="v">${fmt(active.d30)}</span></div>
    <div class="kpi"><span class="k">Neu in 30 Tagen</span><span class="v">${fmt(freshTotal)}</span></div>
  </section>

  <section class="charts">
    ${chartCard("Aktive Installationen pro Tag", days, perDay, "aktiv")}
    ${chartCard("Neue Installationen pro Tag", days, fresh, "neu")}
  </section>

  <h2>Aufteilung <span class="hint">aktive Installationen der letzten 30 Tage, jeweils jüngster Stand</span></h2>
  <section class="splits">
    ${splits.map(([title, rows, label]) => splitCard(title, rows, label, active.d30)).join("")}
  </section>

  <h2>Funktionen <span class="hint">Summe der letzten 30 Tage; Verlauf je Zeile auf ihren Höchstwert skaliert</span></h2>
  <section class="card">
    ${used.length ? `<div class="scroll"><table class="events">
      <thead><tr><th scope="col">Funktion</th><th scope="col" class="num">Anzahl</th><th scope="col" class="num">Installationen</th><th scope="col" class="spark-cell">pro Tag</th></tr></thead>
      <tbody>${eventRows}</tbody></table></div>` : `<p class="empty">Noch keine Daten.</p>`}
    ${unused.length && used.length ? `<p class="unused">Nicht genutzt: ${unused.map((n) => esc(EVENTS[n])).join(", ")}</p>` : ""}
  </section>

  <details class="card">
    <summary>Alle Tageswerte als Tabelle</summary>
    <div class="scroll"><table class="days">
      <thead><tr><th scope="col">Tag</th><th scope="col" class="num">Aktiv</th><th scope="col" class="num">Neu</th>${tableHead}</tr></thead>
      <tbody>${tableRows}</tbody>
    </table></div>
  </details>

  <footer>Nur anonyme Zähler: kein Inhalt, keine IP-Adresse, keine Geräte-ID im Klartext. Daten älter als 400 Tage werden täglich gelöscht. <a href="${REPO}">Quelltext</a></footer>
</main>
</body>
</html>`;
}

function chartCard(title, days, values, unit) {
  const last = values.get(days[days.length - 1]) ?? 0;
  const max = Math.max(0, ...days.map((d) => values.get(d) ?? 0));
  return `<div class="card chart">
    <div class="chart-head"><h3>${title}</h3><span class="meta">heute <b>${fmt(last)}</b> · Höchstwert ${fmt(max)}</span></div>
    ${columns(days, values, { max, unit })}
    <div class="axis"><span>${shortDate(days[0])}</span><span>${shortDate(days[14])}</span><span>${shortDate(days[29])}</span></div>
  </div>`;
}

// Säulen als HTML (skaliert ohne Verzerrung); Tageswert im Tooltip.
function columns(days, values, { max, small = false, unit }) {
  const cols = days.map((d) => {
    const n = values.get(d) ?? 0;
    const h = max > 0 && n > 0 ? Math.max(4, Math.round((n / max) * 100)) : 0;
    return `<span class="col" title="${shortDate(d)}: ${fmt(n)} ${esc(unit)}"><i style="height:${h}%"></i></span>`;
  }).join("");
  return `<div class="cols${small ? " small" : ""}" role="img" aria-label="${esc(unit)} pro Tag, 30 Tage">${cols}</div>`;
}

function splitCard(title, rows, label, total) {
  const top = rows.slice(0, 8);
  const rest = rows.slice(8).reduce((s, r) => s + r.n, 0);
  if (rest) top.push({ k: "\u0000rest", n: rest });
  const max = Math.max(1, ...top.map((r) => r.n));
  const body = top.map((r) => `<tr>
      <td>${esc(r.k === "\u0000rest" ? "Andere" : r.k == null ? "unbekannt" : label(r.k))}</td>
      <td class="bar"><i style="width:${Math.max(2, Math.round((r.n / max) * 100))}%"></i></td>
      <td class="num">${fmt(r.n)}</td><td class="num pct">${pct(r.n, total)}</td></tr>`).join("");
  return `<div class="card split"><h3>${title}</h3>${top.length ? `<table>${body}</table>` : `<p class="empty">Noch keine Daten.</p>`}</div>`;
}

// ---------- Beschriftungen ----------

function platformLabel(k) {
  return k === "macos" ? "macOS" : k === "windows" ? "Windows" : k;
}

function osLabel(k) {
  const [p, v] = k.split(" ");
  if (!v) return `${platformLabel(p)}, Version unbekannt`;
  if (p === "windows") {
    const build = Number(/^10\.0\.(\d+)/.exec(v)?.[1]);
    if (build) return `Windows ${build >= 22000 ? 11 : 10} (${build})`;
  }
  return `${platformLabel(p)} ${v}`;
}

const regionNames = displayNames("region");
const languageNames = displayNames("language");

function displayNames(type) {
  try {
    return new Intl.DisplayNames(["de"], { type });
  } catch {
    return null;
  }
}

function countryLabel(k) {
  if (k === "T1") return "Tor";
  if (k === "XX") return "unbekannt";
  try {
    return `${regionNames?.of(k) ?? k} (${k})`;
  } catch {
    return k;
  }
}

function langLabel(k) {
  try {
    return `${languageNames?.of(k) ?? k} (${k})`;
  } catch {
    return k;
  }
}

// ---------- Hilfen ----------

const numberFormat = new Intl.NumberFormat("de-DE");
const fmt = (n) => numberFormat.format(n ?? 0);
const pct = (n, total) => (total > 0 ? ` ${Math.round((n / total) * 100)} %` : "");
const toMap = (rows) => new Map(rows.map((r) => [r.k, r.n]));
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

function isoDay(offset) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offset);
  return d.toISOString().slice(0, 10);
}

function shortDate(day) {
  return `${day.slice(8, 10)}.${day.slice(5, 7)}.`;
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function plain(text, status = 200, headers = {}) {
  return new Response(text, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", ...headers } });
}

const CSS = `
:root{color-scheme:light;--bg:#f3f3f1;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#6c6b66;--rule:#e2e1dc;--track:#ecebe7;--series:#2a78d6;--series-hover:#1c5fb0}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#111110;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#96958d;--rule:#2e2e2b;--track:#262624;--series:#3987e5;--series-hover:#6aa7ee}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1080px;margin:0 auto;padding:28px 16px 40px}
header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap;margin-bottom:20px}
h1{font-size:22px;margin:0;letter-spacing:-.01em}
h2{font-size:15px;margin:28px 0 10px;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
h3{font-size:13px;margin:0;color:var(--ink2);font-weight:600}
.hint{font-weight:400;color:var(--muted);font-size:12.5px}
.sub{margin:4px 0 0;color:var(--muted);font-size:12.5px}
a{color:var(--series)}
.switch{font-size:13px;text-decoration:none;border:1px solid var(--rule);background:var(--surface);color:var(--ink);padding:6px 12px;border-radius:8px;white-space:nowrap}
.switch:hover{border-color:var(--muted)}
.card{background:var(--surface);border:1px solid var(--rule);border-radius:12px;padding:16px}
.kpis{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.kpi{background:var(--surface);border:1px solid var(--rule);border-radius:12px;padding:14px 16px;display:flex;flex-direction:column;gap:2px}
.kpi .k{color:var(--muted);font-size:12.5px}
.kpi .v{font-size:30px;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.charts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-top:12px}
.chart-head{display:flex;justify-content:space-between;align-items:baseline;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.meta{color:var(--muted);font-size:12.5px}.meta b{color:var(--ink);font-weight:600}
.cols{display:flex;align-items:flex-end;gap:2px;height:120px;border-bottom:1px solid var(--rule)}
.cols.small{height:28px;min-width:120px;gap:1px}
.col{flex:1 1 0;height:100%;display:flex;align-items:flex-end;justify-content:center}
.col i{display:block;width:100%;max-width:24px;background:var(--series);border-radius:4px 4px 0 0}
.cols.small .col i{border-radius:2px 2px 0 0}
.col:hover i{background:var(--series-hover)}
.col:hover{background:var(--track);border-radius:3px 3px 0 0}
.axis{display:flex;justify-content:space-between;color:var(--muted);font-size:11.5px;margin-top:6px;font-variant-numeric:tabular-nums}
.splits{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}
.split h3{margin-bottom:10px}
table{border-collapse:collapse;width:100%}
td,th{padding:5px 0;vertical-align:middle;text-align:left}
.split td{font-size:13px}
.split td:first-child{overflow-wrap:anywhere;padding-right:10px}
.split td.bar{width:34%}
.bar i{display:block;height:10px;background:var(--series);border-radius:0 4px 4px 0}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;padding-left:10px}
.pct{color:var(--muted);font-size:12px;padding-left:6px}
td.pct{width:42px}
.scroll{overflow-x:auto}
.events thead th,.days thead th{font-size:12px;color:var(--muted);font-weight:500;border-bottom:1px solid var(--rule);padding-bottom:8px}
.events td{border-bottom:1px solid var(--rule);padding:8px 0}
.events tr:last-child td{border-bottom:0}
.events .label{font-weight:500}
code{font:11.5px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--muted);margin-left:4px}
.events .spark-cell{width:42%;padding-left:16px}
.unused{margin:12px 0 0;color:var(--muted);font-size:12.5px}
.empty{color:var(--muted);margin:4px 0}
details{margin-top:12px}
summary{cursor:pointer;font-weight:600;font-size:13px}
.days{margin-top:12px;font-size:12.5px}
.days td,.days th{padding:4px 0 4px 12px;white-space:nowrap}
.days th:first-child{padding-left:0;text-align:left}
.days tbody th{font-weight:500;color:var(--ink2)}
.days tbody tr:nth-child(odd){background:var(--bg)}
footer{margin-top:28px;color:var(--muted);font-size:12px}
@media (max-width:720px){.kpis{grid-template-columns:repeat(2,minmax(0,1fr))}.charts{grid-template-columns:1fr}.kpi .v{font-size:26px}.events .spark-cell{width:auto;padding-left:8px}.events .pct{display:none}.events .num{padding-left:6px}.cols.small{min-width:70px}.events{font-size:13px}code{display:none}}
`;
