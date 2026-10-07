# Knips — Screenshot- und Bildschirmaufnahme-App für macOS

Screenshot- und Bildschirmaufnahme-App als native Swift-Menüleisten-App, macOS 14+.


## Bauen

```
scripts/install.sh          # baut, ersetzt /Applications/Knips.app, startet sie
scripts/build.sh            # nur build/Knips.app (Release, signiert)
swift build                 # nur kompilieren (Debug)
swift scripts/make-icon.swift   # Icon neu erzeugen
```

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
| `live` | Bild- und Video-Editor als echtes Fenster, 1 pt in der Bildschirmecke, per SCK fotografiert |
| `settings [bereich,…]` | Einstellungsfenster (Stil Systemeinstellungen) je Bereich, inkl. Kürzel-Eingabe |
| `output` | Ausgabe 1× + PNG/JPEG, Original in voller Auflösung, Speichern aus dem Editor |
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
Zensur: Standard „Balken“, Editor startet mit dem Zensur-Werkzeug. Auto-Zensur-Knopf ist standardmäßig aus.
Im Overlay: Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch, ⇧ = Quadrat.
URL-Befehle: `knips://area|window|fullscreen|record|pin|settings`.

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

## Stand 08.10.2026

Gebaut und geprüft (Selbsttests + Live-Fenster + End-to-End über URL-Befehle): Aufnahme, Overlay,
Karten, Bild-Editor, Auto-Zensur, Bildschirmaufnahme, Video-Editor mit Zensur, MP4/GIF-Export.
Nicht automatisch prüfbar, muss am Gerät getestet werden: Maus-Hover auf den Karten, Ziehen aus den
Karten in andere Apps, das interaktive Auswahl-Overlay, Mikrofon-Aufnahme.
Offen/Ideen: Verlauf-Fenster, Hintergrund/Rahmen („Beautify“), Zensurfelder, die bewegtem Inhalt
folgen (Vision-Tracking), OCR-Text kopieren, Scroll-Screenshots.
