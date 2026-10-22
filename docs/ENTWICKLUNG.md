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

**Sparkle** (automatische Updates, MIT, `Package.swift` mit fester Version): `build.sh` legt `Sparkle.framework` aus
dem SwiftPM-Build nach `Contents/Frameworks` (rpath `@executable_path/../Frameworks` in `Package.swift`), ohne
XPC-Dienste (Knips ist nicht sandboxed), Header und Module, dazu `Resources/Sparkle-LICENSE.txt`. Signiert wird von
innen nach außen, ohne `--deep`: `Autoupdate`, `Updater.app`, Framework (Hardened Runtime, Zeitstempel wie die App,
ohne die Entitlements von Knips), dann die App. Das Universal-Framework kommt fertig aus Sparkles XCFramework.
`swift build` allein ergibt ein Programm, das nur im Bundle startet.

## Prüfen ohne den Bildschirm zu übernehmen

`build/Knips.app/Contents/MacOS/Knips --selftest <test> <ordner>` (läuft isoliert in `<ordner>/sandbox`; Einstellungen in der
Domäne `de.birkgroup.knips.sandbox` (`UserDefaults.knips`), die jeder Test zu Beginn leert — die echte Domäne
`de.birkgroup.knips` bleibt unberührt, Fensterpositionen werden in der Sandbox nicht gemerkt):

