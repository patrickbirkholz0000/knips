# Knips veröffentlichen

Ein Release besteht aus einem GitHub-Release in diesem Repo (`patrickbirkholz0000/knips`) mit vier Dateien:

| Datei | kommt von | Signatur |
|---|---|---|
| `Knips-X.Y.Z-<build>.dmg` + `.sha256` | `scripts/release.sh` auf dem Mac (über `scripts/package.sh`) | Developer ID, von Apple notarisiert, Ticket gestapelt |
| `Knips_X.Y.Z_x64-setup.exe` + `.sha256` | `.github/workflows/release.yml` auf Windows-Runnern | SignPath (Zertifikat der SignPath Foundation), falls eingerichtet, sonst unsigniert |

Maßgeblich ist das Tag `vX.Y.Z`. `build.sh` liest es per `git describe` (ohne Tag gilt
`CFBundleShortVersionString` aus `Resources/Info.plist`), der Workflow schreibt es beim Bauen in
`windows/package.json`, `windows/Cargo.toml` und `windows/src-tauri/tauri.conf.json` (nicht eingecheckt).
Eingecheckt steht dort die aktuelle Version, derzeit `1.0.0`; bei einer neuen Version am besten mit anheben
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

## Release erstellen

Voraussetzungen: alles auf `main` gemergt und gepusht, Windows-CI grün, Arbeitsverzeichnis sauber.

```
scripts/release.sh 1.0.0      # legt v1.0.0 auf HEAD an
scripts/release.sh            # oder: nimmt das vX.Y.Z-Tag, das schon auf HEAD liegt
```

Das Skript

1. prüft Developer ID, Notarisierungs-Profil, `gh`-Anmeldung, `LICENSE`, dass `main` sauber und gleich
   `origin/main` ist und dass die neue Version größer als die letzte ist,
2. legt das Tag lokal an und baut mit `scripts/package.sh` das notarisierte DMG (dauert mit zwei
   Notarisierungen meist 5–15 Minuten),
3. pusht das Tag; das startet `release.yml` (Windows-Installer, etwa 20–30 Minuten, mit SignPath dazu die
   beiden Freigaben),
4. legt den Release-**Entwurf** mit DMG, Prüfsumme und Release-Text an (`build/release-notes-vX.Y.Z.md`),
5. wartet auf den Windows-Lauf und prüft, dass der Installer am Entwurf hängt.

Scheitert es vor dem Push, entfernt es ein selbst angelegtes Tag wieder. Danach den Entwurf selbst ansehen,
beide Downloads einmal testen und veröffentlichen:

```
gh release edit v1.0.0 --draft=false
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
`package.sh` prüft die ersten drei schon vor dem Hochladen.

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

**Falsches Tag, noch nicht veröffentlicht.** Entwurf und Tag löschen, dann neu starten:

```
gh release delete vX.Y.Z --yes
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
```

Ein veröffentlichtes Release nie umschreiben, sondern eine neue Version herausgeben.
