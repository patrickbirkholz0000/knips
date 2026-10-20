# Knips — Design in der Markensprache der App-Familie

Knips gehört zu einer kleinen App-Familie mit gemeinsamer Markensprache.
Diese Datei beschreibt sie für Knips. Sie gilt für beide Fassungen: macOS (`Sources/Knips`) und Windows
(`windows/src`). Beide sehen gleich aus. Werte stehen in genau zwei Dateien, sonst nirgends:

- macOS: `Sources/Knips/UI/Brand.swift` (`Brand.canvas`, `Brand.accent`, `Brand.font(…)`, `Brand.mono(…)` …)
- Windows: `windows/src/shared/tokens.css` (`--k-canvas`, `--k-accent`, `--k-font`, `--k-mono` …)

Keine Farbe, Schrift oder Ecke direkt im Code einer Ansicht — immer über diese Tokens.

## Grundsätze

1. **Tinte auf Papier.** Helle, ruhige Flächen, schwarze Schrift, weiße Karten mit feiner Linie.
2. **Ein Akzent.** Königsblau ist die einzige Akzentfarbe: Schalter, Auswahl, aktives Werkzeug, Fortschritt,
   Fokusrahmen, Auswahlrahmen beim Aufnehmen. Kein zweites Blau, kein Systemblau (`#007AFF`), keine Bunt-Icons.
3. **Rot heißt „es nimmt auf“.** Aufnahme-Rot nur, während ein Video läuft (Punkt, Zeit, Rahmen, Countdown)
   und für fehlende Schritte im Bereit-Check. Löschen ist kein Rot-Knopf, sondern ein Text-/Sekundärknopf.
4. **Grün heißt „erledigt“.** Nur Häkchen im Bereit-Check, „Erlaubt“, „Kopiert“.
5. **Dunkel schwebt.** Was über anderen Apps schwebt, ist immer dunkel: Menü-Panel, Karten-Knöpfe,
   Aufnahme-Leiste, Countdown, Scroll-Leiste, Hinweise (HUD), Größenanzeige im Overlay. Fenster folgen
   Hell/Dunkel.
6. **Zahlen in Mono.** Zeiten (0:08), Größen (1280 × 720), Datum/Uhrzeit in Listen, Kürzel (⇧⌘4), Prozent,
   Dateigrößen und die kleinen Überschriften in Versalien stehen in JetBrains Mono.
7. **Ton:** per du, kurz, Verben statt Technik. Fachwort in Klammern hinter dem verständlichen Wort:
   „Bildschirm aufnehmen (Bildschirmaufnahme-Freigabe)“. Keine Ausrufezeichen.

## Farben

| Token | Hell | Dunkel | Wofür |
|---|---|---|---|
| canvas (Papier) | `#F4F5F7` | `#101114` | Fensterfläche |
| fill | `#ECEEF2` | `#22242A` | Spuren, Chips, Hover, Segment-Hintergrund |
| surface | `#FFFFFF` | `#18191D` | Karten |
| surfaceRaised | `#F8F9FB` | `#1E1F24` | Kachel in einer Karte |
| line / lineStrong | `#E2E4E9` / `#D5D7DE` | `#2A2C32` / `#383A42` | Linien, Feldränder |
| ink (Tinte) | `#15161A` | `#ECEEF2` | Text, Primärknopf |
| inkMuted | `#4A4D55` | `#C3C6CE` | Icons, zweite Textebene |
| inkSoft (Bleistift) | `#6C6F78` | `#979BA5` | Beschreibungen, Meta |
| accent (Königsblau) | `#2D46D2` | `#8B98FF` | einziger Akzent |
| record | `#E8523F` | `#FF7A66` | nur Aufnahme |
| success | `#1F8A5B` | `#4CC58E` | nur „erledigt“ |
| Seitenleiste (immer dunkel) | `#1B1C20`, gehoben `#2C2D33`, Text `#ECEEF2`, leise `#9A9EA8` | | |
| Dunkle Schwebeflächen | `#141518`, gehoben `#24262C`, Hover `#2E3037`, Linie weiß 8 %, Akzent `#9AA6FF` | | |

Primärknopf auf hellen Flächen: Tinte mit weißer Schrift (dunkel: Papier mit Tinte). Auf dunklen
Schwebeflächen: Papier `#F4F5F7` mit Tinte.

Zensurbalken im Bild bleiben Inhalt, nicht Oberfläche: Standard Graphit (wie bisher), Stile wie bisher.

## Schrift

- **Outfit** (OFL, `Resources/Fonts/Outfit.ttf`, Windows `public/fonts/outfit.woff2`): Text normal (400),
  Knöpfe/Zeilentitel mittel (500), Titel halbfett (600). Seitentitel 28, Abschnittstitel 17, Zeilentitel 14,
  Text 13–14, Beschreibung 12.5–13 (inkSoft).