| Test | prüft |
|---|---|
| `render` | Renderer: alle Werkzeuge, Zensurstile, Zuschnitt → PNG |
| `detect` | Auto-Zensur (Vision + Muster) am Testbild; Pflicht: erfundener Stripe-Key und E-Mail in 1× und 2×, außerdem auf hohen (1400×7040, 1400×14080), breiten (7000×880) und 1×-Bildern (4K, Ultrawide) in jedem Fenster an der richtigen Stelle; „Text kopieren“ ohne doppelte Zeilen über Kachelnähte; jede Überschneidung mit Zensur oder gefüllter Form verdeckt |
| `ui` / `selection` | Karten, Einstellungen, Auswahl-Overlay offscreen; `selection` auch: Overlay vor dem Standbild durchsichtig und nur abgedunkelt (Deckkraft 0,4, nie schwarz), mit Standbild deckend (`ui-auswahl-vor-standbild.png`) |
| `cards` | Klicks auf eine Karte als echte Mausereignisse: Fläche öffnet, jeder Knopf nur seine Aktion; Raster mit mehreren Spalten trifft die richtige Karte |
| `live [hell\|dunkel\|beide]` | Bild- und Video-Editor als echtes Fenster, 1 pt in der Bildschirmecke, per SCK fotografiert — je Darstellung breit, schmal (`EditorChrome.minWidth` 860 pt), Werkzeuge, Rahmen (+ Popover), Zuschneiden; einmal Zoom, schlaue Balken, ⌘⏎/⌘Z genau einmal, Klicks in Höhe der Titelleiste landen in der SwiftUI-Fläche (hitTest) |
| `settings [bereich,…]` | Einstellungsfenster je Bereich hell und dunkel (`einstellungen-<bereich>[-dunkel].png`), Start mit simuliertem Bereit-Check (`start-offen*.png` drei Schritte offen, `start-bereit*.png`) und Zählung der offenen Schritte, Darstellung System/Hell/Dunkel → `NSApp.appearance`, Kürzel-Eingabe (Hinweis während der Aufnahme; was aus einem Tastendruck wird: ⇧A, A, ↖ (`kVK_Home`), F5, ⌦, ⌘⌫ werden Kürzel, Esc bricht ab, ⌫/⇧⌫ entfernen; ↖, ⇧A und Esc als echte Eingabe über den Tastatur-Monitor, ohne Kürzel in der Sandbox; gespeichert ↖ und ⇧A mit Hinweis, `einstellungen-shortcuts-einzeltaste*.png`), Eintippen der Anzeigedauer, Datenschutz mit Statistik an/aus und „In Bildschirmübertragungen verbergen“ (alle Fenster `sharingType .none`, auch neue; ScreenCaptureKit bekommt das Fenster dann leer; aus → `.readOnly`); Dialoge Zustimmung (⏎ entscheidet nichts), Freigabe, Kürzel-Übernahme (`zustimmung*.png`, `freigabe*.png`, `kuerzel-uebernehmen*.png`, nur gezeigt — übernimmt nie) |
| `links` | Rückfrage vor knips://fullscreen/last/record immer (auch mit fremdem `linkCaptureWithoutConfirm` in den Defaults), Esc/Schließen/Abbrechen = nichts, ⏎ erst nach der Schutzzeit (beginnt bei jedem Zeigen neu), weitere Links verfallen ohne das Fenster nach vorn zu holen, Absender in der Rückfrage (echtes GURL-Apple-Event an sich selbst → „Knips“), Stoppen und eigener Test-Kanal direkt, Link-Aufnahmen mit Quelle `.link`, Rückfrage „Text kopieren?“, Overlay per Link: ⏎ und Klick erst nach der Schutzzeit (nur Modell und Ansicht, nie auf dem Bildschirm). Aufnahmen sind durch eine Liste ersetzt, nimmt nie auf. Bilder hell und dunkel: `link-rueckfrage-*.png`, `link-text-kopieren*.png`, `link-schutzzeit.png` (Primärknopf noch blass, Fortschritt darunter), `link-einstellungen-datenschutz.png` |
| `update [<feed-ordner>]` | Automatische Updates: Sperren (Selbsttest, Sandbox, CI, eigener Build ohne `KNIPS_UPDATE_FEED`; im Release wirkt `KNIPS_UPDATE_FEED` nicht), Zeitplan (erste Prüfung nach 5 min, höchstens alle 24 h), Einstellung bleibt gespeichert, Info.plist (Feed, `SUPublicEDKey`, Prüfung vor dem Entpacken, keine ATS-Ausnahme), Sparkle im Bundle ohne XPC-Dienste, alle Delegate-Methoden vorhanden, Texte. Ende zu Ende nur über `scripts/update-test.sh` (siehe „Updates“) |
| `update-installed <ordner> <app> <build>` | Beobachter für `scripts/update-test.sh`: keine Fenster der Testkopie und ihrer Helfer, Build N+1 nach dem Beenden an derselben Stelle, Installer beendet, kein Neustart, Code-Signatur streng gültig |
| `telemetry [live]` | Nutzungsstatistik: Sperren (Selbsttest/Sandbox/CI/Entwickler-Build), Payload (genau die Vertragsfelder, Allowlist, Deckel), Zustimmung → Zählen → Senden an lokalen Server (127.0.0.1) → Abmelden; Zähler bleiben nach Fehlern. `live` schickt zusätzlich einen echten Ping (nur mit `KNIPS_TELEMETRY=1`, Kanal `dev`) |
| `output` | Ausgabe 1× + PNG/JPEG, Rahmen, Speichern aus dem Editor, „Text kopieren“ ohne Zensiertes (Karte; Editor mit Zuschnitt und angeschnittenem Schlüssel), Zwischenablage nach Zensieren + „Fertig“ = zensierte Fassung, fremder Inhalt bleibt, Link-Aufnahme ohne Zwischenablage, `knips://pin` lädt keine http-Adresse (private `NSPasteboard` über `Clipboard.testPasteboard`) |
| `track` | Mitlaufender Zensurbalken in scrollendem Video (Texterkennung prüft jeden Zeitpunkt) |
| `stitch` | Scroll-Screenshot: Ausschnitte → exakt das Originalbild (Pixelvergleich); nur neue Zeilen im Speicher, Obergrenze, Anhängen und Zusammensetzen gleichzeitig, Nachzügler einer beendeten Aufnahme landen nie in der nächsten |
| `robust` | Ablage und Abläufe ohne Bildschirm: JPEG über 65 535 px → PNG, Ausweichordner bei nicht erreichbarer Ablage, Schreibfehler werden gemeldet, Aufräumen (Frist, `$TMPDIR/Knips`), Beenden wartet auf Schreibvorgänge; Aufnahme-Zustände mit einer Attrappe (belegt ab dem Start, Abbruch während Start/Countdown, Writer-Fehler, Beenden während der Aufnahme) |
| `ocr-bench` | Tempo und Trefferzahl der Texterkennung auf Testbildern im Speicher (4K/5K 2× und 1× textreich, hohe/breite Bilder, ohne Text) |
| `menu` / `history` | Menü-Panel (auch mit Hinweis auf ein Update: `menu-update.png`, `menu-update-verfuegbar.png`) und Verlauf-Fenster (Verlauf leer und mit Video, Maus über der neuesten Karte, hell und dunkel; leerer Filter) |
| `chrome` | Schwebeflächen ohne Bildschirm (Aufnahme-Attrappe): Aufnahme-Leiste, Countdown, Scroll-Leiste, Hinweise (HUD), Pin-Steuerung, Rahmen, Hinweiszeilen des Overlays, Menü während eines Videos — je über heller App und dunklem Grund |
| `perf` / `record-bench` | Zeiten (Overlay, Speichern, Texterkennung) und Video-Varianten |
| `video` | Video-Zensur mit Zeitbereich, Kürzen, MP4- und GIF-Export, Auto-Zensur im Video |
| `capture` / `record 3` | echte Aufnahme — gibt nur Maße/Dauer aus, speichert keine Inhalte |

