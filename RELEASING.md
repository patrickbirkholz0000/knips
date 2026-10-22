# Knips veröffentlichen

Ein Release besteht aus einem GitHub-Release in diesem Repo (`patrickbirkholz0000/knips`) mit diesen Dateien:

| Datei | kommt von | Signatur |
|---|---|---|
| `Knips-X.Y.Z-<build>.dmg` + `.sha256` | `scripts/release.sh` auf dem Mac (über `scripts/package.sh`) | Developer ID, von Apple notarisiert, Ticket gestapelt |
| `appcast.xml` | `scripts/release.sh` (über `scripts/appcast.sh`) | enthält die EdDSA-Signatur des DMG für die automatischen Updates (Sparkle) |
| `Knips_X.Y.Z_x64-setup.exe` + `.sha256` | `.github/workflows/release.yml` auf Windows-Runnern | SignPath (Zertifikat der SignPath Foundation), falls eingerichtet, sonst unsigniert |
| `latest.json` | `.github/workflows/release.yml`, Job `updater` | enthält die Updater-Signatur (Minisign) über genau diesen Installer, siehe [Automatische Updates (Windows)](#5-automatische-updates-windows) |

Maßgeblich ist das Tag `vX.Y.Z`. `build.sh` liest es per `git describe` (ohne Tag gilt
`CFBundleShortVersionString` aus `Resources/Info.plist`), der Workflow schreibt es beim Bauen in
`windows/package.json`, `windows/Cargo.toml` und `windows/src-tauri/tauri.conf.json` (nicht eingecheckt).
Eingecheckt steht dort die aktuelle Version, derzeit `1.0.1`; bei einer neuen Version am besten mit anheben
(`Cargo.lock` folgt über `cargo check`). Die Build-Nummer ist auf beiden Systemen die Zahl der Commits bis zum
Tag (`git rev-list --count HEAD`): `build.sh` schreibt sie als `CFBundleVersion`, der Workflow gibt sie dem
Windows-Build als `KNIPS_BUILD` mit (Nutzungsstatistik).

## Signatur-Identitäten auf dem Mac

| Build | Identität | Bildschirmaufnahme-Freigabe |
|---|---|---|
| `scripts/build.sh`, `scripts/install.sh` (eigene Builds) | letzte „Apple Development“ der Liste, wie bisher | bleibt über Updates erhalten |
| `RELEASE=1`, `scripts/package.sh`, `scripts/release.sh` | erste „Developer ID Application“ | eigene Freigabe (anderer Designated Requirement) |

`KNIPS_SIGN_IDENTITY` (SHA-1 oder exakter Name) übersteuert beides. Signiert wird immer per SHA-1, mit
Hardened Runtime, `Resources/Knips.entitlements` und Kennung `de.birkgroup.knips`. Developer ID bekommt
immer einen sicheren Zeitstempel (braucht Netz), Apple Development keinen (`KNIPS_TIMESTAMP=1` erzwingt ihn).
Das eingebettete `Sparkle.framework` (automatische Updates) signiert `build.sh` vorher mit derselben Identität,
von innen nach außen und ohne `--deep`: `Autoupdate`, `Updater.app`, das Framework, dann die App — jeweils mit
Hardened Runtime und Zeitstempel, ohne die Entitlements von Knips. Die XPC-Dienste von Sparkle braucht Knips
nicht (nicht sandboxed) und lässt sie weg. `package.sh` prüft das vor der Notarisierung.

Wer das Release-DMG auf dem eigenen Mac installiert, erteilt die Freigabe für diese Fassung einmal neu. Ein
späteres `install.sh` wechselt wieder auf Apple Development und braucht dann wieder die alte Freigabe.

## Einmalige Einrichtung

### 1. Developer-ID-Zertifikat (erledigt am 20.10.2026)

Im Schlüsselbund liegt `Developer ID Application: Birkholz & Rabitzsch GbR (S8QR9YWZS7)`,
SHA-1 `CE1984921935D592338A9853BE651CE2AFA58AE8`, ausgestellt von der **Developer ID Certification
Authority G1**, gültig bis **01.02.2027**. Prüfen:

```
security find-identity -v -p codesigning
```

- **Privaten Schlüssel sichern.** Er liegt nur im Anmelde-Schlüsselbund dieses Macs. Schlüsselbundverwaltung
  → Meine Zertifikate → Rechtsklick auf das Zertifikat → Exportieren → `.p12` mit Passwort, sicher ablegen.
  Ohne den Schlüssel muss ein neues Zertifikat her (Apple erlaubt nur wenige gleichzeitig).
- **Ablauf am 01.02.2027.** Bereits veröffentlichte Releases bleiben gültig, weil sie einen Zeitstempel
  tragen. Für neue Releases danach ein neues Zertifikat anlegen, dann mit der G2-Zwischenstelle:
  developer.apple.com → Certificates, Identifiers & Profiles → Certificates → „+“ →
  „Developer ID Application“ → **G2 Sub-CA** → CSR aus der Schlüsselbundverwaltung hochladen
  (Zertifikatsassistent → Zertifikat einer Zertifizierungsinstanz anfordern → „Auf der Festplatte sichern“).
  Das G2-Zwischenzertifikat ist auf diesem Mac schon installiert.
- Anlegen darf das nur der **Account Holder** des Teams. Alternativ in Xcode: Settings… → Accounts → Team
  „Birkholz & Rabitzsch GbR“ → Manage Certificates… → „+“ → „Developer ID Application“.

Beim ersten Signieren fragt macOS, ob `codesign` den Schlüssel benutzen darf: „Immer erlauben“.

### 2. Zugang für die Notarisierung (offen)

`notarytool` liest Zugangsdaten aus einem Schlüsselbund-Profil, Name `knips`
(anderer Name: `KNIPS_NOTARY_PROFILE=<name>`).

**Variante A, API-Schlüssel (empfohlen, hängt an keiner Person):** App Store Connect → Benutzer und Zugriff
→ Integrationen → App Store Connect API → Team-Schlüssel → „+“, Zugriff „Developer“. Die `.p8`-Datei lässt
sich nur einmal herunterladen. Key-ID und Issuer-ID stehen auf derselben Seite.

```
xcrun notarytool store-credentials knips \
  --key ~/Pfad/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
```

**Variante B, Apple-ID:** auf account.apple.com unter „Anmelden und Sicherheit“ → „App-spezifische
Passwörter“ eines anlegen, dann:

```
xcrun notarytool store-credentials knips --apple-id kontakt@birkgroup.de --team-id S8QR9YWZS7
```

Prüfen (muss ohne Fehler eine, gegebenenfalls leere, Liste zeigen):

```
xcrun notarytool history --keychain-profile knips
```

### 3. GitHub CLI

`gh auth status` muss ein Konto mit Schreibrechten auf `patrickbirkholz0000/knips` zeigen
(sonst `gh auth login`). Der Workflow selbst braucht nichts, er nimmt das `GITHUB_TOKEN`.

### 4. Windows signieren über SignPath (Open-Source-Programm der SignPath Foundation)

Ohne Signatur warnt SmartScreen beim Ausführen eines heruntergeladenen Installers („Der Computer wurde
durch Windows geschützt“), und Smart App Control unter Windows 11 kann unsignierte Programme ganz blockieren.
Die SignPath Foundation signiert Open-Source-Projekte kostenlos: Das Zertifikat lautet auf „SignPath
Foundation“ (nicht auf uns), der Schlüssel liegt in SignPaths HSM, und SignPath signiert nur Dateien, die
nachweislich GitHub Actions aus diesem Repo gebaut hat. Bedingungen: <https://signpath.org/terms>.

**So läuft es in `release.yml`:** Der Job `windows` baut App und Installer ohne jeden Signatur-Zugang.
`sign-app` schickt `knips.exe` an SignPath und wartet auf die Freigabe. `bundle` baut den Installer neu um die
signierte EXE (SignPath kann NSIS-Installer nicht von innen signieren; `tauri bundle --no-binary-patching`,
sonst ändert Tauri die EXE und zerstört die Signatur). `sign-installer` lässt den Installer signieren (zweite
Freigabe), `publish` prüft beides mit `Get-AuthenticodeSignature` (auch die EXE im Installer, per 7-Zip
ausgepackt), rechnet die Prüfsumme und hängt die Dateien an das Release. Der SignPath-Token steht nur in den
beiden Signier-Jobs, die nichts auschecken und nichts bauen. Ist `SIGNPATH_API_TOKEN` oder
`SIGNPATH_ORGANIZATION_ID` nicht gesetzt, läuft alles wie bisher unsigniert. Den Ablauf mit einem
Wegwerf-Zertifikat statt SignPath prüft bei jedem Lauf der Job `signatur` in `windows.yml`.

Nicht signiert werden die NSIS-Plugins im Installer (fremder Code, darf nicht unter dem Foundation-Zertifikat
laufen) und der Deinstaller `uninstall.exe`, den NSIS erst beim Bauen erzeugt (Tauri kann ihn nur über einen
synchronen Signierbefehl signieren, und der würde auch die fremden Plugins signieren).

**Vor dem Antrag** (SignPath prüft die Seite beim Antrag):

- Version 1.0.0 ist veröffentlicht, mit Windows-Installer (Bedingung „bereits in der zu signierenden Form
  veröffentlicht“).
- README: Abschnitt „Code signing policy“ mit dem Satz „Free code signing provided by SignPath.io,
  certificate by SignPath Foundation“, Rollen und Datenschutz-Verweis (ist drin). Der Release-Text verlinkt
  ihn (`scripts/release.sh`).
- Der Installer zeigt den Datenschutzhinweis vor der Lizenz (`windows/installer/datenschutz-und-lizenz.txt`).
- Zwei-Faktor-Anmeldung bei GitHub ist an (verlangt für alle Beteiligten, später auch bei SignPath).

**Einrichten:**

1. **Antrag** unter <https://signpath.org/apply>: Projekt Knips, Repo
   `https://github.com/patrickbirkholz0000/knips`, Lizenz GPL-3.0-or-later, Download-Seite = Releases,
   Build-System GitHub Actions, kurze Beschreibung. SignPath meldet sich per E-Mail und lädt in eine
   Organisation auf <https://app.signpath.io> ein. Einladung annehmen, Zwei-Faktor-Anmeldung einrichten.
2. **Organisations-ID** steht unter Organization → Settings (eine GUID).
3. **Projekt** `knips` (Slug): legt SignPath bei Foundation-Projekten meist selbst an, sonst Projects → Add.
   Anderer Slug → Variable `SIGNPATH_PROJECT_SLUG`.
4. **GitHub als Trusted Build System:** Organization → Trusted Build Systems → „Add predefined“ → GitHub.com,
   dann im Projekt unter Trusted Build Systems verknüpfen. Als Quellcode-Repository des Projekts
   `https://github.com/patrickbirkholz0000/knips` eintragen.
5. **Artefakt-Konfigurationen** im Projekt anlegen, Typ „Custom“, Slugs genau `knips-exe` und
   `knips-installer`, Inhalt aus `.signpath/artifact-configurations/knips-exe.xml` bzw. `knips-installer.xml`
   einfügen. Sie prüfen ProductName „Knips“ und die Version (Parameter `version` aus dem Workflow), wie es die
   Foundation verlangt. Ändert sich eine der Dateien im Repo, dort ebenfalls ersetzen.
6. **Signing Policies:** `test-signing` (Testzertifikat, sofort nutzbar) und `release-signing` (das echte
   Zertifikat; steht auf „CSR pending“, bis SignPath es nach einem erfolgreichen Testlauf einspielt). Bei
   beiden: Approver = Patrick Birkholz, Freigabe erforderlich. Gibt es Pipeline-Richtlinien, für GitHub
   `runners.required_github_hosted: true` setzen.
7. **CI-Zugang:** Users → einen CI-Benutzer anlegen (z. B. `github-actions`), bei beiden Richtlinien als
   Submitter eintragen und für ihn einen API-Token erzeugen (wird nur einmal angezeigt).
8. **GitHub-Secret und -Variablen:**

   ```
   gh secret set SIGNPATH_API_TOKEN                                   # Token aus Schritt 7
   gh variable set SIGNPATH_ORGANIZATION_ID --body <GUID>             # aus Schritt 2
   gh variable set SIGNPATH_SIGNING_POLICY_SLUG --body test-signing   # erst der Probelauf
   ```

9. **Probelauf** mit dem Testzertifikat: Der Lauf nimmt `release.yml` aus dem Tag, also ein Tag, das schon
   diesen Workflow enthält (v1.0.0 hat noch den alten), und muss auf dem Tag selbst laufen:

   ```
   gh workflow run release.yml --ref v1.0.1 -f tag=v1.0.1
   ```

   Mit `test-signing` signiert er, gibt sich mit der nicht vertrauten Test-Wurzel zufrieden und hängt nichts
   an das Release; das Ergebnis liegt im Artefakt `knips-windows-<version>` des Laufs.
10. **Echtes Zertifikat:** Sobald SignPath `release-signing` freigeschaltet hat (nach dem Probelauf bei
    SignPath nachfragen, falls es auf „CSR pending“ bleibt):
    `gh variable delete SIGNPATH_SIGNING_POLICY_SLUG` (Standard ist `release-signing`). Ab dann ist jedes
    Release signiert.

**Ein Release mit Freigabe:** `scripts/release.sh X.Y.Z` wie immer. Nach dem Bauen (20–30 Minuten) schickt
SignPath eine E-Mail: Signieranfrage für `knips.exe`. Auf app.signpath.io → Signing Requests die Anfrage
öffnen, Herkunft prüfen (Repo, Tag, Commit, Workflow-Lauf) und „Approve“ klicken. Ein paar Minuten später
kommt die zweite Anfrage für den Installer, wieder freigeben. Danach hängt der Workflow die signierten
Dateien an den Entwurf und `release.sh` meldet sich wie gewohnt. Jede Anfrage wartet höchstens 60 Minuten;
danach schlägt der Lauf fehl und `gh run rerun <id> --failed` stellt eine neue Anfrage (SignPath wertet
höchstens drei Wiederholungen eines Laufs aus).

Auch signiert kann SmartScreen bei ganz neuen Dateien anfangs noch warnen, bis sie genug Downloads haben;
das Zertifikat der SignPath Foundation bringt aber schon Vertrauen mit.

**Alternative mit eigenem Namen im Zertifikat:** Azure Artifact Signing (früher „Trusted Signing“) mit
Identitätsprüfung der Birkholz & Rabitzsch GbR und kleiner monatlicher Gebühr. Der frühere, nie benutzte
Azure-Pfad im Workflow ist entfernt; umgestellt würden nur die Jobs `sign-app` und `sign-installer` (Azures
eigene GitHub-Action statt der von SignPath).

### 5. Automatische Updates der Mac-App (Sparkle)

Knips fragt einmal am Tag nach
`https://github.com/patrickbirkholz0000/knips/releases/latest/download/appcast.xml` (`SUFeedURL` in
`Resources/Info.plist`). Jede Version hängt ihr eigenes `appcast.xml` an ihr Release; `latest` ist immer das
neueste **veröffentlichte** Release, Entwürfe zählen nicht. Ein Update erreicht die Nutzer also erst, wenn der
Entwurf veröffentlicht ist. Jedes DMG trägt eine EdDSA-Signatur (ed25519), die Knips vor dem Entpacken gegen
`SUPublicEDKey` prüft; danach prüft Sparkle die Code-Signatur der neuen App. Ablauf und Oberfläche:
`docs/ENTWICKLUNG.md`, Abschnitt „Updates“.

**Schlüssel.** `generate_keys --account knips` legt den privaten Schlüssel einmalig im Schlüsselbund des Macs ab,
auf dem Releases entstehen. Der öffentliche steht als `SUPublicEDKey` in `Resources/Info.plist`. Sparkles Werkzeuge liegen nach
`swift build` bzw. `swift package resolve` unter `.build/artifacts/sparkle/Sparkle/bin/`. Öffentlichen Schlüssel
anzeigen:

```
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account knips -p
```

**Sicherung:** Ohne den privaten Schlüssel lässt sich kein Update mehr signieren, das installierte Fassungen
annehmen. Mit `generate_keys --account knips -x <datei>` in eine Datei außerhalb des Repos exportieren, sicher
verwahren (Passwortmanager, verschlüsseltes Backup) und die Datei danach löschen.

Auf einem anderen Mac zurückholen: Inhalt wieder in eine Datei schreiben, dann
`generate_keys --account knips -f <datei>` und die Datei löschen.

**Schlüssel verloren:** Sparkle nimmt ersatzweise ein DMG an, das mit derselben Developer ID (Team S8QR9YWZS7)
signiert ist, und übernimmt dann den neuen `SUPublicEDKey` aus der neuen App. Neuen Schlüssel erzeugen, in die
Info.plist eintragen, ein Release damit herausgeben. EdDSA-Schlüssel und Developer-ID-Zertifikat nie in derselben
Version wechseln, sonst nimmt keine installierte Fassung das Update an.

**1.0.0 und 1.0.1 haben noch keinen Updater.** Wer eine dieser Versionen hat, aktualisiert einmal von Hand (neues DMG
laden, Knips in „Programme“ ersetzen); ab dann geht es automatisch. Am besten einen Satz dazu in den Text des ersten
Releases mit Updater schreiben (im Entwurf vor dem Veröffentlichen).

**Sparkle selbst aktualisieren:** Version in `Package.swift` (fest, `exact:`) anheben, `swift package resolve`,
Änderungen von Sparkle lesen, `Resources/Sparkle-LICENSE.txt` aus `.build/artifacts/sparkle/Sparkle/LICENSE`
übernehmen, dann `scripts/update-test.sh` (Ende-zu-Ende-Test mit zwei Builds und Wegwerf-Schlüssel, siehe
`docs/ENTWICKLUNG.md`).

### 6. Automatische Updates der Windows-Fassung (Tauri)

Die Windows-Fassung aktualisiert sich selbst, ab der ersten Version nach 1.0.1, ohne eigenen Server: über das
offizielle `tauri-plugin-updater` (MIT/Apache-2.0). Ablauf in der App: `windows/src-tauri/src/update.rs`, Regeln
`windows/crates/core/src/update.rs`, Einzelheiten `windows/ENTWICKLUNG.md` („Automatische Aktualisierung“).

- **Feed:** `https://github.com/patrickbirkholz0000/knips/releases/latest/download/latest.json` (in
  `windows/src-tauri/tauri.conf.json`, `plugins.updater`). Jede Version bringt ihre eigene `latest.json` als
  Release-Datei mit. GitHub zählt Entwürfe nie als „latest“: Ein Update geht erst an die Nutzer, wenn das Release
  veröffentlicht ist. Ein veröffentlichtes Release ohne `latest.json` (etwa nur fürs DMG) hielte die Updates an,
  bis wieder eines mit `latest.json` erscheint.
- **Signatur:** Der Job `updater` in `release.yml` signiert den **endgültigen** Installer (nach SignPath bzw.
  unsigniert) mit `tauri signer sign --app-version X.Y.Z` und schreibt `latest.json` (`scripts/update-feed.ps1` →
  `scripts/update-feed.mjs`): Version, `pub_date`, `notes` mit Link zur Release-Seite, `platforms.windows-x86_64` mit
  `signature` und `url` auf `Knips_X.Y.Z_x64-setup.exe` des Tags. Geprüft wird gleich danach und noch einmal in
  `publish` mit dem öffentlichen Schlüssel aus `tauri.conf.json` des Tags — passt der Schlüssel nicht, hängt nichts
  am Release. Die App verlangt, dass die Signatur die Versionsnummer nennt (`requireSignedVersion`), lädt nur über
  HTTPS und installiert nie etwas Älteres oder Gleiches.
- **Installation:** NSIS pro Benutzer, passiv (nur Fortschrittsbalken), ohne Administratorrechte. Beim Beenden ohne
  Neustart, per „Neu starten und aktualisieren“ mit. Einstellungen, Ablage, Verlauf, Druck-Taste und Autostart
  bleiben (Aktualisierungsmodus `/UPDATE`, die Deinstallations-Hooks laufen dabei nicht).
- **1.0.0 und 1.0.1** haben noch keinen Updater: Wer sie installiert hat, aktualisiert einmal von Hand (Installer
  von der Releases-Seite oder `irm https://knips.velno.ai/install.ps1 | iex`); ab dann geht es von selbst. Am besten
  im Release-Text der ersten Version mit Updater erwähnen.
- **`install.ps1` und winget** funktionieren unverändert: beide nehmen den Installer, nicht `latest.json`. Nach einer
  Selbstaktualisierung zeigt `winget list` die neue Version (der Installer schreibt `DisplayVersion`), ein späteres
  `winget upgrade` installiert einfach darüber.

**Einrichtung:**

- Schlüsselpaar mit `pnpm tauri signer generate` erzeugen (mit Passwort), außerhalb des Repos. Den öffentlichen
  Schlüssel in `windows/src-tauri/tauri.conf.json` eintragen.
- GitHub-Secrets `TAURI_SIGNING_PRIVATE_KEY` (Inhalt der Schlüsseldatei) und `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
  über die Standardeingabe setzen, damit nichts in einer Befehlszeile steht:

  ```
  gh secret set TAURI_SIGNING_PRIVATE_KEY < <schlüsseldatei>
  gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD < <passwortdatei>
  ```

  Fehlt das Secret, bricht `release.yml` gleich zu Beginn mit einem Hinweis ab.

**Schlüssel sichern — wichtig.** Ohne den privaten Schlüssel und sein Passwort lässt sich nie wieder ein Update
signieren, das bereits installierte Fassungen annehmen; dann bliebe nur, alle Nutzer einmal von Hand auf eine
Version mit neuem Schlüssel zu bringen. Schlüssel und Passwort deshalb verschlüsselt an einem zweiten Ort ablegen
(Passwortmanager oder verschlüsseltes Backup), nie ins Repo, nie unverschlüsselt in eine Cloud. Das GitHub-Secret
lässt sich nicht wieder auslesen und ist kein Backup.

**Schlüssel wechseln** (nur wenn er verloren oder bekannt geworden ist): neues Paar erzeugen, öffentlichen Schlüssel in
`tauri.conf.json`, Secrets neu setzen. Installierte Fassungen kennen nur den alten Schlüssel — die erste Version mit
neuem Schlüssel muss deshalb noch mit dem **alten** signiert sein (falls vorhanden): `latest.json` von Hand mit dem
alten Schlüssel signieren und hochladen. Ist der alte verloren, bleibt nur der Hinweis an die Nutzer, einmal von Hand
zu aktualisieren.

**Probe ohne Release:** `windows.yml` spielt den Ablauf bei jedem Lauf nach — Job `signatur` mit Wegwerf-Schlüssel
über den signierten Installer (`latest.json` erzeugen und prüfen, Gegenproben), Schritt „Aktualisierung (Ende zu
Ende)“ mit zwei echten Installern 0.0.1 → 0.0.2 (`windows/scripts/update-test.ps1`). Einzeln:
`gh workflow run windows.yml --ref <zweig> -f selbsttests=update`.

## Release erstellen

Voraussetzungen: alles auf `main` gemergt und gepusht, Windows-CI grün, Arbeitsverzeichnis sauber.

```
scripts/release.sh 1.0.0      # legt v1.0.0 auf HEAD an
scripts/release.sh            # oder: nimmt das vX.Y.Z-Tag, das schon auf HEAD liegt
```

Das Skript

1. prüft Developer ID, Notarisierungs-Profil, den EdDSA-Schlüssel für die Updates, `gh`-Anmeldung, `LICENSE`,
   dass `main` sauber und gleich `origin/main` ist und dass die neue Version größer als die letzte ist,
2. legt das Tag lokal an und baut mit `scripts/package.sh` das notarisierte DMG (dauert mit zwei
   Notarisierungen meist 5–15 Minuten),
3. signiert das fertige DMG mit Sparkles `sign_update` (Schlüssel `knips` aus dem Schlüsselbund; beim ersten Mal
   fragt macOS nach: „Immer erlauben“), prüft die Signatur mit `scripts/update-signature.swift` gegen
   `SUPublicEDKey` der gebauten App und schreibt mit `scripts/appcast.sh` `build/appcast.xml` mit genau dieser
   Version (`sparkle:version` = Build-Nummer, `sparkle:shortVersionString` = Version, mindestens macOS 14.0,
   Länge, Signatur, Link auf die Release-Seite, DMG-Adresse des Tags),
4. pusht das Tag; das startet `release.yml` (Windows-Installer, etwa 20–30 Minuten, mit SignPath dazu die
   beiden Freigaben),
5. legt den Release-**Entwurf** mit DMG, Prüfsumme, `appcast.xml` und Release-Text an
   (`build/release-notes-vX.Y.Z.md`),
6. wartet auf den Windows-Lauf und prüft, dass Installer, `appcast.xml` und `latest.json` am Entwurf hängen.

Scheitert es vor dem Push, entfernt es ein selbst angelegtes Tag wieder. Danach den Entwurf selbst ansehen,
beide Downloads einmal testen und veröffentlichen:

```
gh release edit v1.0.0 --draft=false
```

Erst danach liefert `releases/latest/download/appcast.xml` die neue Version, und die installierten Macs holen sie
innerhalb eines Tages (frühestens fünf Minuten nach ihrem nächsten Start). Prüfen:

```
curl -sL https://github.com/patrickbirkholz0000/knips/releases/latest/download/appcast.xml | grep -E 'sparkle:(short)?[vV]ersion'
```

Nur ein Test-DMG ohne Notarisierung (nicht zur Weitergabe, Gatekeeper blockiert es auf anderen Macs):

```
NOTARIZE=0 scripts/package.sh   # → build/Knips-<version>-<build>-nicht-notarisiert.dmg
```

Nur den Windows-Teil neu bauen und anhängen (ersetzt vorhandene Dateien). Mit `--ref` auf dem Tag selbst,
sonst verweigert der Workflow die Signatur (SignPath prüft die Herkunft am Lauf):

```
gh workflow run release.yml --ref v1.0.0 -f tag=v1.0.0
```

## Installationsskript (PowerShell)

`windows/install.ps1` ist das Skript hinter `irm https://knips.velno.ai/install.ps1 | iex`. Es nimmt immer das
neueste **veröffentlichte** Release (Entwürfe sieht es nicht), prüft die `.sha256` aus dem Release (und die
Prüfsumme, die GitHub selbst nennt), bei signierten Installern die Signatur (Status `Valid`, Herausgeber
SignPath Foundation, sonst Abbruch), installiert mit `/S` und startet Knips. Der Worker in `telemetry/` liefert
es aus derselben Datei aus: Nach einer Änderung am Skript den Worker deployen (`telemetry/README.md`).
Geprüft wird es in `windows.yml` (Installation und Deinstallation unter PowerShell 7 und 5.1, falsche
Prüfsumme, fremder Herausgeber, manipulierte Datei). Die Datei muss UTF-8 **mit** BOM bleiben, sonst liest
Windows PowerShell 5.1 die Umlaute falsch (die CI prüft das; der Worker entfernt das BOM beim Ausliefern).

Wechselt das Zertifikat (z. B. zu Azure mit eigenem Namen), `$TrustedSigner` in `install.ps1` anpassen.

## winget (Windows-Paketmanager)

Paket `PatrickBirkholz.Knips`, Vorlagen in `windows/winget/` (Manifest-Schema 1.28.0, Standardsprache de-DE,
dazu en-US; Installer-Typ nullsoft, Scope user, x64, Lizenz GPL-3.0-or-later).

**Was winget-pkgs prüft:** Schema; ob die URLs per HTTPS erreichbar sind und zum Herausgeber gehören (die
Release-URLs dieses Repos tun das); die SmartScreen-Reputation der **URL** (nicht der Datei; github.com ist
unproblematisch); Virenscan; Installation und Deinstallation ohne Eingaben in einer Test-VM. Eine Signatur
verlangt winget-pkgs nicht, unsignierte Installer werden angenommen. Beim Installieren über winget gibt es
auch keine SmartScreen-Abfrage: winget prüft den SHA-256 aus dem Manifest und markiert Installer aus der
Community-Quelle danach als vertrauenswürdig. Smart App Control (Windows 11) kann unsignierte Programme
trotzdem blockieren — das behebt erst die Signatur.

**Erste Einreichung (von Hand):**

1. Release veröffentlichen (kein Entwurf; die Installer-URL muss öffentlich sein).
2. Manifeste erzeugen:

   ```
   scripts/winget-manifest.sh 1.0.0      # → build/winget/manifests/p/PatrickBirkholz/Knips/1.0.0/
   ```

   Das Skript lädt den Installer über dieselbe URL wie winget, prüft ihn gegen die `.sha256` aus dem Release,
   trägt SHA-256 und Datum ein und prüft die Dateien gegen die offiziellen JSON-Schemas (braucht
   `pip install jsonschema pyyaml`, sonst nur ein Hinweis).
3. Optional auf einem Windows-Rechner: `winget validate --manifest <ordner>`, dann
   `winget settings --enable LocalManifestFiles` (als Administrator) und `winget install --manifest <ordner>`.
4. Einreichen: Fork von `microsoft/winget-pkgs` anlegen, den Ordner `manifests/p/PatrickBirkholz/Knips/1.0.0`
   hineinkopieren und einen Pull Request „New package: PatrickBirkholz.Knips version 1.0.0“ stellen. Unter
   Windows geht das auch mit `wingetcreate submit --token <PAT> <ordner>`. Beim ersten Pull Request fragt ein
   Bot nach dem Microsoft-CLA. Die Prüfung dauert Stunden bis Tage; Fehler stehen als Labels
   (`Validation-…`) am Pull Request.
5. Nach der Aufnahme in der README „sobald Knips im Windows-Paketmanager aufgenommen ist“ streichen.

**Spätere Versionen** (nicht eingerichtet): mit `vedantmgoyal9/winget-releaser` in einem eigenen Workflow auf
`release: published` automatisierbar. Braucht einen Fork von winget-pkgs unter `patrickbirkholz0000` und einen
Personal Access Token (classic, Scope `public_repo`) als Secret, z. B. `WINGET_TOKEN`; Eingaben
`identifier: PatrickBirkholz.Knips`, `installers-regex: '_x64-setup\.exe$'`. Die Action an eine Commit-SHA
pinnen; sie installiert intern `cargo-bins/cargo-binstall@main` ohne feste Version, das vorher prüfen.
Neue Versionen übernehmen die Angaben der vorigen aus winget-pkgs, nicht die Vorlagen hier.

## Download prüfen

macOS, im Download-Ordner:

```
shasum -a 256 -c Knips-1.0.0-123.dmg.sha256
spctl -a -vvv -t open --context context:primary-signature Knips-1.0.0-123.dmg
xcrun stapler validate Knips-1.0.0-123.dmg
```

Erwartet: `OK`, `accepted` mit `source=Notarized Developer ID` und
`origin=Developer ID Application: Birkholz & Rabitzsch GbR (S8QR9YWZS7)`, `The validate action worked!`.
Nach dem Installieren:

```
spctl -a -vvv /Applications/Knips.app
codesign -dvv /Applications/Knips.app   # TeamIdentifier=S8QR9YWZS7, flags=0x10000(runtime), Timestamp=…
```

Windows, in PowerShell:

```
Get-FileHash .\Knips_1.0.0_x64-setup.exe          # Hash muss in der .sha256-Datei stehen
Get-AuthenticodeSignature .\Knips_1.0.0_x64-setup.exe | Format-List Status, SignerCertificate
```

Signiert erwartet: `Status: Valid`, Zertifikat `CN=SignPath Foundation`. Dasselbe für
`%LOCALAPPDATA%\Knips\knips.exe` nach der Installation.

`latest.json` gegen den Installer und den öffentlichen Schlüssel prüfen (aus `windows/`, nur Node):

```
node scripts/update-feed.mjs --check ~/Downloads/latest.json --installer ~/Downloads/Knips_1.0.2_x64-setup.exe
```

## Fehlersuche

**Notarisierung hängt bei „In Progress“.** Meist dauert sie wenige Minuten. Bei den ersten Einreichungen
eines Teams prüft Apple manchmal Stunden. `package.sh` wartet höchstens 30 Minuten und nennt dann die
Einreichungs-ID:

```
xcrun notarytool info <id> --keychain-profile knips
xcrun notarytool wait <id> --keychain-profile knips
xcrun notarytool history --keychain-profile knips
```

Ist sie später durch, `scripts/package.sh` bzw. `scripts/release.sh` einfach erneut starten. Störungen
meldet developer.apple.com/system-status.

**HTTP 403, „A required agreement is missing or has expired“.** Apple hat neue Vereinbarungen. Der Account
Holder meldet sich auf developer.apple.com/account an und nimmt sie an, gegebenenfalls auch in App Store
Connect unter „Business“. Danach erneut versuchen. Bei **401** ist der Zugang ungültig (API-Schlüssel
widerrufen, app-spezifisches Passwort gelöscht): `store-credentials` wiederholen.

**Status „Invalid“.** `package.sh` gibt das Protokoll von Apple aus. Häufige Ursachen sind fehlende Hardened
Runtime, fehlender Zeitstempel, `get-task-allow` in den Entitlements oder unsignierter Code im Bundle;
`package.sh` prüft die ersten drei schon vor dem Hochladen, auch für `Autoupdate`, `Updater.app` und
`Sparkle.framework`.

**`sign_update`: „Signing key not found for account knips“.** Der EdDSA-Schlüssel fehlt in diesem Schlüsselbund
(anderer Mac, neu eingerichtet): aus der Sicherung zurückholen (Einrichtung 5). Fragt macOS bei jedem Release
nach dem Schlüssel, im Dialog „Immer erlauben“ wählen; nach einem Wechsel der Sparkle-Version fragt es einmal neu.

**„Die EdDSA-Signatur passt nicht zu SUPublicEDKey“.** Signiert wurde mit einem anderen Schlüssel als dem, den die
App kennt (anderes Konto, falscher Import, Info.plist von Hand geändert). Mit `generate_keys --account knips -p`
vergleichen; nichts hochladen, bis beide übereinstimmen.

**Updates kommen nicht an.** Ist das Release veröffentlicht und kein Entwurf? Liefert der `curl`-Befehl aus
„Release erstellen“ die neue Build-Nummer? Größer als die installierte (`CFBundleVersion`)? Was Knips und Sparkle
melden, steht im Systemprotokoll:

```
log show --last 1d --info --predicate 'subsystem == "de.birkgroup.knips" OR subsystem == "org.sparkle-project.Sparkle"'
```

Ein veröffentlichtes Release mit falschem `appcast.xml` lässt sich nicht ändern: eine neue Version herausgeben.
Den ganzen Weg ohne GitHub prüft `scripts/update-test.sh`.

**`errSecInternalComponent` beim Signieren** (z. B. über SSH): Schlüsselbund ist gesperrt.
`security unlock-keychain ~/Library/Keychains/login.keychain-db`, dann erneut.

**„The timestamp service is not available.“** Apples Zeitstempel-Server war nicht erreichbar. Netz prüfen,
erneut starten.

**Windows-Lauf fehlgeschlagen.** `gh run view <id> --log-failed`, Fehler beheben, dann
`gh workflow run release.yml --ref vX.Y.Z -f tag=vX.Y.Z`. Der Lauf baut aus dem Tag; ein Fix im Code braucht
daher eine neue Version. Nur eine Freigabe verpasst (Zeitüberschreitung in `sign-app` oder
`sign-installer`): `gh run rerun <id> --failed`.

**SignPath lehnt die Anfrage ab.** Den Grund zeigt die Anfrage auf app.signpath.io. Häufig: Metadaten passen
nicht (ProductName „Knips“, Version, Dateiname wie in `.signpath/artifact-configurations/`), die
Artefakt-Konfiguration in SignPath ist veraltet (aus dem Repo neu einfügen), oder die Herkunft stimmt nicht
(Lauf nicht auf dem Tag gestartet, nicht auf GitHub-Runnern).

**Job `updater` scheitert.** „TAURI_SIGNING_PRIVATE_KEY fehlt“: Secret setzen (siehe Einrichtung 6). „incorrect
updater private key password“: `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` passt nicht zum Schlüssel — beide Secrets neu
setzen. „Signatur stammt von einem anderen Schlüssel“: Secret und öffentlicher Schlüssel in
`tauri.conf.json` gehören nicht zusammen (nach einem Schlüsselwechsel einen von beiden vergessen). Danach
`gh run rerun <id> --failed`; bei einem Fehler im Code braucht es wie immer eine neue Version.

**Installierte Fassungen finden das Update nicht.** Release veröffentlicht (kein Entwurf, keine Vorabversion)?
`latest.json` am Release? `curl -sL https://github.com/patrickbirkholz0000/knips/releases/latest/download/latest.json`
muss die neue Version nennen. Knips sucht höchstens einmal am Tag (erste Suche einige Minuten nach dem Start);
„Jetzt nach Updates suchen“ unter Einstellungen → Über Knips sucht sofort. Gründe stehen im Protokoll
`%LOCALAPPDATA%\de.birkgroup.knips\logs\knips.log` (Zeilen „Aktualisierung …“). Fassungen bis 1.0.1 haben keinen
Updater.

**Update geladen, aber nicht installiert.** Installiert wird nur beim Beenden über das Menü oder per „Neu starten
und aktualisieren“, nie während einer Aufnahme, eines Scroll-Screenshots oder während Knips speichert; der Knopf
nennt den Grund (auch: offene Editoren). Wird Windows heruntergefahren, bleibt das Update in
`%LOCALAPPDATA%\de.birkgroup.knips\update\` und steht beim nächsten Start ohne neuen Download bereit.

**Falsches Tag, noch nicht veröffentlicht.** Entwurf und Tag löschen, dann neu starten:

```
gh release delete vX.Y.Z --yes
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
```

Ein veröffentlichtes Release nie umschreiben, sondern eine neue Version herausgeben.