- **JetBrains Mono** (OFL): Zahlen, Zeiten, Größen, Kürzel; **kleine Überschriften in Versalien**
  (11, Sperrung 0.08 em, inkSoft bzw. in der Seitenleiste `#9A9EA8`), z. B. `AUFNAHME`, `ZULETZT`, `WILLKOMMEN`.
- Lizenztexte liegen neben den Schriften (`OFL-*.txt`); „Über Knips“ nennt sie.

## Formen und Abstände

Radien: Felder/Knöpfe 10, Karten 14, Panels/Menü 16, Dialoge 22, Pillen rund. Karten: weiß, 1 px `line`,
Schatten kaum (`0 1 2 rgba(21,22,26,.04)`). Zeilen in Karten 14–16 hoch gepolstert, Trennlinie `line`
eingerückt. Seitenränder 28–32. Fokusrahmen: 3 px `accentSoft` um Felder; Tastaturfokus sichtbar.

## Logo und Wortmarke

**Zeichen:** Vier Auswahl-Ecken (die Auswahl) und ein Balken darin (die Zensur). Einheiten 0..100:
Ecken eines Quadrats 22..78, Schenkel 17 lang, Strichstärke 9, runde Enden; Balken waagerecht
x 33..67, y 45,5..54,5 (Höhe 9), runde Enden. App-Icon: Fläche Tinte (oben `#24262E`, unten `#111216`,
macOS-Squircle bzw. Windows abgerundet), Ecken Papier `#F4F5F7`, Balken Königsblau `#7B88FF`.
Menüleiste (macOS, Template) und Taskleiste (Windows): Ecken + Balken
einfarbig; **während eines Videos** wird der Balken zu einem gefüllten Punkt (Aufnahme-Zustand, unter
Windows rot).

**Wortmarke:** „knips“ in Kleinbuchstaben, Outfit halbfett. Der i-Punkt ist die Aufnahmelampe:
Königsblau in Ruhe, Rot und pulsierend, während ein Video läuft. Steht oben in der
Seitenleiste der Einstellungen und im Menü-Panel.

## Fenster und Flächen

**Einstellungen**: Seitenleiste immer dunkel, volle Höhe, 216 breit:
oben Zeichen + Wortmarke, darunter Gruppen mit Mono-Überschrift (`START`, `AUFNAHME`, `BEARBEITEN`, `APP`),
Einträge 34 hoch mit Icon, gewählter Eintrag gehoben (`#2C2D33`) mit Pfeil rechts; unten Status
(„Bereit“ mit grünem Punkt bzw. „2 Schritte offen“ mit rotem Punkt) und Version in Mono. Inhalt auf Papier:
Seitentitel 28 halbfett + Satz darunter (inkSoft), Abschnitte mit Titel, weiße Karten mit Zeilen
(Titel, Beschreibung, Bedienelement rechts). Bedienelemente: Schalter Königsblau, Segment-Schalter
(fill-Spur, weißer Daumen), Auswahlfelder 40 hoch mit Linie, Primärknopf Tinte, Sekundärknopf weiß mit
Linie, Tastenkappen für Kürzel (weiße Kappe, Linie, Mono).

Neue erste Seite **Start** („So geht's“): deine Kürzel als Tastenkappen (Bereich, Bildschirm,
Fenster, Video), drei Schritte (1 Aufnehmen → 2 Zensieren → 3 Teilen) in hellen Kacheln mit
Königsblau-Nummern, darunter **Bereit-Check** als Karte: Bildschirmaufnahme (Freigabe), Mikrofon (optional,
nur für Videos mit Ton), Kürzel aktiv (bzw. Druck-Taste unter Windows), Ablageordner erreichbar — je mit
grünem Häkchen oder rotem Punkt + Knopf („Erlauben“, „Öffnen“). Fehlt etwas, zeigt die Seitenleiste die
Zahl offener Schritte. Das bisherige Freigabe-Fenster bleibt für den ersten Start, im selben Stil.
Gruppen der Seitenleiste: START (Start) · AUFNAHME (Allgemein, Tastaturkürzel, Bildschirmaufnahme) ·
BEARBEITEN (Zensur, Export) · APP (Ablage, Datenschutz, Über Knips). Neu unter Allgemein bzw. App:
**Darstellung: System / Hell / Dunkel** (Segment-Schalter; gilt für alle Fenster).

**Menü-Panel** (Menüleiste bzw. Taskleiste): immer dunkel, Radius 16. Kopf: Zeichen + Wortmarke links,
Status rechts (z. B. Punkt „Bereit“). Hauptaktion „Bereich aufnehmen“ als große gehobene Zeile mit Kürzel
in Mono-Tastenkappen. Darunter Raster der weiteren Aktionen (Icon, Name, Kürzel in Mono, leise). Abschnitt
`ZULETZT` (Mono-Versalien) mit Vorschaubildern (Radius 8), „Alle anzeigen →“. Fuß: Einstellungen, Ordner,
Beenden als leise Textknöpfe. Hover: `#2E3037`.