Aus dem Terminal gestartet erbt das Binary dessen Bildschirm-Freigabe. End-to-End mit laufender App:
`KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`, dann `open knips://debug-sample`,
`open knips://fullscreen`, `open knips://debug-snapshot` (fotografiert nur eigene Fenster).
**Achtung:** `knips://fullscreen` nimmt einen echten Screenshot auf (über einen Link erst nach der Rückfrage; in die
Zwischenablage kommt er weder per Link noch in der Sandbox).

Testbild-Geheimnisse sind erfunden. Den Stripe-Schlüssel (`SelfTest.sampleStripeKey`) nie als ein Literal
`sk_` + `live_…` schreiben, sondern zusammengesetzt — sonst schlagen Secret-Scanner (GitHub-Push-Schutz) an.

Fensterbilder entstehen hell und dunkel (`<name>.png`, `<name>-dunkel.png`, gesetzt über `NSApp.appearance`);
`KNIPS_TEST_APPEARANCE=light|dark` beschränkt auf eine Darstellung, `KNIPS_TEST_WINDOW_HEIGHT=1400` zeigt in `settings`
ganze Seiten.

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
- Zwischenablage: Knips merkt sich, welche Aufnahme es zuletzt hineingelegt hat (`Clipboard`, über `changeCount`).
  Speichert der Editor diese Aufnahme und hat seitdem niemand etwas anderes kopiert, ersetzt er sie durch die neue
  (zensierte) Fassung — ⇧⌘4 kopiert ja sofort das Original. „Text kopieren“ im Editor erkennt den Text auf dem
  gerenderten Bild (Zuschnitt, Zensur), wie die Karte.
- Originale + Bearbeitungsstand (JSON): `~/Library/Application Support/Knips/items/<uuid>/`.
  Nur damit lässt sich eine Zensur wieder aufheben. Wird nach 30 Tagen aufgeräumt (beim Start und alle 6 h,
  `CaptureStore.purgeExpired`); Reste in `$TMPDIR/Knips`, an denen seit 1 h nichts geschrieben wurde, ebenso.
- Ablageordner nicht erreichbar (Netzlaufwerk, keine Schreibrechte) → `~/Pictures/Knips` mit Hinweis.
  Schreibfehler werden gemeldet (Dialog, danach höchstens alle 10 s), nie verschluckt. JPEG über 65 535 px
  je Kante → PNG. Videos werden im Hintergrund in die Ablage kopiert.
- Scroll-Screenshots behalten nur die neuen Zeilen, höchstens 60 000 px hoch (`ScrollStitcher.maxHeight`,
  dann Hinweis in der Leiste). Bilder, die nach „Fertig“ zurückkommen, werden verworfen (Sitzungsnummer).
- Beenden während einer Aufnahme oder eines Schreibvorgangs (`QuitGuard`): Video bzw. Scroll-Screenshot wird
  gespeichert, offene Schreibvorgänge abgewartet, höchstens 10 s.

