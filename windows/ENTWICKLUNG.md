# Knips für Windows

Windows-Fassung von Knips, 1:1 nach der Mac-App in `../Sources/Knips/`. Überblick und Mac-Fassung: `../docs/ENTWICKLUNG.md`.
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
cargo test -p knips-platform                       # reine Video-Rechnungen (win/media/pure.rs) auf dem Mac
cargo check -p knips --features dev --target x86_64-pc-windows-msvc       # Windows-Code prüfen (auch ohne --features dev)
```
Der Windows-Check braucht ein Windows-Ziel (`rustup target add x86_64-pc-windows-msvc`) und für
`tauri-build` einen Ressourcen-Compiler (`llvm-rc`; zum reinen Prüfen genügt eine Attrappe, die eine leere
Datei schreibt). Homebrew-Rust hat kein rustup — eine eigene Toolchain mit `CARGO_HOME`/`RUSTUP_HOME`
anlegen. Liegt seit 20.10.2026 in `~/.knips-rust` (`RUSTUP_HOME=~/.knips-rust/rustup`, Cargo aus
`~/.knips-rust/cargo/bin`, Ziel installiert; `llvm-rc` aus `/opt/homebrew/opt/llvm@22/bin` in den PATH,
eigenes `CARGO_TARGET_DIR`, damit sich Homebrew- und rustup-Compiler nicht gegenseitig neu bauen).

## Selbsttests

`knips.exe --selftest <test> <ordner>` (Feature `dev`, läuft in `<ordner>\sandbox`, Zwischenablage tabu).
Alle zusammen: `scripts/selftest.ps1` (macht die CI).

| Test | prüft |
|---|---|
| `detect` | Texterkennung + Auto-Zensur am Testbild (E-Mail, IBAN, Telefon, Schlüssel) |
| `output` | Ausgabe 1× PNG/JPEG, Original in voller Auflösung, Editor-Speichern, „Text kopieren“ ohne Zensiertes |
| `selection` | Auswahl-Overlay offscreen (Bereich, Fenstermodus, Aufnahme) |
| `capture` | echte Standbilder aller Monitore, Fensterliste, Fensteraufnahme, Bereichsaufnahme (nur Maße) |
| `record [s]` | echte Bildschirmaufnahme mit kreisender Maus, Dauer und Größe; Export der Aufnahme ≥ 24 fps (Datei wird gelöscht) |
| `track` | mitlaufender Balken in scrollendem Testvideo deckt zu jedem Zeitpunkt ab |
| `video` | MP4-Export mit Kürzen + Balken, GIF-Export, Auto-Zensur im Video; Quelle mit variabler Bildrate (wie eine Aufnahme, Ø 9 fps): wirksam ≈ 30 fps, Export ≥ 24 fps, jedes Exportbild zeigt das Quellbild seiner Zeit |
| `perf` | Zeiten: Standbild, 1×+PNG, Texterkennung |
| `hotkeys` | Kürzel über RegisterHotKey und Tastatur-Hook mit simulierten Tastendrücken (auch Druck, Win-Kombination) |
| `overlay` | das echte Auswahl-Overlay mit simulierter Maus/Tastatur: Ziehen, Umschalt-Quadrat, Esc, Eingabe, Leertaste + Fensterklick — nur auf Rechnern ohne Nutzer (CI) |
| `clipboard` | echte Zwischenablage: Bild verzögert anbieten (PNG/JPEG) und zurücklesen — nur für die CI |
| `telemetry` | Nutzungsstatistik gegen einen lokalen Server (127.0.0.1): in Sandbox/CI aus, ohne Zustimmung nichts, Zustimmung → Ereignisse → Senden (Nutzlast, Erlaubt-Liste, Deckel 10000) → Zähler zurückgesetzt, Fehler behält Zähler, Widerruf löscht Kennung + Zähler; Nutzlast als `telemetry-payload.json` |
| `render` | Renderer der Oberfläche — gleiche Dokumente wie `SelfTest.render` auf dem Mac (Vergleich: `tests/reference/mac-render-*.png`) |
| `ui` | alle Fenster mit Beispieldaten, je ein Bild (Vergleich: `tests/reference/mac-ui/`), auch `einwilligung.png`, `link-rueckfrage.png` und Allgemein/Datenschutz/Über Knips nach unten gescrollt (`…-unten.png`) |
| `links` | Rückfrage vor knips://fullscreen/last/record (wie `links` auf dem Mac): ohne Einstellung erst Rückfrage, weiterer Link verfällt, Esc/Schließen/Abbrechen = nichts, Aufnehmen erst nach der Schutzzeit (Rust und Oberfläche), „Nicht mehr fragen“ nur mit Aufnehmen, Stoppen und eigener Weg direkt; mit Einstellung direkt; Schalter in Allgemein. Ausführen ist durch eine Liste ersetzt, nimmt nie auf. Bilder: `link-rueckfrage-*.png`, `link-einstellung-allgemein.png` |
| `nomedia` | Windows N/KN ohne Media Feature Pack (simuliert, `KNIPS_TEST_NO_MEDIA`): Importtabelle der knips.exe (mfplat/mfreadwrite/mf nur verzögert), alle Videofunktionen melden den Hinweis statt abzustürzen, Video-Kürzel zeigt Hinweis statt Auswahl, Screenshot geht; Bilder `einstellungen-aufnahme-ohne-media.png`, `menu-ohne-media.png` |
| `oldwin` | Windows vor 10 2004 (simuliert, `KNIPS_TEST_OLD_WINDOWS`): kein `WDA_EXCLUDEFROMCAPTURE`, eigene Fenster für das Standbild ausgeblendet und danach wieder sichtbar, Aufnahmerahmen ohne Ausschluss |

## Nutzungsstatistik und Lizenz

Freie Software unter GPL-3.0-or-later (`LICENSE` = Text von gnu.org, zeigt der NSIS-Installer als
Lizenzseite; Über Knips nennt © und Quellcode-Link). Anonyme Nutzungsstatistik nach Vertrag v1 (gleich
auf dem Mac, Server `https://knips.velno.ai/v1/ping`): Regeln, Erlaubt-Liste (24 Ereignisse), Nutzlast in
`crates/core/src/telemetry.rs` (Kern-Tests), Senden/Fragen in `src-tauri/src/telemetry.rs` (ureq +
native-tls = SChannel, eigener Thread, 30 s nach Start und alle 6 h, höchstens 1× in 24 h, 10 s Zeitlimit).
Zustand in `settings.json` (`telemetryConsent`, `…InstallId`, `…Counts`, `…LastSent`; die Oberfläche
kann ihn über `set_settings` nicht ändern). Frage `#/consent` beim Start nach der Druck-Tasten-Frage,
Schalter unter Einstellungen → Datenschutz. Nie in Selbsttests, Sandbox oder CI (`CI`/`GITHUB_ACTIONS`);
Feature `dev` nur mit `KNIPS_TELEMETRY=1` (Kanal „dev“); `KNIPS_TELEMETRY_URL` ersetzt das Ziel.
Gezählt wird, wo die Aktion fertig ist: `capture_*` (coordinator.rs, scroll.rs), `recording_start/saved`,
`editor_open`/`video_editor_open` (neues Fenster), `censor_auto` (Erkennung), `censor_manual`/`censor_smart`
(Editor über `telemetry_count`), `export_png/jpeg` (Speichern im Editor), `export_mp4` (Video-Export mit
Änderungen), `export_gif`, `copy_image`/`copy_text`/`pin`/`drag_out` (Karten, Editor, Pins),
`history_open`, `settings_open`, `app_launch`.

