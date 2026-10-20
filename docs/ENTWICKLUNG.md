# Knips — Screenshot- und Bildschirmaufnahme-App für macOS

Screenshot- und Bildschirmaufnahme-App als native Swift-Menüleisten-App, macOS 14+.
Freie Software (GPL-3.0-or-later), Repo `github.com/patrickbirkholz0000/knips`. Für Nutzer: `README.md`,
für Beiträge: `CONTRIBUTING.md`, für Releases: `RELEASING.md`.

**Windows-Fassung** (Tauri 2 + Rust + React, 1:1 nach dieser App) liegt in `windows/` — eigene Anleitung
`windows/ENTWICKLUNG.md`; geprüft über die GitHub-CI `.github/workflows/windows.yml` auf echtem Windows.

## Bauen

```
scripts/install.sh          # baut, ersetzt /Applications/Knips.app, startet sie
scripts/build.sh            # nur build/Knips.app (Release, signiert)
swift build                 # nur kompilieren (Debug)
swift scripts/make-icon.swift   # Icon neu erzeugen
```

**Weitergeben:** siehe `RELEASING.md`. Release-Builds baut `scripts/package.sh` (aufgerufen von
`scripts/release.sh`) mit `RELEASE=1`: Developer-ID-signiert (Hardened Runtime, `Resources/Knips.entitlements`),
von Apple notarisiert, ohne Selbsttests/Test-Befehle (`#if KNIPS_DEV`), ohne Debug-Symbole, ohne Quelldatei-Namen
(`onMainActor` statt `MainActor.assumeIsolated`, kein `fatalError`/`try!`). Eigene Builds (`build.sh`, `install.sh`)
enthalten den Entwickler-Code weiterhin. Paket: → `build/Knips-<version>-<build>.dmg` (Universal, mit „Zuerst lesen.txt“,
ohne Aufnahmen/Einstellungen — die liegen nur in `~/Pictures/Knips`, `~/Library/Application Support/Knips`
und den Defaults).

**Signatur:** `build.sh` nimmt die jüngste gültige „Apple Development“-Identität (dafür muss Apples
Zwischenzertifikat WWDR G3 im Schlüsselbund liegen). Damit bleibt die Freigabe „Bildschirm- &
Systemaudioaufnahme“ über Updates hinweg erhalten. Ad hoc signiert müsste sie nach jedem Build neu erteilt werden.

## Prüfen ohne den Bildschirm zu übernehmen

`build/Knips.app/Contents/MacOS/Knips --selftest <test> <ordner>` (läuft isoliert in `<ordner>/sandbox`):

| Test | prüft |
|---|---|
| `render` | Renderer: alle Werkzeuge, Zensurstile, Zuschnitt → PNG |
| `detect` | Auto-Zensur (Vision + Muster) am Testbild; Pflicht: erfundener Stripe-Key und E-Mail in 1× und 2× |
| `ui` / `selection` | Karten, Einstellungen, Auswahl-Overlay offscreen |
| `cards` | Klicks auf eine Karte als echte Mausereignisse: Fläche öffnet, jeder Knopf nur seine Aktion; Raster mit mehreren Spalten trifft die richtige Karte |
| `live` | Bild- und Video-Editor als echtes Fenster, 1 pt in der Bildschirmecke, per SCK fotografiert |
| `settings [bereich,…]` | Einstellungsfenster (Stil Systemeinstellungen) je Bereich, inkl. Kürzel-Eingabe und Eintippen der Anzeigedauer, Datenschutz mit Statistik an/aus, Zustimmungsdialog (`zustimmung.png`) |
| `links` | Rückfrage vor knips://fullscreen/last/record: ohne Einstellung erst Rückfrage, Esc/Schließen/Abbrechen = nichts, ⏎ erst nach der Schutzzeit, „Nicht mehr fragen“, Stoppen und eigener Test-Kanal direkt; mit Einstellung direkt. Aufnahmen sind durch eine Liste ersetzt, nimmt nie auf. Bilder: `link-rueckfrage-*.png`, `link-einstellung-allgemein.png` |
| `telemetry [live]` | Nutzungsstatistik: Sperren (Selbsttest/Sandbox/CI/Entwickler-Build), Payload (genau die Vertragsfelder, Allowlist, Deckel), Zustimmung → Zählen → Senden an lokalen Server (127.0.0.1) → Abmelden; Zähler bleiben nach Fehlern. `live` schickt zusätzlich einen echten Ping (nur mit `KNIPS_TELEMETRY=1`, Kanal `dev`) |
| `output` | Ausgabe 1× + PNG/JPEG, Rahmen, Speichern aus dem Editor, „Text kopieren“ ohne Zensiertes |
| `track` | Mitlaufender Zensurbalken in scrollendem Video (Texterkennung prüft jeden Zeitpunkt) |
| `stitch` | Scroll-Screenshot: Ausschnitte → exakt das Originalbild (Pixelvergleich) |
| `menu` / `history` | Menü-Panel und Verlauf-Fenster |
| `perf` / `record-bench` | Zeiten (Overlay, Speichern, Texterkennung) und Video-Varianten |
| `video` | Video-Zensur mit Zeitbereich, Kürzen, MP4- und GIF-Export, Auto-Zensur im Video |
| `capture` / `record 3` | echte Aufnahme — gibt nur Maße/Dauer aus, speichert keine Inhalte |

