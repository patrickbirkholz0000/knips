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

## Oberfläche

Gestaltung nach `../docs/design.md` (Markensprache der App-Familie): Werte nur aus
`src/shared/tokens.css` (`--k-*`), Schriften Outfit und JetBrains Mono (`public/fonts`, SIL OFL 1.1). Hell/Dunkel:
Einstellung `appearance` (System/Hell/Dunkel, Einstellungen → Allgemein → „Darstellung“), `src/shared/appearance.ts`
setzt `<html data-theme>` in jedem Fenster — Fenster, die ihn beim Start lesen, brauchen `allow-get-bootstrap`
(auch Einwilligung und Link-Rückfrage). `src/shared/theme.css`: Grundschrift, Papier, Tinte, Fokusrahmen; die alten
Namen (`--ink`, `--accent`, `--panel` …) sind nur noch Aliase auf `--k-*`.

Gemeinsame Bausteine in `src/shared/ui` (`index.tsx` + `ui.css`, Präfix `k-`): `Switch` (Königsblau), `Segmented`,
`Select`, `Checkbox`, `Button` (`primary` Tinte / `secondary` / `text`), `KeyCap` und `Keys` (Kürzel-Text →
Tastenkappen in Mono), `Overline` (Mono-Versalien), `Card`, `Section` (Titel 17 + Karte + Satz), `Row` (Titel,
Beschreibung, Bedienelement rechts), `Notice` (`warn`/`success`), `StatusIcon` (Häkchen / roter Punkt / gestrichelt),
`Dot`, `Badge`, `IconTile`, `Point`, `DialogCard` (Dialog-Karte) und `.k-scrim` für Dialoge
im Fenster.

- **Einstellungen** (`src/settings`): dunkle Seitenleiste mit Zeichen + Wortmarke, Gruppen START · AUFNAHME ·
  BEARBEITEN · APP, unten Bereit-Status und Version. Erste Seite **Start** (`Start.tsx`): Kürzel als
  Tastenkappen, drei Schritte, **Bereit-Check** (`readiness.ts`) aus vorhandenen Daten — Video
  (`mediaAvailable`), Kürzel registriert (`hotkeyFailures`), Druck-Taste (`snippingKeyEnabled`, nur wenn ein
  Kürzel auf Druck liegt), Ablageordner (`save_folder_ok`, im Hintergrund, schreibt nichts), Mikrofon nur als
  Hinweis (Windows meldet die Freigabe für Desktop-Apps nicht). Offene Schritte zählen in der Seitenleiste.
  Bereiche: `SETTINGS_PANES` in `commands.rs` = `Pane` in `support.ts`.
- **Dialoge** (Einwilligung `src/consent`, Link-Rückfrage `src/links`, „Alle Originale löschen?“): `DialogCard`
  auf Papier. Die Rückfrage zeigt die Schutzzeit als leisen Fortschritt im Knopf „Aufnehmen“; Tastaturlogik,
  Schutzzeit und `link_confirm_shown` sind davon unberührt. Größen: `CONSENT_SIZE` 480 × 400, Rückfrage 520 × 352.
- Die Fragen „Druck-Taste übernehmen?“, „Endgültig löschen?“ und Fehlermeldungen sind noch native
  Windows-Dialoge (`tauri_plugin_dialog`).
- Im Browser prüfen: `pnpm dev`, `node scripts/shot.mjs "/settings/start" …`; Attrappen-Schalter in der Adresse:
  `?fehlt` (Bereit-Check mit offenen Schritten), `?bereit` (alles erledigt), `nomedia`, `nohevc`, im Verlauf `?leer`,
  in den Tastaturkürzeln `?aufnahme` (wartet ohne Ende) und `?ungueltig` (meldet Umschalt+A als ungültig), jeweils mit
  `--click='[data-hotkey=captureFullscreen]'`. Dunkel: Systemmodus des Browsers (die Attrappe steht auf „System“), in
  `shot.mjs` mit `--dark`.

## Selbsttests

`knips.exe --selftest <test> <ordner>` (Feature `dev`, läuft in `<ordner>\sandbox`, Zwischenablage tabu).
Alle zusammen: `scripts/selftest.ps1` (macht die CI). Nur einzelne in der CI, ohne Installer und Signatur-Probe:
`gh workflow run windows.yml --ref <zweig> -f selbsttests="hotkeys hotkeyrecord"`.

