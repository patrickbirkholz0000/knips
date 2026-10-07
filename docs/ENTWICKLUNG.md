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

- Sichtbare Dateien: `~/Pictures/Knips` (einstellbar). Dort liegt immer die **gerenderte** Fassung,
  also bereits zensiert. Herausziehen/Kopieren gibt nie das Original weiter.
- Originale + Bearbeitungsstand (JSON): `~/Library/Application Support/Knips/items/<uuid>/`.
  Nur damit lässt sich eine Zensur wieder aufheben. Wird nach 30 Tagen aufgeräumt.

## Bedienung

Kürzel (änderbar): ⌥⇧4 Bereich · ⌥⇧2 Fenster · ⌥⇧3 Vollbild · ⌥⇧5 Aufnahme starten/stoppen.
Im Overlay: Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch, ⇧ = Quadrat.
URL-Befehle: `knips://area|window|fullscreen|record|pin|settings`.

## Stand 08.10.2026

Gebaut und geprüft (Selbsttests + Live-Fenster + End-to-End über URL-Befehle): Aufnahme, Overlay,
Karten, Bild-Editor, Auto-Zensur, Bildschirmaufnahme, Video-Editor mit Zensur, MP4/GIF-Export.
Nicht automatisch prüfbar, muss am Gerät getestet werden: Maus-Hover auf den Karten, Ziehen aus den
Karten in andere Apps, das interaktive Auswahl-Overlay, Mikrofon-Aufnahme.
Offen/Ideen: Verlauf-Fenster, Hintergrund/Rahmen („Beautify“), Zensurfelder, die bewegtem Inhalt
folgen (Vision-Tracking), OCR-Text kopieren, Scroll-Screenshots.
