# Knips veröffentlichen

Ein Release besteht aus einem GitHub-Release in diesem Repo (`patrickbirkholz0000/knips`) mit vier Dateien:

| Datei | kommt von | Signatur |
|---|---|---|
| `Knips-X.Y.Z-<build>.dmg` + `.sha256` | `scripts/release.sh` auf dem Mac (über `scripts/package.sh`) | Developer ID, von Apple notarisiert, Ticket gestapelt |
| `Knips_X.Y.Z_x64-setup.exe` + `.sha256` | `.github/workflows/release.yml` auf einem Windows-Runner | Azure Artifact Signing, falls eingerichtet, sonst unsigniert |

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

### 4. Optional: Windows-Installer signieren (Azure Artifact Signing)

Ohne Signatur warnt SmartScreen beim Ausführen („Der Computer wurde durch Windows geschützt“), die
Release-Notizen erklären den Weg über „Weitere Informationen“ → „Trotzdem ausführen“. Signieren lässt sich
über Azure Artifact Signing (früher „Trusted Signing“):

1. Azure-Konto mit Abonnement anlegen, Ressource **Artifact Signing Account** erstellen (Region z. B.
   West Europe, Endpunkt dann `https://weu.codesigning.azure.net`). Der Basis-Tarif kostet eine kleine
   monatliche Gebühr, aktuellen Preis vorher nachsehen.
2. **Identitätsprüfung** als Organisation „Birkholz & Rabitzsch GbR“ beantragen. Microsoft prüft die
   Firmenidentität und verlangt dabei unter anderem eine nachweisbare Geschäftshistorie. Ob eine GbR ohne
   Registereintrag angenommen wird, vorher in den aktuellen Voraussetzungen nachlesen.
3. **Zertifikatsprofil** vom Typ „Public Trust“ anlegen.
4. In Microsoft Entra ID eine **App-Registrierung** anlegen, ein Client-Geheimnis erzeugen und ihr auf dem
   Signing-Account die Rolle „Artifact Signing Certificate Profile Signer“ geben (ältere Bezeichnung:
   „Trusted Signing Certificate Profile Signer“).
5. Sechs Secrets im Repo setzen:

   ```
   gh secret set AZURE_CLIENT_ID         # Anwendungs-ID der App-Registrierung
   gh secret set AZURE_CLIENT_SECRET     # Client-Geheimnis
   gh secret set AZURE_TENANT_ID         # Verzeichnis-/Mandanten-ID
   gh secret set AZURE_SIGNING_ENDPOINT  # z. B. https://weu.codesigning.azure.net
   gh secret set AZURE_SIGNING_ACCOUNT   # Name des Signing-Accounts
   gh secret set AZURE_SIGNING_PROFILE   # Name des Zertifikatsprofils
   ```

Sind alle sechs gesetzt, installiert der Workflow `trusted-signing-cli`, gibt Tauri per `--config` ein
`bundle.windows.signCommand` mit und prüft danach `Get-AuthenticodeSignature`. Fehlt eines, baut er
unsigniert und schreibt einen Hinweis ins Protokoll. Auch signiert kann SmartScreen bei einem neuen
Zertifikat anfangs noch warnen, bis genug Downloads Vertrauen aufgebaut haben.

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
3. pusht das Tag; das startet `release.yml` (Windows-Installer, etwa 20–30 Minuten),
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

Nur den Windows-Teil neu bauen und anhängen (ersetzt vorhandene Dateien):

```
gh workflow run release.yml -f tag=v1.0.0
```

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
Get-AuthenticodeSignature .\Knips_1.0.0_x64-setup.exe   # Status Valid, wenn signiert
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
`package.sh` prüft die ersten drei schon vor dem Hochladen.

**`errSecInternalComponent` beim Signieren** (z. B. über SSH): Schlüsselbund ist gesperrt.
`security unlock-keychain ~/Library/Keychains/login.keychain-db`, dann erneut.

**„The timestamp service is not available.“** Apples Zeitstempel-Server war nicht erreichbar. Netz prüfen,
erneut starten.

**Windows-Lauf fehlgeschlagen.** `gh run view <id> --log-failed`, Fehler beheben, dann
`gh workflow run release.yml -f tag=vX.Y.Z`. Der Lauf baut aus dem Tag; ein Fix im Code braucht daher eine
neue Version.

**Falsches Tag, noch nicht veröffentlicht.** Entwurf und Tag löschen, dann neu starten:

```
gh release delete vX.Y.Z --yes
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
```

Ein veröffentlichtes Release nie umschreiben, sondern eine neue Version herausgeben.