| Test | prüft |
|---|---|
| `detect` | Texterkennung + Auto-Zensur am Testbild (E-Mail, IBAN, Telefon, Schlüssel); dazu ein hohes (1×6) und ein breites (4×1) Bild aus Kopien des Testbilds: jede Kopie muss alle vier Arten liefern, keine doppelten Funde (Kacheln statt Verkleinern, `detect-hoch/breit-funde.png`) |
| `output` | Ausgabe 1× PNG/JPEG, Original in voller Auflösung, Editor-Speichern, „Text kopieren“ ohne Zensiertes (Karte) und ohne Zensiertes/Weggeschnittenes (Editor-Regel `visible_text`); Speichern in eine blockierte Datei meldet einen Fehler und lässt sie unverändert |
| `selection` | Auswahl-Overlay offscreen (Bereich, Fenstermodus, Aufnahme, Text, Scroll, kleine Auswahl) und Aufnahmerahmen (`render_frame_offscreen`: Video Aufnahme-Rot, Scroll Königsblau hell); Pixelprüfung der Farben aus `overlay/brand.rs` (einzige Stelle für Overlay-Farben in Rust, Werte wie `tokens.css`) |
| `capture` | echte Standbilder aller Monitore, Fensterliste, Fensteraufnahme, Bereichsaufnahme (nur Maße) |
| `record [s]` | echte Bildschirmaufnahme mit kreisender Maus, Dauer und Größe; Export der Aufnahme ≥ 24 fps (Datei wird gelöscht) |
| `track` | mitlaufender Balken in scrollendem Testvideo deckt zu jedem Zeitpunkt ab |
| `video` | MP4-Export mit Kürzen + Balken, GIF-Export, Auto-Zensur im Video; Quelle mit variabler Bildrate (wie eine Aufnahme, Ø 9 fps): wirksam ≈ 30 fps, Export ≥ 24 fps, jedes Exportbild zeigt das Quellbild seiner Zeit |
| `perf` | Zeiten: Standbild, 1×+PNG, Texterkennung |
| `hotkeys` | Kürzel über RegisterHotKey und Tastatur-Hook mit simulierten Tastendrücken (auch Druck, Win-Kombination); Tastennamen und AltGr-Erkennung auf dem deutschen und US-Layout (`probe_layout` lädt sie kurz) |
| `hotkeyrecord` | Kürzel ändern wie ein Nutzer: Einstellungen → Tastaturkürzel, Knopf anklicken (im Fenster und einmal mit simulierter Maus), Tasten per `SendInput` als fremde Eingabe (nicht `OWN_INJECT`). Strg+Umschalt+K/L und Umschalt+F7: Ereignis `hotkey-recorded`, Einstellung, Anzeige, das neue Kürzel löst aus, das alte nicht mehr; nur „A“ und Umschalt+A → `invalid` mit Hinweis unter dem Kürzel, die Aufnahme läuft weiter; Esc bricht ab, Rücktaste entfernt, zweiter Klick beendet; Fokus weg oder Fenster zu beendet die Aufnahme; Druck (Hook-Kürzel) löst aus, während die Einstellungen vorn sind. Jede Taste mit Zahl der Hook-Aufrufe im Log. Ausführen ist durch eine Liste ersetzt, nimmt nie auf. Bilder `kuerzel-*.png` (auch dunkel) |
| `overlay` | das echte Auswahl-Overlay mit simulierter Maus/Tastatur: Ziehen, Umschalt-Quadrat, Esc, Eingabe, Leertaste + Fensterklick — nur auf Rechnern ohne Nutzer (CI) |
| `clipboard` | echte Zwischenablage: Bild verzögert anbieten (PNG/JPEG) und zurücklesen; privates Kopieren (nach der Aufnahme) vom Verlauf/Cloud ausgeschlossen und trotzdem einfügbar — nur für die CI |
| `telemetry` | Nutzungsstatistik gegen einen lokalen Server (127.0.0.1): in Sandbox/CI aus, ohne Zustimmung nichts, Zustimmung → Ereignisse → Senden (Nutzlast, Erlaubt-Liste, Deckel 10000) → Zähler zurückgesetzt, Fehler behält Zähler, Widerruf löscht Kennung + Zähler; Nutzlast als `telemetry-payload.json` |
| `render` | Renderer der Oberfläche — gleiche Dokumente wie `SelfTest.render` auf dem Mac (Vergleich: `tests/vergleich/mac-render-*.png`); „Text kopieren“ der Seite (`src/editor/text.ts`) = `textlayout::visible_text` (feste Fälle + erkannte Zeilen des Testbilds) |
| `ui` | alle Fenster mit Beispieldaten, je ein Bild, auch `einwilligung.png`, `link-rueckfrage.png` und Allgemein/Datenschutz/Über Knips nach unten gescrollt (`…-unten.png`); Einstellungen (alle 9 Bereiche, Start mit Bereit-Check), Einwilligung, Link-Rückfrage und Verlauf zusätzlich dunkel (`…-dunkel.png`), je Fenster `data-theme` passend zur Einstellung; danach keine der gezeigten Aufnahmen im WebView2-Profil (`EBWebView`), Diagnose mit einem Fenster ohne InPrivate. Maßstab ist `../docs/design.md`; Mac-Vergleichsbilder liefern die Selbsttests der Mac-App |
| `links` | Rückfrage vor knips://fullscreen/last/record (wie `links` auf dem Mac): ohne Einstellung erst Rückfrage, weiterer Link verfällt, Esc/Schließen/Abbrechen = nichts, Aufnehmen erst nach der Schutzzeit (Rust und Oberfläche), gehaltene ⏎ / Wiederholungen / ⏎ ohne Loslassen / ⏎ direkt nach Tippen bestätigen nichts, „Nicht mehr fragen“ vor der Schutzzeit gesperrt und nur mit Aufnehmen, Stoppen und eigener Weg direkt; zweiter Start (`app::second_instance` → Deep-Link-Plugin) und Erststart mit `knips://pin` (Kindprozess) je genau ein Aufruf; mit Einstellung direkt; Schalter in Allgemein. Ausführen ist durch eine Liste ersetzt, nimmt nie auf. Bilder: `link-rueckfrage-*.png`, `link-einstellung-allgemein.png` |
| `nomedia` | Windows N/KN ohne Media Feature Pack (simuliert, `KNIPS_TEST_NO_MEDIA`): Importtabelle der knips.exe (mfplat/mfreadwrite/mf nur verzögert), alle Videofunktionen melden den Hinweis statt abzustürzen, Video-Kürzel zeigt Hinweis statt Auswahl, Screenshot geht; Bilder `einstellungen-aufnahme-ohne-media.png`, `menu-ohne-media.png` |
| `oldwin` | Windows vor 10 2004 (simuliert, `KNIPS_TEST_OLD_WINDOWS`): kein `WDA_EXCLUDEFROMCAPTURE`, eigene Fenster für das Standbild ausgeblendet und danach wieder sichtbar, Aufnahmerahmen ohne Ausschluss |
| `storage` | Umzug aus dem Installationsordner (bis 1.0.0) an den Ort der App-Kennung, Zwischendateien (Start: alles, regelmäßig: nur Altes, Pins bleiben), Video-Vorschaubilder gehen mit Löschen/„Originale löschen“, Ablauf nach der Frist (geöffnete bleiben), Papierkorb-Erkennung (lokal ja, `\\localhost\C$` nein); in der CI der Druck-Tasten-Vermerk in `HKCU\Software\Knips` |