## Nutzungsstatistik (Opt-in)

Vertrag v1 (gleich für Windows und den Worker `knips.velno.ai`): `Support/Telemetry.swift`. Beim ersten Start fragt
`ConsentWindowController` — erst nach Freigabe-Fenster und Kürzel-Rückfrage, nie gleichzeitig; Schließen ohne Wahl = Nein,
beim nächsten Start erneut. Umschalten in Einstellungen → Datenschutz. Gezählt wird nur über `Telemetry.count(.ereignis)`
an den Aufrufstellen (24 erlaubte Namen in `TelemetryEvent`; `export_png/jpeg` = Speichern im Bild-Editor,
`export_mp4` = Video mit Zensur/Kürzung gespeichert, `copy_image` nur bei Bildern, `drag_out` = Ziehen beginnt), gesendet höchstens alle 24 h (Prüfung 30 s nach Start, dann
alle 6 h), 10 s Zeitlimit; Fehler → Zähler bleiben. Zustand in den UserDefaults: `telemetryConsent`, `telemetryInstallID`,
`telemetryCounts`, `telemetryLastSent` — in der Test-Sandbox in der Domäne `de.birkgroup.knips.sandbox`. Nie gefragt,
gezählt oder gesendet in Selbsttests, Sandbox (`KNIPS_TEST_DIR`) und CI. Eigene Builds (`KNIPS_DEV`) senden nur mit
`KNIPS_TELEMETRY=1` (Kanal `dev`); `KNIPS_TELEMETRY_URL` ersetzt den Endpunkt — nur in eigenen Builds, im Release wirkungslos.

## Updates (Sparkle)

Feed `https://github.com/patrickbirkholz0000/knips/releases/latest/download/appcast.xml` (`SUFeedURL`), je Release ein
eigenes `appcast.xml` (`scripts/appcast.sh`, aufgerufen von `scripts/release.sh`); Entwürfe zählen nicht als `latest`.
Jedes DMG ist EdDSA-signiert (`SUPublicEDKey`), Sparkle prüft die Signatur vor dem Entpacken
(`SUVerifyUpdateBeforeExtraction`) und danach die Code-Signatur der neuen App. Schlüssel und Release: `RELEASING.md`,
Einrichtung 5.

Ablauf (`Support/Updates.swift`): Knips plant selbst (`SUEnableAutomaticChecks` = false): erste Prüfung 5 min nach dem
Start, dann stündlich nachsehen, ob die letzte Prüfung (`SPUUpdater.lastUpdateCheckDate`) 24 h her ist. Gefunden wird
im Hintergrund geladen (`SUAutomaticallyUpdate`), geprüft und für das Beenden vorbereitet; Sparkle installiert, sobald
Knips beendet ist — `applicationShouldTerminate` wartet vorher auf `QuitGuard` (Aufnahme, Scroll-Screenshot,
Schreibvorgänge). Sofort geht es über „Neu starten und aktualisieren“ (`immediateInstallationBlock`), gesperrt solange
`QuitGuard.needsTime`, zur Sicherheit verschiebt `shouldPostponeRelaunchForUpdate` den Neustart. Einstellung
„Automatisch aktualisieren“ (`updateAutomatically`, Standard an): aus = keine Prüfung im Hintergrund, „Jetzt nach
Updates suchen“ geht weiter und lädt ein gefundenes Update gleich.

Oberfläche: Sparkles Fenster erscheinen nie. `UpdateDriver` (eigener `SPUUserDriver`) meldet jeden Schritt an
`Updates` (`UpdateState`: Suche, Laden mit Fortschritt, Prüfen, verfügbar, bereit, Installieren); angezeigt wird es auf
„Über Knips“ (Abschnitt „Updates“ mit Knopf je Zustand, Version, letzte Prüfung, Sparkle mit Lizenz) und, sobald es
etwas zu tun gibt, als leiser Hinweis im Menü-Panel über dem Fuß („Knips 1.0.2 ist bereit“, Knopf „Neu starten“).
Begründung: Knips ist eine Menüleisten-App ohne Dock-Symbol — ein aufspringendes Fenster bei einer Prüfung im
Hintergrund stört mitten in fremden Apps, und Sparkles Standardfenster passen nicht zur Markensprache. Ein eigener
Treiber für beide Wege (automatisch und von Hand) hält alles an einer Stelle und lässt sich ohne Fenster testen.