## Befehle per Link und Sicherheit

`knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` kommen über Deep Link,
zweiten Start oder Startargument immer als „von außen“ (`app::handle_url` → `links.rs`, Regeln in
`knips_core::links`). Was sofort aufnimmt — `fullscreen`, `last`, `record` (nur Start) — fragt erst nach:
Fenster „Aufnahme per Link?“ (`#/link-confirm/<befehl>`, Label `link-confirm-<n>`, schwebend, Texte wie auf
dem Mac); „Aufnehmen“ (⏎) wirkt erst nach 0,6 s (Oberfläche und Rust prüfen), „Abbrechen“/Esc/Schließen
verwirft, „Nicht mehr fragen“ gilt nur mit „Aufnehmen“. Höchstens eine Rückfrage zur Zeit, weitere Links
verfallen solange. Einstellungen → Allgemein → „Aufnahmen per Link ohne Rückfrage“
(`linkCaptureWithoutConfirm`, Standard aus). Kürzel, Menü-Panel, Taskleisten-Symbol und Selbsttests rufen
`Coordinator::perform` direkt auf, ohne Rückfrage; Stoppen einer Aufnahme läuft auch per Link direkt.

`open_url` öffnet nur `https://github.com/patrickbirkholz0000/knips…`, `https://knips.velno.ai…` und
`ms-settings:…` (`knips_core::links::allowed_external_url`). CSP in `tauri.conf.json`: Skripte nur `'self'`,
Bilder/Videos zusätzlich Asset-Protokoll, `data:`, `blob:`; Verbindungen nur IPC. Testbild und simulierte
Eingaben (`sample`, `testinput`) gibt es unter Windows nur mit Feature `dev`.

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
**Auf echtem Windows (CI, 13.10.2026): alle 13 Selbsttests grün**, Installer baut — inkl. echter Kürzel
über simulierte Tastendrücke (Druck, Win-Kombination), echter Zwischenablage und des interaktiven
Auswahl-Overlays mit simulierter Maus. Fenster-Bilder aus der CI gegen die Mac-Referenzen durchgesehen.
CI 20.10.2026 (Version 1.0.0): alle 15 Selbsttests grün, auch `links` (Rückfrage per Link) und alle Fenster
unter der neuen CSP (Editor, Video-Editor, Verlauf, Karten laden Bilder/Videos über das Asset-Protokoll).
Noch am Gerät zu testen: Tastendrücke auf echter Tastatur (Hook neben anderen Tools), Mikrofon,
Ziehen aus den Karten in andere Apps, Einfügen in fremde Apps, mehrere Monitore mit gemischter Skalierung.

