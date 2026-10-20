# Knips-Telemetrie

Ein kleiner Cloudflare Worker unter `https://knips.velno.ai`. Er nimmt anonyme Nutzungszähler der
Knips-Apps (macOS und Windows) an — aber nur, wenn man beim ersten Start oder später in den
Einstellungen zugestimmt hat. Ohne Zustimmung sendet Knips nichts.

Außerdem liefert er das Windows-Installationsskript aus: `GET /install.ps1` (für
`irm https://knips.velno.ai/install.ps1 | iex`). Es wird beim Bündeln aus `../windows/install.ps1`
gelesen (Text-Modul, `[[rules]]` in `wrangler.toml`), es gibt also nur eine Fassung im Repo. Ausgeliefert
als `text/plain; charset=utf-8` ohne BOM, 5 Minuten Cache. Nach jeder Änderung an `install.ps1` den Worker
neu deployen.

## Was gesendet wird

Höchstens einmal am Tag ein `POST /v1/ping` mit:

- Zählern, wie oft Funktionen genutzt wurden, z. B. „3 Bereichs-Screenshots, 2× Editor geöffnet“.
  Die erlaubten Namen stehen in `src/index.js` (`EVENTS`); alles andere verwirft der Server.
- App-Version und Build, Kanal (`release` oder `dev`), Plattform, Betriebssystem-Version,
  Prozessorarchitektur und Sprache (zwei Buchstaben).
- einer zufälligen Installations-ID (UUID). Sie entsteht beim Zustimmen und wird beim Widerruf gelöscht.

## Was nie gesendet oder gespeichert wird

- keine Bilder, Videos, Texte, Dateinamen, Fenstertitel, App-Namen, Bildschirmgrößen oder Zeitangaben
- keine IP-Adresse und kein User-Agent. Cloudflare verarbeitet die IP als Hoster beim Transport wie jeder
  Webserver; der Worker speichert sie nicht, und Workers Logs sind abgeschaltet. Für die Ratenbegrenzung
  (unten) dient sie nur als Schlüssel im flüchtigen Zähler von Cloudflare.
- die Installations-ID nicht im Klartext: gespeichert wird nur `sha256(ID + geheimes Salz)`, gekürzt
  auf 32 Zeichen. Das Land kommt als zweistelliger Code von Cloudflare (`request.cf.country`).

## Speicherung

D1-Datenbank `knips-telemetry` (Westeuropa), Schema in `schema.sql`: je Installation und UTC-Tag eine
Zeile in `daily` (dazu die Serverzeit des letzten Pings an diesem Tag), die Zähler in `daily_events`, und
in `daily_new` nur die Zahl neuer Installationen je Tag. Jeden Tag um 03:30 UTC löscht ein Cron-Trigger
alles, was älter als 400 Tage ist.

## Schutz gegen Missbrauch

- Body höchstens 4 KB (sonst `413`), kein JSON → `400`. Unbekannte App, falsche UUID oder unbekannte
  Plattform werden still verworfen (`204`), Zähler auf 0–10.000 begrenzt, mehr als 48 Pings pro
  Installation und Tag ignoriert.
- Ratenbegrenzung je IP-Adresse über das Rate-Limiting-Binding von Cloudflare (`[[ratelimits]]` in
  `wrangler.toml`, gilt je Cloudflare-Standort und ist bewusst ungenau): `/v1/ping` 10 pro Minute, darüber
  `429` (die Apps behalten ihre Zähler und senden später erneut); `/stats` 10 Anfragen mit Zugangsdaten pro
  Minute, darüber `429`. Weil sich der Stand nur zählend abfragen lässt, zählen auch erfolgreiche Anmeldungen.
- Höchstens 5000 neue Installationen pro UTC-Tag, darüber werden Pings unbekannter Installationen still
  verworfen (`204`). Schlägt diese Prüfung fehl (etwa weil `daily_new` fehlt), wird angenommen.
- Auf jeder Antwort: `Strict-Transport-Security: max-age=31536000`, `X-Frame-Options: DENY`,
  `Content-Security-Policy` mit `frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: no-referrer` (nur dieser Worker, nicht zonenweit).

## Statistik ansehen

`https://knips.velno.ai/stats` — Benutzer `knips`, Passwort = Secret `STATS_PASSWORD` (beim Betreiber
hinterlegt). Zeigt aktive Installationen (heute, 7, 30 Tage), neue pro Tag, Aufteilung nach Plattform,
Version, Betriebssystem, Land und Sprache sowie die Funktionen der letzten 30 Tage.
`?channel=dev` zeigt Entwickler-Builds statt Release.

## Deploy

Eingerichtet über die Cloudflare-API; `wrangler.toml` hält dieselbe Konfiguration fest. Wrangler ist in
`package.json` versionsgenau festgelegt (`package-lock.json`); `npx wrangler` nimmt nach `npm ci` diese
Fassung aus `node_modules`.

```
cd telemetry
npm ci
npx wrangler d1 execute knips-telemetry --remote --file schema.sql   # beim ersten Mal und nach Schema-Änderungen
npx wrangler secret put SALT                                          # nur beim ersten Mal
npx wrangler secret put STATS_PASSWORD                                # nur beim ersten Mal
npx wrangler deploy
```

`schema.sql` legt nur an, was fehlt (`IF NOT EXISTS`), und lässt sich deshalb jederzeit erneut einspielen.
Das Salz beim Neu-Einrichten nicht neu würfeln (beim Betreiber hinterlegt), sonst zählt jede Installation
ab dann als neu. Die `namespace_id` der Ratenbegrenzung ist frei gewählt und muss im Cloudflare-Konto
eindeutig sein.

Lokal testen: `.dev.vars` mit `SALT=…` und `STATS_PASSWORD=…` anlegen, Schema mit `--local` statt
`--remote` einspielen, dann `npx wrangler dev --local` (die Ratenbegrenzung läuft dort simuliert).
`npm run check` bündelt wie beim Deploy, ohne hochzuladen (`wrangler deploy --dry-run`).

Cron-Trigger brauchen eine workers.dev-Subdomain im Konto, für diesen Worker selbst ist workers.dev aber
abgeschaltet. Einstellungen der Zone außerhalb dieses Ordners führt der Betreiber.