Datenschutz: Die Anfragen tragen nur `User-Agent: Knips` und `Accept-Language: *` (keine Version, keine Sprache), kein
Systemprofil, keine Cookies (`HTTPCookieStorage.shared.cookieAcceptPolicy = .never`; GitHub setzt beim Weiterleiten
welche). GitHub sieht die IP-Adresse. Sparkle merkt sich `SULastCheckTime` u. a. in den Defaults von Knips und lädt nach
`~/Library/Caches/de.birkgroup.knips/org.sparkle-project.Sparkle`.

Sperren: nie in Selbsttests, Sandbox (`KNIPS_TEST_DIR`) und CI; eigene Builds (`KNIPS_DEV`) nur mit
`KNIPS_UPDATE_FEED=<url>` (Testkanal: HTTPS oder HTTP auf 127.0.0.1/localhost), sonst ersetzte sich ein Entwickler-Build
durch das Release. Im Release wirkt `KNIPS_UPDATE_FEED` nicht. Gesperrt entsteht kein `SPUUpdater`. Für HTTP auf
diesem Mac braucht es keine ATS-Ausnahme; die Info.plist hat keine.

**Ende-zu-Ende-Test** `scripts/update-test.sh [<ausgabeordner>]` (`SKIP_BUILD=1` nimmt `build/Knips.app`, `KEEP=1` lässt
den Temp-Ordner stehen): zwei Testkopien von `build/Knips.app` in einem Temp-Ordner, alt (Build N) und neu (Build N+1),
mit der Kennung `de.birkgroup.knips.aktualisierungstest` (eigene Defaults, Caches, Installer — nie die echte App oder
`de.birkgroup.knips`) und einem Wegwerf-Schlüssel (`scripts/update-signature.swift new-key`; der echte Schlüssel bleibt
unberührt). Die neue kommt wie bei `package.sh` in ein DMG, `sign_update` signiert es, `update-signature.swift verify`
prüft gegen die alte App, `appcast.sh` schreibt die Feeds (richtig, falsch signiert, gleiche, ältere Version). Die alte
Fassung läuft mit `--selftest update <ordner> <feed>`: lokaler Server, dann Gegenproben — Einstellung aus (keine
Anfrage), gleiche und ältere Version (nichts geladen, höchstens eine Prüfung in 24 h), falsche Signatur im Hintergrund
und von Hand (geladen, abgelehnt, Hinweis in den Einstellungen) — und zuletzt das richtige Update: im Hintergrund
geladen, geprüft, bereit; Anfragen ohne Version, Sprache und Cookies. Dann beendet sie sich. Nebenher wartet
`--selftest update-installed` aus `build/Knips.app`, bis Build N+1 an derselben Stelle liegt: kein Fenster der Testkopie
oder von Sparkle während des ganzen Laufs, kein Neustart, Installer beendet, Code-Signatur streng gültig; zum Schluss
`codesign --verify --deep --strict`.

## Bedienung