Deinstallation: `scripts/uninstall-test.ps1 -Setup <…-setup.exe>` (nur CI, verändert das Benutzerprofil) —
installiert still, startet einmal (Umzug, Aufräumen), deinstalliert ohne und mit „App-Daten löschen“
(`/S`, `/S /DELETEAPPDATA`) und prüft Ordner, Registry und Druck-Taste. Ergebnis `<Out>\ergebnis.txt`.

## Nutzungsstatistik und Lizenz

Freie Software unter GPL-3.0-or-later (`LICENSE` = Text von gnu.org; Über Knips nennt © und Quellcode-Link).
Die Lizenzseite des NSIS-Installers zeigt `installer/datenschutz-und-lizenz.txt`: erst den
Datenschutzhinweis (verlangt die SignPath Foundation während der Installation), dann genau `LICENSE` — die CI
prüft, dass das Ende der Datei mit `LICENSE` übereinstimmt. Anonyme Nutzungsstatistik nach Vertrag v1 (gleich
auf dem Mac, Server `https://knips.velno.ai/v1/ping`): Regeln, Erlaubt-Liste (24 Ereignisse), Nutzlast in
`crates/core/src/telemetry.rs` (Kern-Tests), Senden/Fragen in `src-tauri/src/telemetry.rs` (ureq +
native-tls = SChannel, eigener Thread, 30 s nach Start und alle 6 h, höchstens 1× in 24 h, 10 s Zeitlimit).
Zustand in `settings.json` (`telemetryConsent`, `…InstallId`, `…Counts`, `…LastSent`; die Oberfläche
kann ihn über `set_settings` nicht ändern). Frage `#/consent` beim Start nach der Druck-Tasten-Frage,
Schalter unter Einstellungen → Datenschutz. Nie in Selbsttests, Sandbox oder CI (`CI`/`GITHUB_ACTIONS`);
Feature `dev` nur mit `KNIPS_TELEMETRY=1` (Kanal „dev“); nur dort ersetzt `KNIPS_TELEMETRY_URL` das Ziel, und
nur durch `https://…` oder `http://` auf 127.0.0.1/localhost (`knips_core::telemetry::endpoint_override_allowed`).
Weitergabe-Builds lesen die Variable nie. `telemetry_count` aus der Oberfläche nimmt nur `censor_manual`/`censor_smart`.
Gezählt wird, wo die Aktion fertig ist: `capture_*` (coordinator.rs, scroll.rs), `recording_start/saved`,
`editor_open`/`video_editor_open` (neues Fenster), `censor_auto` (Erkennung), `censor_manual`/`censor_smart`
(Editor über `telemetry_count`), `export_png/jpeg` (Speichern im Editor), `export_mp4` (Video-Export mit
Änderungen), `export_gif`, `copy_image`/`copy_text`/`pin`/`drag_out` (Karten, Editor, Pins),
`history_open`, `settings_open`, `app_launch`.