Aus dem Terminal gestartet erbt das Binary dessen Bildschirm-Freigabe. End-to-End mit laufender App:
`KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`, dann `open knips://debug-sample`,
`open knips://fullscreen`, `open knips://debug-snapshot` (fotografiert nur eigene Fenster).
**Achtung:** `knips://fullscreen` legt einen echten Screenshot in die Zwischenablage (über einen Link erst nach der Rückfrage).

Testbild-Geheimnisse sind erfunden. Den Stripe-Schlüssel (`SelfTest.sampleStripeKey`) nie als ein Literal
`sk_` + `live_…` schreiben, sondern zusammengesetzt — sonst schlagen Secret-Scanner (GitHub-Push-Schutz) an.

SwiftUI rendert nicht über `cacheDisplay` in Fenstern — für Editor-Prüfungen `live` nehmen.
Seit macOS 14 clippen NSViews nicht mehr: eigene `draw(_:)` immer auf `bounds` begrenzen
(`clipsToBounds = true`), sonst übermalt die Fläche Nachbar-Views.

## Ablage

Ausgabe standardmäßig in **Bildschirmgröße (1×)** als PNG (Einstellungen → Export, auch JPEG / Retina 2×).
Gemessen an echten 4K-Screenshots: Retina-PNG 2–6,7 MB → 1×-PNG 0,7–2,2 MB → 1×-JPEG 0,24–0,63 MB.
Das Original in `items/<uuid>/original.png` bleibt immer in voller Auflösung; der Editor arbeitet darauf
und schreibt beim Speichern wieder die verkleinerte Fassung (`AppSettings.outputPromise`).

- Sichtbare Dateien: `~/Pictures/Knips` (einstellbar). Dort liegt immer die **gerenderte** Fassung,
  also bereits zensiert. Herausziehen/Kopieren gibt nie das Original weiter.
- Originale + Bearbeitungsstand (JSON): `~/Library/Application Support/Knips/items/<uuid>/`.
  Nur damit lässt sich eine Zensur wieder aufheben. Wird nach 30 Tagen aufgeräumt.

## Nutzungsstatistik (Opt-in)

Vertrag v1 (gleich für Windows und den Worker `knips.velno.ai`): `Support/Telemetry.swift`. Beim ersten Start fragt
`ConsentWindowController` — erst nach Freigabe-Fenster und Kürzel-Rückfrage, nie gleichzeitig; Schließen ohne Wahl = Nein,
beim nächsten Start erneut. Umschalten in Einstellungen → Datenschutz. Gezählt wird nur über `Telemetry.count(.ereignis)`
an den Aufrufstellen (24 erlaubte Namen in `TelemetryEvent`; `export_png/jpeg` = Speichern im Bild-Editor,
`export_mp4` = Video mit Zensur/Kürzung gespeichert, `copy_image` nur bei Bildern, `drag_out` = Ziehen beginnt), gesendet höchstens alle 24 h (Prüfung 30 s nach Start, dann
alle 6 h), 10 s Zeitlimit; Fehler → Zähler bleiben. Zustand in den UserDefaults: `telemetryConsent`, `telemetryInstallID`,
`telemetryCounts`, `telemetryLastSent` — in der Test-Sandbox in der Domäne `de.birkgroup.knips.sandbox`. Nie gefragt,
gezählt oder gesendet in Selbsttests, Sandbox (`KNIPS_TEST_DIR`) und CI. Eigene Builds (`KNIPS_DEV`) senden nur mit
`KNIPS_TELEMETRY=1` (Kanal `dev`); `KNIPS_TELEMETRY_URL` ersetzt den Endpunkt.

## Bedienung