**Karten** (nach der Aufnahme, unten links): Vorschaubild mit Radius 12 und dunklem Rand; beim Darüberfahren
dunkler Schleier, Hauptaktionen als Pillen: „Kopieren“ (Papier-Knopf = primär) und „Bearbeiten“/„Öffnen“
(dunkel gehoben); kleine runde dunkle Knöpfe in den Ecken (Schließen, Anpinnen, Ordner, Text, Löschen).
„Kopiert“ als kurze grüne Bestätigung.

**Editor (Bild):** Fensterfläche Papier (dunkel: `#101114`), Bild in der Mitte auf `fill`-Fläche mit leichtem
Schatten. Werkzeugleiste oben als eine Gruppe (weiße Leiste, Radius 12, Linie): Werkzeug-Knöpfe 32×32,
aktives Werkzeug Königsblau-Fläche (`accentSoft`) mit Königsblau-Icon; Zensur-Werkzeug und Auto-Zensur
deutlich. Rechts: „Text kopieren“, „Kopieren“ (sekundär), „Fertig“ (primär Tinte). Eigenschaften
(Farbe, Stärke, Zensur-Stil) als kleine Leiste/Popover im selben Stil. Unten links Zoom in Mono
(„100 %“), Maße in Mono. Farbauswahl für Anmerkungen bleibt bunt (Inhalt).

**Video-Editor:** wie Bild-Editor; Zeitleiste als weiße Karte, Zensurbereiche als Königsblau-Spannen,
Abspielkopf Tinte, Zeiten in Mono, Kürzen-Griffe Tinte. Export-Knöpfe rechts oben.

**Verlauf:** Fenster wie Einstellungen ohne Seitenleiste oder mit Kopfzeile: Titel „Verlauf“, Satz mit Anzahl,
Filter als Segment-Schalter (Alle / Screenshots / Videos / GIFs), Suchfeld optional. Raster aus Karten
(Vorschau oben auf `fill`, darunter Name, Meta in Mono: `20. Okt · 18:03 · 500 × 500`). Hover: Linie
Königsblau, Aktionen als kleine Knöpfe.

**Dialoge** (Zustimmung Statistik, Link-Rückfrage, „Text kopieren?“, Freigabe, Druck-Taste übernehmen):
als Karte im Stil eines Einrichtungs-Assistenten: weiße Karte (dunkel: surface), Radius 22, Mono-Überschrift in
Versalien oben (`STATISTIK`, `LINK VON AUSSEN`), Titel 22 halbfett, Text, Punkte mit Icon-Kacheln
(`accentSoft`-Kachel, Königsblau-Icon), Knöpfe rechts: Sekundär, Primär Tinte. Schutzzeit sichtbar
(Primärknopf erst nach 0,6 s aktiv, leiser Fortschritt).

**Aufnahme-Leiste** (Video läuft): dunkle Pille: roter pulsierender Punkt, Zeit in
Mono, ggf. Mikrofon-Pegel als kleine Balken (Königsblau hell), Pause, Stopp (Papier-Knopf). **Countdown:**
dunkle runde Fläche, große Mono-Ziffer. **Scroll-Leiste:** dunkle Pille mit Höhe in Mono („12 480 px“),
„Fertig“ (Papier) und „Abbrechen“. **HUD/Hinweise:** dunkle Pille, Icon, ein Satz.

**Auswahl-Overlay:** abgedunkelt wie bisher, Auswahlrahmen 1,5 pt Königsblau hell `#9AA6FF` mit Eckgriffen,
Größe als dunkle Pille in Mono („640 × 480“) nahe der Ecke, Hinweiszeile unten als dunkle Pille
(„Leertaste Fenster · ⏎ Bildschirm · Esc Abbrechen“ mit Mono-Tastenkappen). Fenstermodus: Fenster mit
Königsblau-Fläche 12 % und Rand.

**Angepinnte Bilder:** randlos mit Radius 10 und Schatten; Steuerung beim Darüberfahren als kleine dunkle
Pille.

## Hell und Dunkel

Einstellung `appearance` = `system` | `light` | `dark` (Standard system). macOS: `NSApp.appearance`
(nil / `.aqua` / `.darkAqua`), alle Fenster folgen sofort. Windows: `<html data-theme>` in jedem Fenster,
bei `system` nach `prefers-color-scheme`; Änderung per Ereignis an alle Fenster. Immer dunkel bleiben:
Seitenleiste, Menü-Panel, Pillen, Overlay-Elemente, Karten-Knöpfe.

## Prüfen

Jede Ansicht hell und dunkel per Selbsttest fotografieren (macOS `ui`, `settings`, `menu`, `history`,
`links`, Editor über `live` nur nach Absprache; Windows `ui` in der CI und `node scripts/shot.mjs` im Browser)
und gegen diese Datei halten. Kein Text darf abgeschnitten sein, nichts überlappen, Kontrast in beiden Modi lesbar.