## Befehle per Link und Sicherheit

`knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` kommen über Deep Link,
zweiten Start oder Startargument immer als „von außen“ (`app::handle_url` → `links.rs`, Regeln in
`knips_core::links`). Jeder Link läuft genau einmal: Zweiter Start → `single-instance` (OHNE sein Feature
`deep-link`) → `app::second_instance` → Deep-Link-Plugin (`handle_cli_arguments`: genau ein Argument, Schema
`knips`) → `on_open_url` → `handle_url`. Erststart: Das Plugin meldet das Argument in seinem eigenen Setup,
bevor `on_open_url` angemeldet ist (ungehört) — `app::first_start` führt es aus. Mit dem Feature `deep-link`
liefe jeder Link beim zweiten Start doppelt (Menü auf und zu, zwei Pins, zwei Aufnahmen).

Was sofort aufnimmt — `fullscreen`, `last`, `record` (nur Start) — fragt erst nach: Fenster „Aufnahme per
Link?“ (`#/link-confirm/<befehl>`, Label `link-confirm-<n>`, schwebend, Texte wie auf dem Mac). Schutzzeit
0,6 s ab Sichtbarkeit: Die Oberfläche fragt `link_confirm_shown`, bis Rust das Fenster als sichtbar bestätigt;
erst ab da zählen Rust (`LinkGate::shown`) und die Oberfläche. Vorher nimmt Rust kein „Aufnehmen“ an.
Oberfläche: jede getippte Taste (außer ⏎/Esc/Tab/Umschalttasten) startet die Schutzzeit neu; ⏎ zählt nur als
frischer Druck (keine Wiederholung, und war ⏎ vor Ablauf unten, erst nach dem Loslassen); der Browser löst
Knöpfe per ⏎ nie selbst aus; ⏎ auf „Abbrechen“ = Abbrechen; „Nicht mehr fragen“ ist vor der Schutzzeit
gesperrt und gilt nur mit „Aufnehmen“. Esc/Schließen/„Abbrechen“ verwerfen immer. Höchstens eine Rückfrage zur
Zeit; weitere Links verfallen und holen sie NICHT erneut nach vorn (Mac: schon — unter Windows würde das den
Fokus mitten ins Tippen ziehen). Einstellungen → Allgemein → „Aufnahmen per Link ohne Rückfrage“
(`linkCaptureWithoutConfirm`, Standard aus). Kürzel, Menü-Panel, Taskleisten-Symbol und Selbsttests rufen
`Coordinator::perform` direkt auf, ohne Rückfrage; Stoppen einer Aufnahme läuft auch per Link direkt.

