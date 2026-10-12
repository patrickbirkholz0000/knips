# Knips — Screenshot- und Bildschirmaufnahme-App für macOS

Screenshot- und Bildschirmaufnahme-App als native Swift-Menüleisten-App, macOS 14+.

**Windows-Fassung** (Tauri 2 + Rust + React, 1:1 nach dieser App) liegt in `windows/` — eigene Anleitung
`windows/ENTWICKLUNG.md`; geprüft über die GitHub-CI `.github/workflows/windows.yml` auf echtem Windows.

## Bauen

```
scripts/install.sh          # baut, ersetzt /Applications/Knips.app, startet sie
scripts/build.sh            # nur build/Knips.app (Release, signiert)
swift build                 # nur kompilieren (Debug)
swift scripts/make-icon.swift   # Icon neu erzeugen
```

**Weitergeben:** `scripts/package.sh` baut mit `RELEASE=1`: ohne Selbsttests/Test-Befehle (`#if KNIPS_DEV`),
ohne Debug-Symbole, ohne Quelldatei-Namen (`onMainActor` statt `MainActor.assumeIsolated`, kein `fatalError`/`try!`).
Eigene Builds (`build.sh`, `install.sh`) enthalten den Entwickler-Code weiterhin. Paket: → `build/Knips-<version>-<build>.dmg` (Universal, mit „Zuerst lesen.txt“,
ohne Aufnahmen/Einstellungen — die liegen nur in `~/Pictures/Knips`, `~/Library/Application Support/Knips`
und den Defaults). Mit „Apple Development“ signiert lehnt Gatekeeper auf fremden Macs ab; Empfänger gibt
Knips einmal unter Datenschutz & Sicherheit frei. Ohne Warnung: Developer-ID-Zertifikat + Notarisierung,
siehe Kopf von `scripts/package.sh` (Hardened Runtime, `Resources/Knips.entitlements`).

**Signatur:** `build.sh` nimmt die jüngste gültige „Apple Development“-Identität (ab 08.10.2026
gültig, weil das Apple-Zwischenzertifikat WWDR G3 im Anmelde-Schlüsselbund liegt). Damit bleibt die
Freigabe „Bildschirm- & Systemaudioaufnahme“ über Updates hinweg erhalten. Ad hoc signiert müsste sie
nach jedem Build neu erteilt werden.

## Prüfen ohne den Bildschirm zu übernehmen

`build/Knips.app/Contents/MacOS/Knips --selftest <test> <ordner>` (läuft isoliert in `<ordner>/sandbox`):

| Test | prüft |
|---|---|
| `render` | Renderer: alle Werkzeuge, Zensurstile, Zuschnitt → PNG |
| `detect` | Auto-Zensur (Vision + Muster) am Testbild |
| `ui` / `selection` | Karten, Einstellungen, Auswahl-Overlay offscreen |
| `cards` | Klicks auf eine Karte als echte Mausereignisse: Fläche öffnet, jeder Knopf nur seine Aktion; Raster mit mehreren Spalten trifft die richtige Karte |
| `live` | Bild- und Video-Editor als echtes Fenster, 1 pt in der Bildschirmecke, per SCK fotografiert |
| `settings [bereich,…]` | Einstellungsfenster (Stil Systemeinstellungen) je Bereich, inkl. Kürzel-Eingabe und Eintippen der Anzeigedauer |
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
**Achtung:** `knips://fullscreen` legt einen echten Screenshot in die Zwischenablage.

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
URL-Befehle: `knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings`.
Test-Instanz: `KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`, Befehle dann über
`swiftc -O scripts/test-command.swift -o .build/knips-test-command && .build/knips-test-command <befehl>`
(URL-Aufrufe landen sonst bei der installierten App). In der Sandbox fasst Knips die Zwischenablage nie an.
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

Menü-Panel (`UI/MenuPanel.swift`) und Einstellungen (`App/SettingsWindow.swift`) folgen einem eigenen
Stil: dunkles Panel mit Raster; Einstellungen mit dunkler Liste links (Pfeil am ausgewählten
Eintrag), heller Fläche, weißen Karten, schwarzen Knöpfen (`Theme`). Verlauf-Fenster im selben Stil.

## Stand 08.10.2026

Gebaut und geprüft (Selbsttests + Live-Fenster + End-to-End über URL-Befehle): Aufnahme, Overlay,
Karten, Bild-Editor, Auto-Zensur, Bildschirmaufnahme, Video-Editor mit Zensur, MP4/GIF-Export.
Nicht automatisch prüfbar, muss am Gerät getestet werden: Maus-Hover auf den Karten (Klicks prüft `cards`), Ziehen aus den
Karten in andere Apps, das interaktive Auswahl-Overlay, Mikrofon-Aufnahme.
Seitdem dazu: Editor-Zoom, schlaue Zensurbalken (Klick auf Text), Text kopieren/erfassen, Letzter Bereich,
Scroll-Screenshots, Verlauf, Rahmen, Videos 1×/HEVC/Klicks, mitlaufende Video-Balken, kleinere GIFs.
Offen: Developer-ID-Signatur + Notarisierung (nur nötig, wenn andere Knips bekommen sollen).
