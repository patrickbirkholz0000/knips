# Knips — Screenshot- und Bildschirmaufnahme-App für macOS

Screenshot- und Bildschirmaufnahme-App als native Swift-Menüleisten-App, macOS 14+.

## Bauen

```
scripts/build.sh            # → build/Knips.app (Release, signiert)
scripts/install.sh          # baut, ersetzt /Applications/Knips.app und startet sie
swift build                 # nur kompilieren
```

`build/Knips.app/Contents/MacOS/Knips --selftest <name> <ausgabeordner>` rendert Editor, Karten,
Overlay usw. offscreen in PNGs — so lässt sich die UI prüfen, ohne den Bildschirm zu übernehmen.

## Ablage

- Sichtbare Dateien: `~/Pictures/Knips` (einstellbar). Dort liegt immer die **gerenderte** Fassung,
  also bereits zensiert.
- Originale + Bearbeitungsstand (JSON): `~/Library/Application Support/Knips/items/<uuid>/`.
  Nur damit lässt sich eine Zensur wieder aufheben. Dieser Ordner wird nie geteilt.