**IPC nur so weit wie nötig.** `build.rs` listet alle eigenen Befehle (`AppManifest::commands` → Berechtigungen
`allow-<befehl>`, generiert in `src-tauri/permissions/autogenerated/`, nicht eingecheckt). Damit darf jedes
Fenster nur, was ihm `capabilities/windows.json` erlaubt (je Label: `settings`, `menu`, `cards`, `history`,
`pin-*`, Leisten, `consent`, `link-confirm-*`, `editor-*`, `video-*`; alle nur Ereignisse empfangen, nicht
senden). **Neuer Befehl = in `generate_handler!`, `build.rs` und der passenden Capability eintragen**, sonst
lehnt Tauri ihn ab. Test-Befehle (`selftest_probe`, `selftest_report`) erlaubt erst `selftest::after_setup`
zur Laufzeit. `set_settings`: nur Felder aus `SETTINGS_WINDOW_FIELDS` (Einstellungsfenster) bzw.
`EDITOR_WINDOW_FIELDS` (`redactStyle`, Editoren), geprüft von `Settings::patched` (Typen, Auswahlwerte,
Bereiche); Ablageordner nach `check_save_folder` (Laufwerkspfad, kein UNC-/Gerätepfad, kein `..`, keine
Gerätenamen) und muss als Ordner existieren — Fehler zeigt Einstellungen → Ablage an. `open_save_folder` öffnet
nur Ordner (`shell::open_folder`, Verb „explore“). Asset-Protokoll: `items` und `temp` ganz, aus dem
Ablageordner nur die Dateien eigener Aufnahmen (`allow_item_files`). Einstellungs-Bereich (`pane`) nur aus
`SETTINGS_PANES`, Werkzeug (`item_open`, `set_editor_prefs`) nur aus `EDITOR_TOOLS`.

`open_url` öffnet nur `https://github.com/patrickbirkholz0000/knips…`, `https://knips.velno.ai…` und
`ms-settings:…` (`knips_core::links::allowed_external_url`). CSP in `tauri.conf.json`: Skripte nur `'self'`,
Bilder/Videos zusätzlich Asset-Protokoll, `data:`, `blob:`; Verbindungen nur IPC. Testbild und simulierte
Eingaben (`sample`, `testinput`) gibt es unter Windows nur mit Feature `dev`.

## Verteilung

- **Release** (`.github/workflows/release.yml`, Einrichtung in `../RELEASING.md`): Jobs `windows` (baut,
  ohne Signatur-Zugang) → `sign-app` (SignPath signiert `knips.exe`) → `bundle` (`scripts/bundle-signed.ps1`:
  Installer um die signierte EXE, `tauri bundle --no-binary-patching`, sonst patcht Tauri die EXE und die
  Signatur bricht) → `sign-installer` → `publish` (`scripts/check-signature.ps1 -Installer`, Prüfsumme, Release).
  Ohne `SIGNPATH_API_TOKEN`/`SIGNPATH_ORGANIZATION_ID` unsigniert wie früher. Version setzt
  `scripts/set-version.mjs`. Den Ablauf prüft der Job `signatur` in `windows.yml` mit Wegwerf-Zertifikat.
- **PowerShell** (`install.ps1`, ausgeliefert vom Worker unter `https://knips.velno.ai/install.ps1`): neuestes
  Release, SHA-256, Signatur (nur SignPath Foundation), `/S`, Start; `-Version`, `-InstallerPath`, `-NoStart`.
  UTF-8 **mit** BOM (Windows PowerShell 5.1). CI-Test: `scripts/test-install.ps1` (installiert wirklich).
  Tauri-NSIS pro Benutzer: `%LOCALAPPDATA%\Knips\knips.exe`, Eintrag `HKCU\…\Uninstall\Knips`,
  Deinstaller `uninstall.exe /S` (kopiert sich nach %TEMP%, läuft dort weiter).