Kürzel wie macOS (änderbar): ⌘⇧4 Bereich · ⌘⇧3 Vollbild · ⌘⇧5 Aufnahme starten/stoppen · ⌘⇧2 Fenster.
Kollidieren sie mit eingeschalteten macOS-Kürzeln, fragt Knips einmal beim Start, ob es sie übernehmen darf
(`SystemShortcuts.takeOver`: schreibt `com.apple.symbolichotkeys`, lädt per `activateSettings -u` neu;
rückgängig in Einstellungen → Tastaturkurzbefehle).
Festlegen in Einstellungen → Tastaturkürzel: Unter dem Kürzel steht, solange Knips wartet, „Taste oder Kombination
drücken. Esc bricht ab, ⌫ entfernt.“ Jede Taste taugt, auch allein (↖, „A“, ⇧A, F5, ⌦; `HotkeyRecorderState.outcome`),
nur Esc und ⌫ (ohne ⌘/⌥/⌃) bleiben Abbrechen und Entfernen. Carbon registriert sie mit Modifiern 0 wie jede Kombination,
und macOS gibt den Tastendruck dann nicht an die App im Vordergrund weiter. Liegt danach eine Taste zum Tippen oder
Navigieren allein auf einem Kürzel (`KeyCombo.isTypingKey`: Buchstaben, Ziffern, Zeichen, Leertaste, ↩, ⇥, ↖, ↘, ⇞, ⇟,
Pfeile, ⌦, Ziffernblock, auch mit ⇧), steht darunter als Hinweis (Info-Symbol in Königsblau, kein Fehler) „↖ wirkt jetzt
überall – in anderen Apps geht ↖ dann nicht mehr.“ Klappt die Registrierung nicht, steht dort wie bei Kombinationen
„Schon von einer anderen App belegt“.
Karten unten links: Klick irgendwo auf die Karte öffnet sie (Bild-/Video-Editor, GIF in der Standard-App), die Knöpfe
darauf haben Vorrang. Ausblenden nach frei wählbaren Sekunden (1–3600, `quickAccessAutoHide` + `quickAccessSeconds`,
alter Schlüssel `quickAccessAutoClose` wird beim Start übernommen); unter der Maus nie.
Ist die Spalte bis zur Bildschirmhöhe voll, stapeln sich neue Karten rechts daneben weiter (`QuickAccessController.grid`,
`cardOrigin`; 2048×1028-pt-Bildschirm: 6 hoch, 8 Spalten). Erst wenn auch die Breite voll ist, fällt die älteste weg.
Zensur: Standard „Balken“, Editor startet mit dem Zensur-Werkzeug. Auto-Zensur-Knopf ist standardmäßig aus.
Im Overlay: Leertaste = Fenstermodus, ⏎ = ganzer Bildschirm, Esc = Abbruch, ⇧ = Quadrat.
URL-Befehle: `knips://area|window|fullscreen|record|last|text|scroll|pin|menu|history|settings` (`App/LinkCommands.swift`).
Jede App und jede Webseite kann solche Links öffnen. Was sofort aufnimmt — `fullscreen`, `last`, `record` (nur Start) —
fragt deshalb **immer** erst nach: Fenster „Aufnahme per Link?“ (`LinkConfirmWindowController`, schwebend, Stil wie der
Zustimmungsdialog) nennt Absender und Aktion. Den Absender liest `LinkSender` aus dem Apple Event
(`keySenderAuditTokenAttr` → `SecCode` → äußerstes App-Bundle, sonst „Das Programm …“ bzw. „Eine andere App oder
Webseite“); der Name ist fälschbar und nur Information. „Aufnehmen“ (⏎) wirkt erst nach 0,6 s Schutzzeit, die bei jedem
Zeigen neu beginnt; „Abbrechen“/Esc/Schließen verwirft. Höchstens eine Rückfrage zur Zeit; weitere Links verfallen
solange, ohne das Fenster erneut nach vorn zu holen. Abschalten lässt sich die Rückfrage bewusst nicht: Eine Einstellung
läge in den UserDefaults, die jedes Programm umschreiben kann (bis 20.10.2026 `linkCaptureWithoutConfirm` — wird beim
Start gelöscht); ein Schlüsselbund-Eintrag ließe sich von fremden Programmen genauso vorab anlegen.
Per Link geöffnete Overlays (`area`, `window`, `text`, `scroll`, auch `last`/`record` nach der Rückfrage) nehmen ⏎ und
Klicks erst nach derselben Schutzzeit an (`SelectionOverlay.armed`). Per Link ausgelöste Aufnahmen (`CaptureSource.link`)
kommen nie von selbst in die Zwischenablage — kopieren geht über Karte oder Editor; per Link erfasster Text erst nach der
Rückfrage „Text kopieren?“ mit Vorschau. Direkt laufen: Stoppen einer Aufnahme und alles, was nur Oberfläche öffnet
(Overlay, Anpinnen, Menü, Verlauf, Einstellungen). `knips://pin` nimmt aus der Zwischenablage nur Bilddaten und
Bilddateien, nie http(s)-Adressen. Kürzel und Menü-Panel rufen `CaptureCoordinator` direkt auf, ohne Rückfrage.
Test-Instanz: `KNIPS_TEST_DIR=<ordner> build/Knips.app/Contents/MacOS/Knips &`, Befehle dann über
`swiftc -O scripts/test-command.swift -o .build/knips-test-command && .build/knips-test-command <befehl>`
(URL-Aufrufe landen sonst bei der installierten App). Dieser Kanal gilt als intern (ohne Rückfrage);
`link:<befehl>` verhält sich wie ein Link von außen. In der Sandbox fasst Knips die Zwischenablage nie an, nutzt die
Einstellungs-Domäne `de.birkgroup.knips.sandbox` und bietet keine Übernahme der macOS-Kürzel an.
Befehle, die das Auswahl-Overlay öffnen, nicht nebenbei testen — das Overlay erscheint auf dem Bildschirm.

