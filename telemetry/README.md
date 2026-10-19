# Knips-Telemetrie

Ein kleiner Cloudflare Worker unter `https://knips.velno.ai`. Er nimmt anonyme Nutzungszähler der
Knips-Apps (macOS und Windows) an — aber nur, wenn man beim ersten Start oder später in den
Einstellungen zugestimmt hat. Ohne Zustimmung sendet Knips nichts.

## Was gesendet wird

Höchstens einmal am Tag ein `POST /v1/ping` mit:

- Zählern, wie oft Funktionen genutzt wurden, z. B. „3 Bereichs-Screenshots, 2× Editor geöffnet“.
  Die erlaubten Namen stehen in `src/index.js` (`EVENTS`); alles andere verwirft der Server.
- App-Version und Build, Kanal (`release` oder `dev`), Plattform, Betriebssystem-Version,
  Prozessorarchitektur und Sprache (zwei Buchstaben).
- einer zufälligen Installations-ID (UUID). Sie entsteht beim Zustimmen und wird beim Widerruf gelöscht.

## Was nie gesendet oder gespeichert wird

- keine Bilder, Videos, Texte, Dateinamen, Fenstertitel, App-Namen, Bildschirmgrößen oder Zeitangaben
- keine IP-Adresse und kein User-Agent. Cloudflare sieht die IP beim Transport wie jeder Webserver;
  der Worker speichert sie nicht, und Workers Logs sind abgeschaltet.
- die Installations-ID nicht im Klartext: gespeichert wird nur `sha256(ID + geheimes Salz)`, gekürzt
  auf 32 Zeichen. Das Land kommt als zweistelliger Code von Cloudflare (`request.cf.country`).

## Speicherung

D1-Datenbank `knips-telemetry` (Westeuropa), Schema in `schema.sql`: je Installation und UTC-Tag eine
Zeile in `daily` (dazu die Serverzeit des letzten Pings an diesem Tag), die Zähler in `daily_events`. Jeden Tag um 03:30 UTC löscht ein Cron-Trigger alles,
was älter als 400 Tage ist.

Schutz gegen Unsinn: Body höchstens 4 KB (sonst `413`), kein JSON → `400`. Unbekannte App, falsche
UUID oder unbekannte Plattform werden still verworfen (`204`), Zähler auf 0–10.000 begrenzt, mehr als
48 Pings pro Installation und Tag ignoriert.

## Statistik ansehen

`https://knips.velno.ai/stats` — Benutzer `knips`, Passwort = Secret `STATS_PASSWORD`.
Zeigt aktive Installationen (heute, 7, 30 Tage), neue pro Tag, Aufteilung nach Plattform, Version,
Betriebssystem, Land und Sprache sowie die Funktionen der letzten 30 Tage.
`?channel=dev` zeigt Entwickler-Builds statt Release.

## Deploy

Eingerichtet über die Cloudflare-API; `wrangler.toml` hält dieselbe Konfiguration fest.

```
cd telemetry
npx wrangler d1 execute knips-telemetry --remote --file schema.sql   # nur beim ersten Mal
npx wrangler secret put SALT
npx wrangler secret put STATS_PASSWORD
npx wrangler deploy
```

Das Salz beim Neu-Einrichten nicht neu würfeln, sonst zählt
jede Installation ab dann als neu.

Lokal testen: `npx wrangler dev` mit einer `.dev.vars` (`SALT=…`, `STATS_PASSWORD=…`), Schema vorher mit
`--local` statt `--remote` einspielen.

Cron-Trigger brauchen eine workers.dev-Subdomain im Konto, für diesen Worker selbst ist workers.dev
abgeschaltet. Einstellungen der Zone außerhalb dieses Ordners führt der Betreiber.