Kürzel wie macOS (änderbar): ⌘⇧4 Bereich · ⌘⇧3 Vollbild · ⌘⇧5 Aufnahme starten/stoppen · ⌘⇧2 Fenster.
Kollidieren sie mit eingeschalteten macOS-Kürzeln, fragt Knips einmal beim Start, ob es sie übernehmen darf
(`SystemShortcuts.takeOver`: schreibt `com.apple.symbolichotkeys`, lädt per `activateSettings -u` neu;
rückgängig in Einstellungen → Tastaturkurzbefehle).
Karten unten links: Klick irgendwo auf die Karte öffnet sie (Bild-/Video-Editor, GIF in der Standard-App), die Knöpfe
darauf haben Vorrang. Ausblenden nach frei wählbaren Sekunden (1–3600, `quickAccessAutoHide` + `quickAccessSeconds`,
alter Schlüssel `quickAccessAutoClose` wird beim Start übernommen); unter der Maus nie.
Ist die Spalte bis zur Bildschirmhöhe voll, stapeln sich neue Karten rechts daneben weiter (`QuickAccessController.grid`,
`cardOrigin`; 2048×1028-pt-Bildschirm: 6 hoch, 8 Spalten). Erst wenn auch die Breite voll ist, fällt die älteste weg.
Zensur: Standard „Balken“, Editor startet mit dem Zensur-Werkzeug. Auto-Zensur-Knopf ist standardmäßig aus.
Im Overlay: Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch, ⇧ = Quadrat.
URL-Befehle: `knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` (`App/LinkCommands.swift`).
Jede App und jede Webseite kann solche Links öffnen. Was sofort aufnimmt — `fullscreen`, `last`, `record` (nur Start) —
fragt deshalb erst nach: Fenster „Aufnahme per Link?“ (`LinkConfirmWindowController`, schwebend, Stil wie der
Zustimmungsdialog) nennt die Aktion; „Aufnehmen“ (⏎) wirkt erst nach 0,6 s Schutzzeit, „Abbrechen“/Esc/Schließen
verwirft; „Nicht mehr fragen“ gilt nur zusammen mit „Aufnehmen“. Höchstens eine Rückfrage zur Zeit, weitere Links
verfallen solange. Einstellungen → Allgemein → „Aufnahmen per Link ohne Rückfrage“ (`linkCaptureWithoutConfirm`,
Standard aus). Direkt laufen: Stoppen einer Aufnahme und alles, was nur Oberfläche öffnet (Overlay, Anpinnen, Menü,
Verlauf, Einstellungen). Kürzel und Menü-Panel rufen `CaptureCoordinator` direkt auf, ohne Rückfrage.
Test-Instanz: `KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`, Befehle dann über
`swiftc -O scripts/test-command.swift -o .build/knips-test-command && .build/knips-test-command <befehl>`
(URL-Aufrufe landen sonst bei der installierten App). Dieser Kanal gilt als intern (ohne Rückfrage);
`link:<befehl>` verhält sich wie ein Link von außen. In der Sandbox fasst Knips die Zwischenablage nie an.
Nie Befehle testen, die das Auswahl-Overlay öffnen — das erscheint auf dem Bildschirm des Nutzers.

## Tempo (gemessen 08.10.2026, M4, zwei 4K-Bildschirme)

- Overlay erscheint sofort als nicht-aktivierendes Panel; das Standbild (~150–260 ms) wird darunter
  aufgenommen. Knips-Fenster sind per Content-Filter ausgeschlossen, die Ziel-App bleibt aktiv.
- Nach dem Loslassen: 2 ms im Hauptthread. PNG-Kodierung, Schreiben, Vorschaubild laufen über
  `PNGPromise` im Hintergrund; die Zwischenablage liefert PNG/TIFF erst bei Anfrage.
  `CaptureStore.waitUntilWritten` vor Kopieren/Ziehen/Löschen/Öffnen.
- Texterkennung immer auf ≤ 2048 px (`SensitiveDetector.ocrMaxPixel`): 4K „genau“ dauerte auf einem
  textreichen Bildschirm 35 s, verkleinert 0,1–0,15 s bei gleicher Trefferzahl. Video: zusätzlich
  unveränderte Frames überspringen (`FrameSignature`).
- `--selftest perf` misst das alles (Bildschirmfoto nur im Speicher, gibt nur Zeiten aus).

## Oberfläche

Menü-Panel (`UI/MenuPanel.swift`): dunkles Panel mit Raster. Einstellungen (`App/SettingsWindow.swift`):
dunkle Liste links (Pfeil am ausgewählten Eintrag), helle Fläche, weiße Karten, schwarze Knöpfe (`Theme`).
Verlauf-Fenster, Zustimmungsdialog und Link-Rückfrage im selben Stil.

## Nicht automatisch prüfbar

Am Gerät testen: Maus-Hover auf den Karten (Klicks prüft `cards`), Ziehen aus den Karten in andere Apps,
das interaktive Auswahl-Overlay, Mikrofon-Aufnahme.