## Tempo (gemessen 08.10.2026, M4, zwei 4K-Bildschirme)

- Overlay erscheint sofort als nicht-aktivierendes Panel; das Standbild (~150–260 ms) wird darunter
  aufgenommen. Knips-Fenster sind per Content-Filter ausgeschlossen, die Ziel-App bleibt aktiv.
- Nach dem Loslassen: 2 ms im Hauptthread. PNG-Kodierung, Schreiben, Vorschaubild laufen über
  `PNGPromise` im Hintergrund; die Zwischenablage liefert PNG/TIFF erst bei Anfrage.
  `CaptureStore.waitUntilWritten` vor Kopieren/Ziehen/Löschen/Öffnen.
- Texterkennung in überlappenden Kacheln je ≤ 2048 px (`TextRecognizer`, `SensitiveDetector.ocrMaxPixel`):
  4K „genau“ im Ganzen dauerte auf einem textreichen Bildschirm 35 s. Nie stärker als 0,5 verkleinert; ist
  die Schrift dann zu klein (1×-Bildschirme), zweiter Durchgang in voller Größe. Früher wurde das ganze Bild
  auf 2048 px verkleinert: 1400×14080 fand 0 von 16 E-Mails, 4K in 1× 2 von 9. Gemessen 20.10.2026
  (`--selftest ocr-bench`): 4K Retina textreich 0,17 s (vorher 0,18 s), 5K Retina textreich 0,45 s,
  1400×14080 0,27 s mit 16/16, 4K 1× 0,5–1,25 s, 4K ohne Text 0,26 s. Wörter gehören der Kachel, die
  für ihre Mitte zuständig ist; über Nähte geteilte Zeilen werden verbunden. Video: Frames sind ≤ 2048 px,
  zusätzlich unveränderte Frames überspringen (`FrameSignature`).
- `--selftest perf` misst das alles (Bildschirmfoto nur im Speicher, gibt nur Zeiten aus).

## Oberfläche

Menü-Panel (`UI/MenuPanel.swift`): dunkles Panel mit Raster.

Markensprache der App-Familie: `docs/design.md`, Werte nur aus `UI/Brand.swift`, Zeichen und
Wortmarke `UI/BrandMark.swift`. Bausteine für die Fenster in `UI/Controls.swift`: `BrandToggle` (Schalter Königsblau),
`BrandSegmented`, `BrandSelect` (Auswahlfeld, Menü unter dem Feld), `BrandButtonStyle` (.primary/.secondary/.quiet),
`BrandKeycap`/`BrandKeys` (Tastenkappen, Sondertasten als SF Symbol), `KeyCombo.inlineText` (Kürzel im Fließtext),
`BrandCard`/`BrandSection`/`BrandRow`/`BrandRowDivider`, `BrandStatusIcon` (erledigt/fehlt/freiwillig),
`BrandStatusDot`, `BrandIconTile`, `BrandOverline`, `BrandLink`, `BrandDialogWindow`/`BrandDialog`/`BrandDialogPoint`.
Das alte `Theme` und `PillButtonStyle` liegen unverändert in `UI/LegacyTheme.swift`, nur für noch nicht umgestellte Ansichten.