## Windows-Ausgaben und ältere Versionen

- **N/KN ohne Media Feature Pack:** Media Foundation fehlt. `knips.exe` lädt `mfplat.dll`, `mfreadwrite.dll`
  und `mf.dll` deshalb verzögert (`src-tauri/build.rs`: `/DELAYLOAD` + `delayimp.lib`); `media::available()`
  prüft sie per `LoadLibraryExW` im Systemordner, `util::enter()` vor jeder MF-Funktion (ein Aufruf ohne DLL
  würde den Prozess beenden). Ohne MF: Video-Kürzel/Menü zeigen den Hinweis „Media Feature Pack“ mit Knopf
  `ms-settings:optionalfeatures`, Einstellungen → Bildschirmaufnahme ebenso, Video-Editor/Export melden ihn
  als Fehler; Screenshots, Texterkennung, Zwischenablage laufen normal. Neue MF-Funktionen nur hinter `enter()`.
- **HEVC** wird nur angeboten (`hevcAvailable`), wenn ein kurzes Testvideo sich schreiben **und** lesen lässt —
  Grafiktreiber bringen oft nur den Encoder mit, ohne „HEVC-Videoerweiterung“ wäre die Aufnahme unlesbar.
  Lässt sich eine Aufnahme trotzdem nicht übernehmen, landet sie unbearbeitet im Ablageordner (Meldung nennt den Pfad).
- **Variable Bildrate:** Aufnahmen schreiben nur Bilder bei Änderungen; die MP4-Angabe ist der Durchschnitt
  (CI: 30 fps eingestellt → 2,4 fps). `probe` liefert deshalb die wirksame Rate aus den Bildabständen
  (`pure::effective_fps`), der Export nimmt sie (unter 24 → 30) und wiederholt stehende Bilder zeitgenau.
- **Vor Windows 10 2004 (Build 19041):** `WDA_EXCLUDEFROMCAPTURE` wirkt wie `WDA_MONITOR` (Fenster schwarz,
  beim Aufnahmerahmen das ganze Video) → wird nicht gesetzt (`capture::exclusion_supported`); stattdessen blendet
  `wm::cloak_for_capture` sichtbare Knips-Fenster für Standbilder kurz aus. In Videos und Scroll-Aufnahmen
  können dort eigene Leisten erscheinen, wenn sie im Bereich liegen (Stopp-Leiste bei Vollbild).
  `SetIsCursorCaptureEnabled` (ab 2004) und `SetIsBorderRequired` (ab Windows 11) sind optional.
- **Mikrofon:** Desktop-Apps fragt Windows 10 nicht; verweigert/fehlt es, läuft die Aufnahme ohne Ton weiter,
  die Einblendung sagt es sofort, nach dem Speichern erklärt ein Dialog die Datenschutz-Schalter
  (`Recorder::warnings`, Knopf `ms-settings:privacy-microphone`).
- **Abstürze:** Panic-Hook (`crash.rs`) schreibt Thread, Stelle und Rückverfolgung ins Log; Wächter setzen
  „Overlay aktiv“, „Overlay wird vorbereitet“ und den Aufnahme-Zustand auch nach einem Panic zurück.

## Windows-Eigenheiten (gefunden in der CI)

- Media-Foundation-H.264 schreibt sonst B-Bilder ohne Edit-Liste → alle Zeitstempel ein Bild zu spät.
  Encoder deshalb mit `CODECAPI_AVEncMPVDefaultBPictureCount = 0`; der Leser zählt das erste Bild als 0.
- Graphics Capture lehnt die rahmenlosen, nicht aktivierbaren Leisten (`WS_EX_NOACTIVATE`) mit
  E_INVALIDARG ab — `capture::own_window_image` schneidet sie dann aus dem Bildschirmbild.
- Windows-Texterkennung verliert bei „sk_live_…“-Schlüsseln gern den Anfang (erst 3× vergrößert vollständig);
  „…-Key:“/„Schlüssel:“ zählen deshalb als Bezeichner, der Balken deckt den ganzen Schlüssel.
  Testbild-Geheimnisse sind erfunden; den Stripe-Schlüssel (`sample::STRIPE_KEY`) nie als ein Literal
  `sk_` + `live_…` schreiben, sondern zusammengesetzt (`concat!`, in TS `"sk_" + "live_…"`) — sonst schlagen
  Secret-Scanner (GitHub-Push-Schutz) an.
- Editor ist auf 90 % des Arbeitsbereichs begrenzt (Mac: ≥ 1140 pt) → Werkzeugleiste wird unter
  1180/1060/960/860 px schrittweise kompakter. Menü 360 statt 340 px breit (Kürzel sind Wörter).