- **winget** (`winget/` Vorlagen, `../scripts/winget-manifest.sh X.Y.Z`): Paket `PatrickBirkholz.Knips`,
  erste Einreichung von Hand (RELEASING.md).
- Installer-Seiten fotografiert die CI (`scripts/installer-shots.ps1` → `shots/installer/`).

## Kürzel (Windows-Standard)

**Raw Input bleibt aus** (`device_event_filter(Always)` in `main.rs`): tao meldet sonst Tastatur und Maus für Raw Input
an (Geräte-Ereignisse, die Knips nicht braucht). Solange das besteht, ruft Windows die Low-Level-Hooks von Knips nicht
auf, während ein Knips-Fenster im Vordergrund ist — in der CI 0 Aufrufe, mit WebView2 wie mit einem schlichten
Win32-Fenster, für Tasten aus Knips wie aus einem anderen Prozess, mit und ohne Modul-Handle, beide Prozesse „Hoch“;
mit fremdem Fenster vorn oder ohne die Anmeldung 6 von 6. Bis 1.0.0 nahm deshalb „Kürzel festlegen“ keine Taste an
(die Tasten landeten in der Seite), und Hook-Kürzel (Druck, Win-Kombinationen) blieben über eigenen Fenstern stumm.

**Festlegen** (Einstellungen → Tastaturkürzel): Klick auf ein Kürzel → `hotkey_record` → der Hook-Thread hängt den
Tastatur-Hook frisch ein (einen still entfernten hielte `HOOK` sonst für aktiv), erneuert ihn während der Aufnahme
alle 2 s und schluckt bis zum Ergebnis jede Taste, in allen Apps. Im Hook-Thread läuft nichts, was hängen kann
(Signalton und Rückmeldung in eigenem Thread), sonst hängt Windows den Hook nach einer Zeitüberschreitung still aus.
Unter dem Kürzel steht solange der Hinweis „Kombination mit Strg, Alt oder Win drücken – oder eine F-Taste/Druck.
Esc bricht ab, Rücktaste entfernt.“ Gültig: mit Strg/Alt/Win oder Druck, Pause, Rollen, Einfg,
F1–F24 allein (`KeyCombo::is_valid`), Umschalt darf dazu. Eine ungültige Taste (nur „A“, Umschalt+A) piept, meldet
`hotkey-recorded` mit `result: "invalid"` („Umschalt+A geht nicht – braucht Strg, Alt oder Win.“, Zeile mit rotem Punkt,
der Knopf zuckt kurz) und die Aufnahme läuft weiter. Verliert das Einstellungsfenster den Fokus oder wird es
geschlossen, endet die Aufnahme (`blur` in `panes.tsx`, `app::on_window_destroyed`) — sonst schluckte der Hook weiter
Tasten in anderen Apps.

Druck = Bereich (Leertaste: Fenster) · Alt+Druck = Fenster · Strg+Druck = Bildschirm · Umschalt+Druck =
Video starten/stoppen. „Mac-Belegung“ in den Einstellungen: Win+Umschalt+4/2/3/5. Windows 11 gibt Druck
dem Bildschirmausschnitt — Knips fragt beim ersten Start einmal, ob es die Taste übernehmen darf
(`HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled`), und fängt sie sonst per Hook ab.

Strg+Alt ist unter Windows dasselbe wie AltGr: Eine aufgenommene Kombination, die auf dem aktuellen oder einem
anderen installierten Layout ein Zeichen tippt (deutsch Strg+Alt+Q = „@“, +E = „€“), lehnt Knips ab
(`knips_platform::hotkeys::altgr_char` per `ToUnicodeEx`, Meldung in Einstellungen → Tastaturkürzel,
Ereignis `hotkey-recorded` mit `result: "rejected"`). Schon gespeicherte Kürzel bleiben. Tastennamen: Zeichentasten
(OEM 0xBA–0xE2) wie auf dem aktuellen Layout beschriftet (`hotkeys::key_name`, `MapVirtualKeyExW`; US „;“ statt
„Ü“), Buchstaben/Ziffern nach dem Virtual-Key, Sondertasten deutsch; die Attrappe nimmt die deutschen Namen
aus `knips_core::settings::key_name`.

