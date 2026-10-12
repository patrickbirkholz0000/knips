# Knips für Windows

Windows-Fassung von Knips, 1:1 nach der Mac-App in `../Sources/Knips/`.
Begonnen 12.10.2026 auf dem Mac, ohne Windows-Rechner — geprüft wird auf echtem Windows über die
GitHub-CI (`.github/workflows/windows.yml`, Artefakt „knips-windows“ mit Selbsttest-Bildern und Installer).

## Aufbau

| Teil | Was | Mac-Gegenstück |
|---|---|---|
| `crates/core` (`knips-core`) | Datenmodell, Einstellungen, Bildoperationen, Erkennung sensibler Daten, Scroll-Zusammensetzen, Verfolger für mitlaufende Balken, Video-Auto-Zensur, GIF, Karten-Raster. Plattformunabhängig, läuft und testet auf dem Mac. | Models, `SensitiveDetector`, `ScrollStitcher`, `VideoRedactor` (Logik) |
| `crates/platform` (`knips-platform`) | Windows-Schicht in `src/win/`: Monitore, Aufnahme (Desktop Duplication, Fallback Windows.Graphics.Capture), Fensterliste, Auswahl-Overlay (Direct2D), Aufnahmerahmen, Texterkennung (Windows.Media.Ocr), Zwischenablage (verzögertes Rendern), Kürzel (RegisterHotKey + Tastatur-Hook), Video (WGC → Media Foundation, Export, GIF), Explorer/Papierkorb, Auslöser-Ton. `src/mock/` = Attrappe mit identischer Schnittstelle, damit die App auf dem Mac startet. | ScreenCaptureKit, Vision, AVFoundation, Carbon, AppKit |
| `src-tauri` (`knips`) | App: Zustand, Ablage (`store.rs`), Aufnahme-Ablauf (`coordinator.rs`), Bildschirmaufnahme, Scroll, Karten, Menü, Einblendung, Pins, Editor-/Video-Sitzungen, Tray, Befehle (`commands.rs`), Selbsttests (`selftest.rs`, Feature `dev`). | `CaptureCoordinator`, `CaptureStore`, Controller |
| `src` (React + TS) | Alle Fenster als eine Seite, Ansicht über den Hash (`#/menu`, `#/cards`, `#/editor/<id>` …). IPC-Vertrag: `src/shared/ipc.ts` + `types.ts`. Renderer für Bilder: `src/editor/renderer.ts` (Editor-Vorschau und gespeicherte Datei). | SwiftUI-Views, `Renderer.swift` |

Gerendert wird im Editor (Canvas), die Pixel gehen roh an Rust (`editor_commit`), das verkleinert (1×)
und kodiert im Hintergrund. Videos zensiert Rust Bild für Bild (`knips_core::redact`).

## Bauen

Auf Windows (Rust MSVC + Node 22 + pnpm):
```
pnpm install
pnpm tauri build                                   # Installer: target\release\bundle\nsis\Knips_*_x64-setup.exe
cargo build --release -p knips --features dev,custom-protocol   # mit Selbsttests (ohne custom-protocol lädt die App vom Dev-Server :1430)
```
Auf dem Mac (Attrappe statt Windows-Teilen, nur zum Entwickeln):
```
pnpm dev                                           # Oberfläche im Browser auf :1430, Attrappen statt Tauri
node scripts/shot.mjs "/cards" shots/cards.png 1100 1060 --transparent   # Screenshot einer Ansicht
cargo test -p knips-core                           # Kern-Tests
cargo check -p knips --features dev --target x86_64-pc-windows-msvc       # Windows-Code prüfen
```
Der Windows-Check braucht ein Windows-Ziel (`rustup target add x86_64-pc-windows-msvc`) und für
`tauri-build` einen Ressourcen-Compiler (`llvm-rc`; zum reinen Prüfen genügt eine Attrappe, die eine leere
Datei schreibt). Homebrew-Rust hat kein rustup — eine eigene Toolchain mit `CARGO_HOME`/`RUSTUP_HOME`
anlegen.

## Selbsttests

`knips.exe --selftest <test> <ordner>` (Feature `dev`, läuft in `<ordner>\sandbox`, Zwischenablage tabu).
Alle zusammen: `scripts/selftest.ps1` (macht die CI).

| Test | prüft |
|---|---|
| `detect` | Texterkennung + Auto-Zensur am Testbild (E-Mail, IBAN, Telefon, Schlüssel) |
| `output` | Ausgabe 1× PNG/JPEG, Original in voller Auflösung, Editor-Speichern, „Text kopieren“ ohne Zensiertes |
| `selection` | Auswahl-Overlay offscreen (Bereich, Fenstermodus, Aufnahme) |
| `capture` | echte Standbilder aller Monitore, Fensterliste, Fensteraufnahme, Bereichsaufnahme (nur Maße) |
| `record [s]` | echte Bildschirmaufnahme, Dauer und Größe (Datei wird gelöscht) |
| `track` | mitlaufender Balken in scrollendem Testvideo deckt zu jedem Zeitpunkt ab |
| `video` | MP4-Export mit Kürzen + Balken, GIF-Export, Auto-Zensur im Video |
| `perf` | Zeiten: Standbild, 1×+PNG, Texterkennung |
| `hotkeys` | Kürzel über RegisterHotKey und Tastatur-Hook mit simulierten Tastendrücken (auch Druck, Win-Kombination) |
| `overlay` | das echte Auswahl-Overlay mit simulierter Maus/Tastatur: Ziehen, Umschalt-Quadrat, Esc, Eingabe, Leertaste + Fensterklick — nur auf Rechnern ohne Nutzer (CI) |
| `clipboard` | echte Zwischenablage: Bild verzögert anbieten (PNG/JPEG) und zurücklesen — nur für die CI |
| `render` | Renderer der Oberfläche — gleiche Dokumente wie `SelfTest.render` auf dem Mac (Vergleich: `tests/reference/mac-render-*.png`) |
| `ui` | alle Fenster mit Beispieldaten, je ein Bild (Vergleich: `tests/reference/mac-ui/`) |

## Kürzel (Windows-Standard)

Druck = Bereich (Leertaste: Fenster) · Alt+Druck = Fenster · Strg+Druck = Bildschirm · Umschalt+Druck =
Video starten/stoppen. „Mac-Belegung“ in den Einstellungen: Win+Umschalt+4/2/3/5. Windows 11 gibt Druck
dem Bildschirmausschnitt — Knips fragt beim ersten Start einmal, ob es die Taste übernehmen darf
(`HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled`), und fängt sie sonst per Hook ab.

## Ablage

Wie auf dem Mac: Ablage `Bilder\Knips` (immer die gerenderte, zensierte Fassung, standardmäßig 1×),
Originale + Bearbeitungsstand in `%LOCALAPPDATA%\Knips\items\<id>\` (30 Tage), Einstellungen in
`%APPDATA%\Knips\settings.json`, Logs in `%LOCALAPPDATA%\de.birkgroup.knips\logs\`.

## Stand

Gebaut 12.10.2026 (Kern, Windows-Schicht, App, alle Fenster). Auf dem Mac geprüft: Kern-Tests,
Oberfläche im Browser gegen die Mac-Referenzbilder, Ablage-Selbsttest mit Attrappe, Windows-Cross-Check.
Was nur auf echtem Windows geprüft werden kann, deckt die CI über die Selbsttests ab; was auch die CI
nicht kann (Kürzel-Tastendrücke, interaktives Overlay, Mikrofon, Ziehen in andere Apps, Einfügen in
fremde Apps), muss am Gerät getestet werden.