Einstellungen (`App/SettingsWindow.swift`): dunkle Seitenleiste über die volle Höhe (Zeichen + Wortmarke, Gruppen
START · AUFNAHME · BEARBEITEN · APP, gewählter Eintrag gehoben mit Pfeil, unten „Bereit“ bzw. „N Schritte offen“ und
die Version in Mono), rechts Papier mit Seitentitel, Abschnitten und weißen Karten. Erste Seite **Start** („So geht's“):
Kürzel als Tastenkappen, drei Schritte, Bereit-Check (`App/Readiness.swift`): Bildschirmaufnahme-Freigabe, Mikrofon
(freiwillig, zählt nur bei „Mikrofon aufnehmen“), Kürzel registriert und nicht von macOS belegt, Ablageordner erreichbar.
Geprüft beim Öffnen, sobald das Fenster aktiv wird, und alle 2 s auf Start und Datenschutz. Öffnen ohne Bereich zeigt Start,
solange etwas fehlt. **Darstellung** (Allgemein): `appearance` = system/light/dark → `NSApp.appearance` beim Start und
sofort bei Änderung; die Fenster setzen keine eigene Darstellung. Seitenleiste, Menü-Panel und Pillen bleiben dunkel.
**In Bildschirmübertragungen verbergen** (Datenschutz, `hideFromScreenSharing`, Standard aus): `ScreenSharing` in
`Support/Settings.swift` setzt `sharingType = .none` für alle Knips-Fenster — beim Anlegen (`ScreenSharing.apply(to:)`
an jeder Fenster-Fabrik), beim Umschalten für alle offenen, und als Auffangnetz beim Erscheinen/Aktivieren
(`ScreenSharing.start`). Aus: `.readOnly`, andere Apps (Teams, Zoom, Discord) sehen Knips wie jedes Fenster. Knips' eigene
Standbilder und Videos lassen Knips-Fenster immer weg (Content-Filter). Selbsttest `settings`: ScreenCaptureKit liefert
ein Knips-Fenster mit der Einstellung leer (gemessen 21.10.2026).

Verlauf (`UI/HistoryWindow.swift`): Kopf mit Titel und Anzahl, Filter als Segment-Schalter, Karten mit Meta in Mono,
Maus darüber: Königsblau-Linie und kleine dunkle Knöpfe. Dialoge (Zustimmung, „Aufnahme per Link?“, „Text kopieren?“,
Freigabe, „Kürzel für Knips übernehmen?“) sind `BrandDialogWindow`: randlose Karte mit Radius 22,
Esc und ⌘W schließen. Die Link-Rückfrage zeigt ihre Schutzzeit (Primärknopf blass,
Fortschritt darunter). Die Kürzel-Übernahme ist modal (`NSApp.runModal`) wie früher der NSAlert, ⏎ = Übernehmen.

## Nicht automatisch prüfbar

Am Gerät testen: Maus-Hover auf den Karten (Klicks prüft `cards`), Ziehen aus den Karten in andere Apps,
das interaktive Auswahl-Overlay, Mikrofon-Aufnahme. Außerdem: Bildschirm ab-/anstecken (Karten ziehen um,
Overlay bricht ab, Scroll-Leiste beendet mit Speichern), volle Platte während einer echten Aufnahme
(Writer-Fehler → Abbruch mit Meldung), Beenden über das Menü während einer echten Aufnahme.
Editoren: Hover auf Werkzeugen und Knöpfen, Fenster ziehen an freier Stelle der oberen Leiste, Vollbild (die leere
`NSToolbar`, die die Ampel-Knöpfe mittig neben die Leiste setzt, wird dort ausgeblendet).
Updates: „Neu starten und aktualisieren“ mit echtem Neustart (der Ende-zu-Ende-Test installiert beim Beenden, ein
Neustart öffnete die Testkopie sichtbar), und ein echtes Update über GitHub nach dem ersten Release mit Updater.