## Ablage, Datenschutz, Deinstallation

Wie auf dem Mac: Ablage `Bilder\Knips` (immer die gerenderte, zensierte Fassung, standardmäßig 1×).
Alles andere liegt in den Ordnern der App-Kennung (`paths.rs`), nie im Installationsordner
(`%LOCALAPPDATA%\Knips`): Originale + Bearbeitungsstand in `%LOCALAPPDATA%\de.birkgroup.knips\items\<id>\`,
daneben `EBWebView\` (WebView2) und `logs\`; Einstellungen in `%APPDATA%\de.birkgroup.knips\settings.json`.
Bis 1.0.0 lagen die Originale im Installationsordner und die Einstellungen in `%APPDATA%\Knips` —
`paths::migrate_legacy` holt sie beim Start (vor dem Laden) an den neuen Ort.

- **Ablauf:** Originale verfallen nach der Frist (Standard 30 Tage) beim Start und alle 6 h
  (`app::housekeeping`, offene Editoren ausgenommen). Dateien im Ablageordner bleiben.
- **Zwischendateien** `%TEMP%\Knips` (unzensierte Video-Einzelbilder `video-thumbs\<id>-<rev>-<i>.jpg`,
  laufende Aufnahmen/Exporte, Pins): beim Start ganz geleert, alle 6 h, was einen Tag unverändert ist
  (Pins und offene Video-Editoren ausgenommen). Ältere Vorschaubilder einer Aufnahme fallen beim Erzeugen
  neuer weg; Löschen und „Originale löschen“ nehmen sie mit.
- **Speichern:** Fehler bleiben nicht stumm. Der Editor wartet, bis die Datei im Ablageordner ersetzt
  ist (`store::Written`); sonst Dialog „Nicht gespeichert“ (Grund; die Datei hat noch den alten Stand),
  „Fertig“ schließt nur nach Erfolg. Fehler beim Speichern nach der Aufnahme und beim Löschen meldet
  `Store::set_on_error` als Dialog.
- **Löschen:** in den Papierkorb (`FOF_WANTNUKEWARNING` als Netz). Laufwerke ohne Papierkorb
  (`shell::can_trash`: Netzlaufwerk, Wechseldatenträger, „sofort löschen“, Richtlinie) → erst Rückfrage
  „Endgültig löschen?“ (`store::delete_item`). Klappt der Papierkorb nicht, bleibt die Datei liegen.
- **Zwischenablage:** Das automatische Kopieren nach der Aufnahme (noch unzensiert) ist privat
  (`clipboard::set_image_private`: `ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory = 0`, `CanUploadToCloudClipboard = 0`) — nicht in Win+V, nicht in der
  Cloud. Kopieren aus Karte, Editor und Pin bleibt normal.
- **WebView2:** Alle Fenster laufen InPrivate (`wm::Spec::incognito`) — Originale, Vorschaubilder und
  Videos, die über das Asset-Protokoll geladen werden (Tauri schickt kein `Cache-Control`), landen nicht
  im Festplatten-Cache von `EBWebView`. Folge: `localStorage` gilt nur bis zum Beenden.
- **Text kopieren:** Karte = Texterkennung auf der gespeicherten (zensierten) Datei; Editor = erkannte
  Zeilen des Originals, gefiltert nach `src/editor/text.ts` (gleiche Regel wie `textlayout::visible_text`):
  jede Überschneidung mit einer Zensur → „████“, Wörter außerhalb des Zuschnitts fallen weg,
  angeschnittene → „████“, Zeilen ohne Wortboxen fallen bei Berührung weg.
- **Deinstallation** (`src-tauri/installer-hooks.nsh` über `bundle.windows.nsis.installerHooks`): gibt
  die Druck-Taste immer an Windows zurück, wenn Knips sie übernommen hat (Vermerk `HKCU\Software\Knips`:
  `PrintScreenKeyTaken`, `PrintScreenKeyOriginal`, geschrieben von `hotkeys::set_snipping_key`; für
  Übernahmen aus 1.0.0 beim Start nachgeholt). Mit „App-Daten löschen“ entfernt Tauri
  `%APPDATA%`/`%LOCALAPPDATA%\de.birkgroup.knips`, der Hook zusätzlich die Orte bis 1.0.0 und `%TEMP%\Knips`.
  Still: `uninstall.exe /S /DELETEAPPDATA`. Beim Aktualisieren (`/UPDATE`) passiert nichts davon.

## Stand

Gebaut 12.10.2026 (Kern, Windows-Schicht, App, alle Fenster). Auf dem Mac geprüft: Kern-Tests,
Oberfläche im Browser gegen die Mac-Referenzbilder, Ablage-Selbsttest mit Attrappe, Windows-Cross-Check.
**Auf echtem Windows (CI, 13.10.2026): alle 13 Selbsttests grün**, Installer baut — inkl. echter Kürzel
über simulierte Tastendrücke (Druck, Win-Kombination), echter Zwischenablage und des interaktiven
Auswahl-Overlays mit simulierter Maus. Fenster-Bilder aus der CI gegen die Mac-Referenzen durchgesehen.
CI 20.10.2026 (Version 1.0.0): alle 15 Selbsttests grün, auch `links` (Rückfrage per Link) und alle Fenster
unter der neuen CSP (Editor, Video-Editor, Verlauf, Karten laden Bilder/Videos über das Asset-Protokoll).
CI 20.10.2026 (Medien/Verträglichkeit): alle 17 Selbsttests grün, neu `nomedia` und `oldwin`; die knips.exe aus
dem Installer lädt mfplat/mfreadwrite/mf nur verzögert (`llvm-readobj --coff-imports`: nur unter `DelayImport`);
Aufnahme mit bewegter Maus wirksam 30 fps (vorher als 2,4 fps exportiert), VFR-Testvideo Ø 8,9 → Export 30 fps.
Nicht in der CI prüfbar: echte N-Edition, echtes Windows vor 2004, Mikrofon ohne Freigabe.
CI 20.10.2026 abends: alle 15 grün mit Capabilities je Fenster (alle Fenster-Bilder vollständig), Links genau
einmal (zweiter Start und Erststart), gehärteter Rückfrage und Layout-Prüfung (deutsch/US) in `hotkeys`.
CI 20.10.2026 (Daten/Datenschutz): alle 16 Selbsttests grün, neu `storage`; Auto-Zensur auf hohem Bild
(1400×5965) 24 statt 9 Funde, auf breitem (6011×880) 16 statt 1; „Text kopieren“ Seite = Rust in allen
Fällen; blockierte Datei → „Zugriff verweigert“ statt stillem Erfolg; Druck-Tasten-Vermerk in der Registry.
WebView2-Cache geprüft: Auch ohne InPrivate landeten per Asset-Protokoll geladenes Bild und Video (Range)
nicht im Cache — InPrivate bleibt als Absicherung. `scripts/uninstall-test.ps1` läuft erst, wenn der
Workflow es aufruft; den stillen Deinstaller mit Hook (`/S`) prüft bereits `scripts/test-install.ps1`.
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

- Texterkennung: Bildschirmfotos wie auf dem Mac als Ganzes auf ≤ 2048 px. Hohe/breite Bilder
  (Scroll-Screenshots) würden dabei unlesbar klein — `knips_core::ocrtiles` zerlegt sie in überlappende
  Kacheln (≤ 2048 px, nie stärker als 0,5 verkleinert, Überlappung 384 px); jedes Wort zählt in der
  Kachel seiner Mitte, über Kachelgrenzen laufende Zeilen werden wieder eine.
- Scroll-Screenshots höchstens `stitch::MAX_HEIGHT` = 30 000 px (Canvas des Editors); dann endet die
  Aufnahme von selbst mit Hinweis. Behalten werden nur die neuen Zeilen, nicht jedes Einzelbild.

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
  1480/1400/1250/1180/1000/940/820 px schrittweise kompakter (Stufen in `src/editor/editor.css`, ab 1250 Farben als
  Popover; passt mit Auto-Zensur bis ~760 px). Video-Editor (mind. 900 px): unter 1020 px nur Symbole für Zensur-Stil
  und Auto-Zensur. Menü 360 statt 340 px breit (Kürzel sind Wörter).
