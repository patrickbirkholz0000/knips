# Knips

Screenshots und Bildschirmvideos für macOS und Windows, mit Zensur für Bilder **und** Videos.
Kostenlos, quelloffen (GPL-3.0), ohne Konto. Alles läuft auf deinem Rechner.

![Der Bild-Editor von Knips unter macOS: Telefonnummer, Teil der IBAN und ein API-Schlüssel sind mit schwarzen Balken zensiert](windows/tests/reference/mac-ui/live/live-editor-schlaue-balken.png)

- **macOS:** native Menüleisten-App in Swift (ScreenCaptureKit, Vision), ab macOS 14.
- **Windows:** dieselbe App mit Tauri 2, Rust und React, für Windows 10 und 11.

Die Oberfläche ist auf Deutsch. [English version below](#english).

## Funktionen

**Aufnehmen**

- Bereich, Fenster oder ganzer Bildschirm. Die Auswahl läuft auf dem eingefrorenen Bildschirm, mit Lupe.
- Letzten Bereich wiederholen, Text aus einem Bereich erfassen (Texterkennung auf dem Gerät).
- Scroll-Screenshots: Bereich wählen, scrollen, Knips setzt die Ausschnitte pixelgenau zusammen.
- Bildschirmvideo als MP4: 30 oder 60 fps, Countdown, Mauszeiger, Klicks hervorheben, optional
  Kommentar über das Mikrofon. Standardmäßig in Bildschirmgröße, auf Wunsch HEVC. Auf dem Mac brauchen
  Klick-Hervorhebung und Mikrofon macOS 15.
- Bild aus der Zwischenablage als schwebendes Fenster anpinnen, Bilddateien im Editor öffnen.

**Nach der Aufnahme**

- Karten unten links: Klick öffnet den Editor. Knöpfe zum Kopieren, Anpinnen, Text kopieren, im
  Finder bzw. Explorer zeigen und Löschen. Karten lassen sich in andere Apps ziehen und blenden auf
  Wunsch nach einer frei wählbaren Zeit aus.
- Verlauf aller Aufnahmen mit Filter nach Bildern, Videos und GIFs.

**Bild-Editor**

- Pfeil, Rechteck, Ellipse, Linie, Text, Nummerierung, Markieren, Zuschneiden, Zoom.
- Hintergrund und Rahmen: Farbverlauf, Abstand, abgerundete Ecken, Schatten.
- Zensur als Balken (Standard), Verpixeln oder Unschärfe. Ein Klick auf Text legt den Balken über die
  Zeile, mit ⌥ bzw. Alt nur über das Wort.
- Auto-Zensur (in den Einstellungen einschaltbar): findet E-Mail-Adressen, IBANs, Telefonnummern,
  Kartennummern, API-Schlüssel und IP-Adressen per Texterkennung.
- „Text kopieren“ lässt zensierte Wörter weg.

**Video-Editor**

- Kürzen, Zensurfelder mit eigenem Zeitbereich, Auto-Zensur.
- Zensurbalken, die bewegtem Inhalt folgen, zum Beispiel beim Scrollen.
- Export als MP4 oder GIF.

**Ablage**

- Gespeichert und geteilt wird immer die gerenderte, also bereits zensierte Fassung. Kopieren und
  Herausziehen geben nie das Original weiter.
- Das Original bleibt mit dem Bearbeitungsstand getrennt erhalten (Standard: 30 Tage), damit sich eine
  Zensur später noch ändern lässt.
- PNG oder JPEG, standardmäßig in Bildschirmgröße (1×), auf Wunsch in voller Auflösung.

## Download & Installation

Fertige Pakete gibt es unter [Releases](https://github.com/patrickbirkholz0000/knips/releases/latest).

### macOS

Voraussetzung: macOS 14 (Sonoma) oder neuer, Apple Silicon oder Intel.

1. `Knips-….dmg` laden, öffnen und Knips in den Ordner „Programme“ ziehen.
2. Knips starten. Es erscheint als Symbol in der Menüleiste, nicht im Dock.
3. **Bildschirmaufnahme erlauben:** Knips zeigt beim ersten Start, wie es geht. Der Schalter liegt unter
   Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme. Danach Knips
   einmal neu starten.
4. **Mikrofon** fragt macOS erst, wenn du Videos mit Kommentar aufnimmst (ab macOS 15).
5. Knips fragt beim Start, ob es die macOS-Kürzel ⇧⌘3, ⇧⌘4 und ⇧⌘5 übernehmen darf. Rückgängig unter
   Einstellungen → Tastaturkürzel → „macOS-Kürzel wiederherstellen“.

### Windows

Voraussetzung: Windows 10 oder 11, 64 Bit. Knips installiert sich nur für deinen Benutzer und braucht
keine Administratorrechte. Fehlt die Microsoft-WebView2-Laufzeit (unter Windows 11 vorinstalliert), lädt
der Installer sie von Microsoft nach. Drei Wege, alle mit demselben Installer:

1. **winget** (sobald Knips im Windows-Paketmanager aufgenommen ist):

   ```
   winget install PatrickBirkholz.Knips
   ```

2. **PowerShell:**

   ```
   irm https://knips.velno.ai/install.ps1 | iex
   ```

   Das Skript holt den Installer der neuesten Version von der Releases-Seite, prüft seine
   SHA-256-Prüfsumme und, sobald die Installer signiert sind, die Signatur, installiert ohne Rückfragen und
   startet Knips. Die heruntergeladene Datei löscht es danach wieder. Eine SmartScreen-Warnung erscheint
   dabei nicht, weil die Datei nicht über den Browser kommt. Sieh dir das Skript vorher an:
   [windows/install.ps1](windows/install.ps1), oder öffne <https://knips.velno.ai/install.ps1> im Browser
   (dieselbe Datei). Eine bestimmte Version:
   `& ([scriptblock]::Create((irm https://knips.velno.ai/install.ps1))) -Version 1.0.0`.

3. **Installer von der Releases-Seite:** `Knips_…_x64-setup.exe` laden und ausführen. Solange der
   Installer nicht signiert ist, meldet SmartScreen „Der Computer wurde durch Windows geschützt“. Dann auf
   „Weitere Informationen“ und „Trotzdem ausführen“ klicken. Lade den Installer nur von der Releases-Seite
   dieses Repos. `Get-FileHash .\Knips_…_x64-setup.exe` muss den Wert aus der `.sha256`-Datei daneben
   ergeben.

Danach:

- Knips liegt im Infobereich der Taskleiste.
- Unter Windows 11 öffnet die Druck-Taste den Bildschirmausschnitt. Knips fragt beim ersten Start, ob es
  die Taste übernehmen darf. Zurückgeben lässt sie sich unter Einstellungen → Tastaturkürzel.
- **Deinstallieren:** Einstellungen → Apps → Installierte Apps → Knips → Deinstallieren (oder
  `winget uninstall PatrickBirkholz.Knips`).

## Kurzbefehle

| Aktion | macOS | Windows |
|---|---|---|
| Bereich aufnehmen | ⇧⌘4 | Druck |
| Fenster aufnehmen | ⇧⌘2 | Alt+Druck |
| Ganzer Bildschirm | ⇧⌘3 | Strg+Druck |
| Bildschirmvideo starten/stoppen | ⇧⌘5 | Umschalt+Druck |

Alle Kürzel lassen sich in den Einstellungen ändern. Letzter Bereich, Text erfassen, Scroll-Screenshot
und Anpinnen haben kein Standardkürzel, lassen sich aber belegen. Unter Windows setzt der Knopf
„Mac-Belegung“ die Kürzel auf Win+Umschalt+4/2/3/5.

**Bei der Auswahl:** Leertaste wechselt in den Fenstermodus, ⏎ bzw. Eingabe nimmt den ganzen
Bildschirm, Esc bricht ab, ⇧ bzw. Umschalt zieht ein Quadrat.

**Im Editor:** V Auswählen, A Pfeil, R Rechteck, O Ellipse, L Linie, T Text, N Nummerierung,
H Markieren, X Zensieren, C Zuschneiden. Zoom mit ⌘+ / ⌘− / ⌘0 / ⌘1 (Windows: Strg).

## Datenschutz

Knips arbeitet vollständig auf deinem Rechner. Es gibt kein Konto, keine Cloud und keinen Upload.
Screenshots, Videos und die Texterkennung (macOS: Vision, Windows: Windows.Media.Ocr) bleiben auf dem
Gerät.

| | macOS | Windows |
|---|---|---|
| Fertige Dateien, immer zensiert (Ordner einstellbar) | `~/Pictures/Knips` | `Bilder\Knips` |
| Originale und Bearbeitungsstand (Standard: 30 Tage) | `~/Library/Application Support/Knips/items/` | `%LOCALAPPDATA%\Knips\items\` |
| Einstellungen | Benutzereinstellungen `de.birkgroup.knips` | `%APPDATA%\Knips\settings.json` |

### Anonyme Nutzungsstatistik (freiwillig)

Das ist die einzige Verbindung ins Internet, die Knips selbst aufbaut, und sie ist aus, bis du zustimmst.
Beim ersten Start fragt Knips einmal („Knips verbessern?“). Schließt du die Frage ohne Antwort, gilt das
als Nein, und Knips fragt beim nächsten Start noch einmal. Ändern kannst du die Wahl jederzeit in den
Einstellungen unter „Anonyme Nutzungsstatistik“.

Mit Zustimmung sendet Knips höchstens einmal am Tag eine kleine Nachricht an
`https://knips.velno.ai/v1/ping`. Sie enthält genau diese Felder:

| Feld | Beispiel | Bedeutung |
|---|---|---|
| `v` | `1` | Version des Formats |
| `app` | `knips` | immer gleich |
| `platform` | `macos` | `macos` oder `windows` |
| `channel` | `release` | `release`, bei Entwickler-Builds `dev` |
| `app_version`, `build` | `1.3.0`, `57` | Version von Knips |
| `os_version` | `15.1` | Version des Betriebssystems |
| `arch` | `arm64` | `arm64` oder `x86_64` |
| `lang` | `de` | Sprache, nur zwei Buchstaben |
| `install_id` | zufällige UUID | entsteht bei der Zustimmung, wird beim Widerruf gelöscht |
| `events` | `{"capture_area": 3}` | Zähler seit der letzten Nachricht |

Gezählt werden nur Aktionen, die du ausgeführt hast. Der Server verwirft alle anderen Namen:
`app_launch`, `capture_area`, `capture_window`, `capture_fullscreen`, `capture_last_area`,
`capture_scroll`, `capture_text`, `recording_start`, `recording_saved`, `editor_open`,
`video_editor_open`, `censor_manual`, `censor_auto`, `censor_smart`, `export_png`, `export_jpeg`,
`export_mp4`, `export_gif`, `copy_image`, `copy_text`, `pin`, `drag_out`, `history_open`,
`settings_open`.

**Nie gesendet** werden Bilder, Videos, Texte (auch kein erkannter Text), Dateinamen, Fenstertitel oder
Fensterinhalte, App-Namen, Bildschirmgrößen und Zeitmessungen.

**Auf dem Server** (Cloudflare Worker mit D1-Datenbank):

- Der Server läuft bei Cloudflare. Als Hoster verarbeitet Cloudflare technisch die Verbindungsdaten, also
  auch die IP-Adresse. Der Worker selbst speichert weder IP-Adresse noch User-Agent; gegen zu viele
  Anfragen dient die IP-Adresse nur kurz als Schlüssel in einem flüchtigen Zähler von Cloudflare.
  Gespeichert wird nur das Land als Kürzel aus zwei Buchstaben, das Cloudflare aus der Verbindung ableitet.
- Die `install_id` wird nie im Klartext gespeichert, nur als gesalzener Hash (SHA-256 mit geheimem Salz,
  gekürzt).
- Pro Tag und Installation gibt es eine Zeile mit Plattform, Kanal, Version, Betriebssystem,
  Architektur, Sprache, Land und den Zählern. Zeilen, die älter als 400 Tage sind, werden automatisch
  gelöscht.
- Widerrufst du, löscht Knips sofort die ID und alle noch nicht gesendeten Zähler. Bereits gesendete
  Tageszeilen laufen nach 400 Tagen aus.

Selbsttests, die Test-Sandbox und die CI senden nie. Entwickler-Builds senden nur, wenn
`KNIPS_TELEMETRY=1` gesetzt ist, und dann als `dev`. Der Server-Code liegt in diesem Repo:
[telemetry/README.md](telemetry/README.md).

Der Windows-Installer zeigt diesen Hinweis während der Installation, vor dem Lizenztext.

## Code signing policy

Die Windows-Fassung (App und Installer) wird über SignPath signiert, sobald Knips in das
Open-Source-Programm der SignPath Foundation aufgenommen ist. Die Aufnahme ist beantragt, bis dahin sind
die Installer unsigniert. Ab dann gilt:

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/).

- **Was signiert wird:** nur Dateien, die GitHub Actions aus dem Quellcode dieses Repos baut
  ([.github/workflows/release.yml](.github/workflows/release.yml)), also `knips.exe` und
  `Knips_X.Y.Z_x64-setup.exe`. Fremde Dateien im Installer (die Plugins des Installationsprogramms NSIS)
  werden nicht mit diesem Zertifikat signiert.
- **Freigabe:** Jede Signatur gibt der Approver in SignPath einzeln frei.
- **Rollen:**
  - Committer und Reviewer: [Patrick Birkholz](https://github.com/patrickbirkholz0000)
  - Approver: [Patrick Birkholz](https://github.com/patrickbirkholz0000)

  Änderungen von anderen (Pull Requests) prüft ein Reviewer, bevor sie übernommen werden.
- **Datenschutz:** siehe [Datenschutz](#datenschutz). Knips sendet nur nach ausdrücklicher Zustimmung eine
  anonyme Nutzungsstatistik, lässt sie jederzeit abschalten und zeigt den Hinweis schon im Installer.

## Selbst bauen

- **macOS:** `scripts/build.sh` baut `build/Knips.app`, `scripts/install.sh` installiert und startet sie.
- **Windows:** im Ordner `windows/` mit `pnpm install` und `pnpm tauri build`.

Voraussetzungen, Selbsttests und Regeln für Beiträge stehen in [CONTRIBUTING.md](CONTRIBUTING.md).
Sicherheitslücken bitte vertraulich melden, siehe [SECURITY.md](SECURITY.md).

## Lizenz

© 2026 Patrick Birkholz. Knips ist freie Software: Du kannst es unter den Bedingungen der GNU General
Public License, Version 3 oder (nach deiner Wahl) jeder späteren Version, weitergeben und verändern.
Knips wird ohne jede Gewährleistung bereitgestellt. Der vollständige Text steht in [LICENSE](LICENSE).

---

## English

Knips takes screenshots and screen recordings on macOS and Windows and lets you censor them, in images
**and** videos. Free, open source (GPL-3.0), no account, everything stays on your computer. The macOS
version is a native Swift menu-bar app (macOS 14+); the Windows version is built with Tauri 2, Rust and
React (Windows 10 and 11). The user interface is in German.

### Features

- Capture an area, a window or the whole screen on a frozen screen with a magnifier; repeat the last
  area, grab text from an area, scrolling screenshots.
- Screen recording to MP4 (30 or 60 fps, countdown, cursor, click highlights, optional microphone;
  on the Mac, click highlights and microphone need macOS 15).
- Cards in the bottom-left corner to open, copy, pin, drag out or delete a capture; history window.
- Image editor: arrow, rectangle, ellipse, line, text, numbering, highlighter, crop, zoom, background
  frame. Censoring with solid bars (default), pixelation or blur; click on text to cover the line.
  Optional auto-censoring of e-mail addresses, IBANs, phone numbers, card numbers, API keys and IP
  addresses via on-device text recognition.
- Video editor: trim, censor boxes with their own time range, boxes that follow moving content,
  auto-censoring, export as MP4 or GIF.
- Saved and shared files are always the censored version; the original is kept separately (30 days by
  default) so you can change the censoring later.

### Download & installation

Get the packages from [Releases](https://github.com/patrickbirkholz0000/knips/releases/latest).

- **macOS 14+:** open the DMG, drag Knips into Applications, start it and allow screen recording under
  System Settings → Privacy & Security → Screen & System Audio Recording, then restart Knips. The
  microphone is only requested when you record with commentary (macOS 15+).
- **Windows 10/11 (64-bit),** per-user install without admin rights, three ways with the same installer:
  1. **winget** (once Knips is accepted into the Windows Package Manager):
     `winget install PatrickBirkholz.Knips`
  2. **PowerShell:** `irm https://knips.velno.ai/install.ps1 | iex` downloads the latest installer from
     the Releases page, verifies its SHA-256 checksum (and its signature once installers are signed),
     installs silently, starts Knips and deletes the download. No SmartScreen prompt, because the file does
     not come through the browser. Read the script first: [windows/install.ps1](windows/install.ps1) or
     open <https://knips.velno.ai/install.ps1> in your browser (same file). A specific version:
     `& ([scriptblock]::Create((irm https://knips.velno.ai/install.ps1))) -Version 1.0.0`.
  3. **Installer from the Releases page:** run `Knips_…_x64-setup.exe`. While the installer is unsigned,
     SmartScreen shows “Windows protected your PC”: click “More info”, then “Run anyway”. Only download the
     installer from this repo's Releases page.

  Uninstall: Settings → Apps → Installed apps → Knips → Uninstall (or `winget uninstall PatrickBirkholz.Knips`).

Default shortcuts: area ⇧⌘4 / Print, window ⇧⌘2 / Alt+Print, full screen ⇧⌘3 / Ctrl+Print, start/stop
recording ⇧⌘5 / Shift+Print. All shortcuts can be changed in the settings.

### Privacy

Everything runs locally. The only network traffic Knips creates is the optional anonymous usage
statistics. Knips asks once on first launch; nothing is sent unless you agree, and you can change it
any time in the settings („Anonyme Nutzungsstatistik“). With consent, Knips sends at most once a day the
fields listed in the table [above](#datenschutz) to `https://knips.velno.ai/v1/ping`: format version,
platform, channel, app version and build, OS version, architecture, two-letter language, a random
install ID and counters for the listed events.

Never sent: images, videos, text (including recognized text), file names, window titles or contents,
app names, screen sizes, timing data. The server runs on Cloudflare, which as the host technically
processes connection data including the IP address. The server itself does not store IP addresses or
user agents (only a two-letter country code derived by Cloudflare; for rate limiting the IP address is
only a short-lived key in a Cloudflare counter), stores the install ID only as a salted hash, and deletes
rows after 400 days. Opting out deletes the install ID and any unsent counters immediately. The Windows
installer shows this notice during installation. Server code: [telemetry/README.md](telemetry/README.md).

### Code signing policy

The Windows version (app and installer) will be signed through SignPath once Knips is accepted into the
SignPath Foundation's open source program (applied for; until then the installers are unsigned). From
then on:

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by
[SignPath Foundation](https://signpath.org/).

- Only files built by GitHub Actions from the source code in this repository
  ([.github/workflows/release.yml](.github/workflows/release.yml)) are signed: `knips.exe` and
  `Knips_X.Y.Z_x64-setup.exe`. Third-party files inside the installer (the NSIS installer plugins) are not
  signed with this certificate.
- Every signing request is approved manually by the approver in SignPath.
- Committers and reviewers: [Patrick Birkholz](https://github.com/patrickbirkholz0000). Approvers:
  [Patrick Birkholz](https://github.com/patrickbirkholz0000). Changes from others (pull requests) are
  reviewed before they are merged.
- Privacy: see [Privacy](#privacy). Knips only sends anonymous usage statistics after explicit consent,
  lets you turn them off at any time and shows the notice in the installer.

### Building

macOS: `scripts/build.sh`. Windows: `pnpm install` and `pnpm tauri build` in `windows/`. Details in
[CONTRIBUTING.md](CONTRIBUTING.md); security issues: [SECURITY.md](SECURITY.md).

### License

© 2026 Patrick Birkholz. Knips is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. Knips is distributed without any warranty. See
[LICENSE](LICENSE).
