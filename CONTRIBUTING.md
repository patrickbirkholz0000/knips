# Mitmachen

Fehlerberichte, Ideen und Pull Requests sind willkommen. Für Fehler und Wünsche bitte ein Issue
anlegen, mit Plattform (macOS oder Windows), Version und den Schritten, die zum Fehler führen.
Sicherheitslücken nicht als Issue, sondern wie in [SECURITY.md](SECURITY.md) beschrieben melden.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `Sources/Knips/` | macOS-App in Swift (AppKit, SwiftUI, ScreenCaptureKit, Vision, AVFoundation) |
| `Resources/` | `Info.plist`, Icon, Entitlements, Anleitung im DMG |
| `scripts/` | Bauen, Installieren, DMG-Paket, Icon, Testbefehle |
| `windows/` | Windows-Fassung: Tauri 2, Rust, React + TypeScript |
| `telemetry/` | Server der freiwilligen Nutzungsstatistik (Cloudflare Worker) |
| `.github/workflows/` | CI für die Windows-Fassung |

Ausführlichere Entwicklernotizen stehen in [docs/ENTWICKLUNG.md](docs/ENTWICKLUNG.md) (macOS) und
[windows/ENTWICKLUNG.md](windows/ENTWICKLUNG.md) (Windows).

## macOS

Voraussetzungen: macOS 14 oder neuer, Xcode 16 oder neuer bzw. dessen Command Line Tools.

```
swift build                 # nur kompilieren (Debug)
scripts/build.sh            # build/Knips.app (Release, signiert)
scripts/install.sh          # bauen, nach /Applications kopieren, starten
scripts/package.sh          # DMG für die Weitergabe (Universal, ohne Entwickler-Code)
```

`build.sh` signiert mit `KNIPS_SIGN_IDENTITY`, sonst mit der jüngsten gültigen „Apple Development“-Identität,
sonst ad hoc. Ad hoc signiert musst du die Bildschirmaufnahme nach jedem Build neu erlauben.

### Selbsttests

Eigene Builds (`build.sh`, `install.sh`) enthalten Selbsttests, die ohne Bildschirmübernahme laufen:

```
build/Knips.app/Contents/MacOS/Knips --selftest <test> <ordner>
```

Jeder Test läuft isoliert in `<ordner>/sandbox` und fasst die Zwischenablage nicht an.

| Test | prüft |
|---|---|
| `render` | Renderer: alle Werkzeuge, Zensurstile, Zuschnitt |
| `detect` | Auto-Zensur (Texterkennung und Muster) am Testbild |
| `ui`, `selection`, `menu`, `history` | Karten, Einstellungen, Auswahl-Overlay, Menü und Verlauf offscreen |
| `cards` | Klicks auf Karten als echte Mausereignisse |
| `live` | Bild- und Video-Editor als echtes Fenster |
| `settings` | Einstellungsfenster je Bereich |
| `output` | Ausgabe 1×, PNG/JPEG, Rahmen, Speichern, „Text kopieren“ ohne Zensiertes |
| `video`, `track` | Video-Zensur, Kürzen, MP4/GIF-Export, mitlaufende Balken |
| `stitch` | Scroll-Screenshot pixelgenau gegen das Original |
| `perf`, `record-bench` | Zeiten und Video-Varianten |
| `capture`, `record 3` | echte Aufnahme, gibt nur Maße und Dauer aus |

Eine Test-Instanz mit eigener Ablage startet `KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`;
Befehle an sie schickt `scripts/test-command.swift`. Befehle, die das Auswahl-Overlay öffnen, übernehmen
den Bildschirm. Dafür lieber die Selbsttests nehmen.

## Windows

Voraussetzungen zum Bauen: Windows 10 oder 11, Rust mit MSVC-Toolchain, Node 22, pnpm 10.

```
cd windows
pnpm install
pnpm tauri build                                                  # Installer unter target\release\bundle\nsis\
cargo build --release -p knips --features dev,custom-protocol     # mit Selbsttests
.\scripts\selftest.ps1 -Exe target\release\knips.exe -Out shots   # alle Selbsttests
```

`selftest.ps1` führt auch `overlay`, `hotkeys` und `clipboard` aus, die Maus, Tastatur und Zwischenablage
benutzen. Auf dem eigenen Rechner einzelne Tests mit `-Tests detect,output,render` wählen.

Auf dem Mac lässt sich die Oberfläche mit Attrappen statt Windows-Teilen entwickeln:

```
cd windows
pnpm dev                    # Oberfläche im Browser auf :1430
cargo test -p knips-core    # Kern-Tests
```

Die CI (`.github/workflows/windows.yml`) baut auf echtem Windows, führt Kern-Tests und alle Selbsttests
aus und baut den Installer. Sie läuft bei Pushes auf `main`, die `windows/` betreffen, und lässt sich von
Hand starten. Ergebnisse liegen im Artefakt „knips-windows“.

## Pull Requests

- Ein Thema pro Pull Request. Beschreibe, was sich für Nutzer ändert und wie du es geprüft hast.
- Die Windows-Fassung folgt der Mac-App. Ändert sich Verhalten nur auf einer Plattform, schreib dazu,
  ob die andere nachziehen sollte.
- Bei Änderungen an der Oberfläche bitte einen Screenshot anhängen.
- Knips baut keine Netzwerkverbindungen auf außer der freiwilligen Statistik. Neue Statistik-Ereignisse
  nur zusammen mit der Liste unter [Datenschutz](README.md#datenschutz) und der Server-Allowlist ändern.

## Commits

Commit-Nachrichten auf Deutsch, kurz, aus Sicht der Nutzer. Betrifft eine Änderung nur einen Teil, steht
er vorne. Beispiele aus dem Verlauf:

```
Windows-Editor: Werkzeugleiste passt sich schmalen Fenstern an
Karten unten links: Klick öffnet, „Öffnen“ statt „Zensieren“, Anzeigedauer frei in Sekunden
Scroll-Screenshots: Bereich wählen, scrollen, Knips setzt pixelgenau zusammen
```

## Lizenz deiner Beiträge

Knips steht unter der GNU General Public License, Version 3 oder später (GPL-3.0-or-later). Mit einem
Beitrag bestätigst du, dass du ihn einreichen darfst, und stellst ihn unter dieselbe Lizenz.

> **Zusätzliche Erlaubnis – bitte lesen:** Mit dem Einreichen eines Beitrags erlaubst du Patrick Birkholz
> außerdem, deinen Beitrag auch unter anderen Lizenzbedingungen als der GPL zu verbreiten, zum Beispiel
> in einer Ausgabe für den Mac App Store. Die GPL-Fassung von Knips und deine eigenen Rechte an deinem
> Beitrag bleiben davon unberührt. Bist du damit nicht einverstanden, schreib das bitte in den Pull
> Request, bevor er übernommen wird.

---

## Contributing (English)

Bug reports, ideas and pull requests are welcome. Build and test instructions are above: `scripts/build.sh`
and `--selftest` on macOS, `pnpm` / `cargo` and `scripts/selftest.ps1` in `windows/`. Commit messages are
written in German, as in the existing history.

Contributions are licensed under GPL-3.0-or-later. **Additional permission:** by submitting a
contribution you also allow Patrick Birkholz to distribute it under license terms other than the GPL,
for example in a Mac App Store edition. The GPL version of Knips and your own rights in your
contribution are not affected. If you do not agree, say so in the pull request before it is merged.
