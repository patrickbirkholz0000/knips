#!/bin/bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen „…“ in den Texten sind gewollt
# Veröffentlicht eine Knips-Version als GitHub-Release-ENTWURF in diesem Repo.
#
#   scripts/release.sh 1.2.0    legt das Tag v1.2.0 auf HEAD an (falls es noch nicht existiert)
#   scripts/release.sh          nimmt das vX.Y.Z-Tag, das bereits auf HEAD liegt
#
# Ablauf: Vorbedingungen (main, sauber, gleich origin/main, Version neuer als die letzte) → scripts/package.sh
# (signiert + notarisiert) → Tag pushen (startet .github/workflows/release.yml: Windows-Installer) →
# Release-Entwurf mit DMG + SHA-256 → warten, bis der Windows-Installer dranhängt → Hinweis zum Veröffentlichen.
# Veröffentlicht wird nie automatisch. Einrichtung und Fehlersuche: RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }

# --- Werkzeuge und Zugänge ------------------------------------------------------------------------------
[[ "${NOTARIZE:-1}" != "0" ]] || die "release.sh veröffentlicht nur notarisierte Pakete — NOTARIZE=0 weglassen."
command -v gh >/dev/null || die "GitHub CLI fehlt: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh ist nicht angemeldet: gh auth login"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || die "GitHub-Repo nicht gefunden."
security find-identity -v -p codesigning | grep -q '"Developer ID Application: ' ||
  die "Keine „Developer ID Application“-Identität im Schlüsselbund — siehe RELEASING.md, Einrichtung 1."
xcrun notarytool history --keychain-profile "${KNIPS_NOTARY_PROFILE:-knips}" >/dev/null 2>&1 ||
  die "Notarisierungs-Profil „${KNIPS_NOTARY_PROFILE:-knips}“ fehlt oder wird abgelehnt — siehe RELEASING.md, Einrichtung 2."
[[ -f LICENSE ]] || die "LICENSE fehlt."

# --- Stand des Repos -----------------------------------------------------------------------------------
BRANCH=$(git symbolic-ref --short -q HEAD || true)
[[ "$BRANCH" == "main" ]] || die "Nicht auf main (sondern: ${BRANCH:-losgelöster HEAD})."
[[ -z "$(git status --porcelain)" ]] || die "Arbeitsverzeichnis nicht sauber — erst committen oder aufräumen (git status)."
step "Hole Stand von origin…"
git fetch --quiet --tags origin main
HEAD_SHA=$(git rev-parse HEAD)
[[ "$HEAD_SHA" == "$(git rev-parse origin/main)" ]] ||
  die "main entspricht nicht origin/main — erst pushen bzw. pullen. Veröffentlicht wird nur, was auf GitHub liegt."

# --- Version und Tag -----------------------------------------------------------------------------------
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ -n "${1:-}" ]]; then
  VERSION=${1#v}
  [[ "$VERSION" =~ $SEMVER ]] || die "Version '$1' hat nicht die Form X.Y.Z."
  TAG="v$VERSION"
else
  TAGS=$(git tag --points-at HEAD --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
  [[ -n "$TAGS" ]] || die "Kein vX.Y.Z-Tag auf HEAD. Aufruf: scripts/release.sh X.Y.Z"
  [[ $(grep -c . <<<"$TAGS") -eq 1 ]] || die "Mehrere Versions-Tags auf HEAD: $(paste -sd ' ' - <<<"$TAGS")"
  TAG=$TAGS
  VERSION=${TAG#v}
fi

CREATED_TAG=0
PUSHED=0
FINISHED=0
# bash 3.2 meldet nach einem Fehler durch `set -u` im EXIT-Trap Status 0 — daher zusätzlich FINISHED.
on_exit() {
  local rc=$?
  if [[ $rc -eq 0 && $FINISHED != 1 ]]; then rc=1; fi
  if [[ $rc -ne 0 && $CREATED_TAG == 1 && $PUSHED == 0 ]]; then
    git tag -d "$TAG" >/dev/null 2>&1 && echo "  (lokales Tag $TAG wieder entfernt)" >&2
  fi
  exit "$rc"
}
trap on_exit EXIT

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-list -n 1 "$TAG")" == "$HEAD_SHA" ]] || die "Tag $TAG existiert schon, aber auf einem anderen Commit."
  step "Tag $TAG liegt bereits auf HEAD."
else
  LATEST=$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
  if [[ -n "$LATEST" ]]; then
    [[ "$(printf '%s\n%s\n' "$LATEST" "$TAG" | sort -V | tail -1)" == "$TAG" ]] ||
      die "$TAG ist nicht neuer als die letzte Version $LATEST."
  fi
  step "Lege Tag $TAG an…"
  git tag -a "$TAG" -m "Knips $VERSION"
  CREATED_TAG=1
fi
# build.sh nimmt die Version aus `git describe` — muss genau dieses Tag sein.
DESCRIBED=$(git describe --tags --abbrev=0)
[[ "$DESCRIBED" == "$TAG" ]] || die "git describe liefert $DESCRIBED statt $TAG — die App bekäme die falsche Version."

STATE=$(gh release view "$TAG" --json isDraft -q 'if .isDraft then "draft" else "published" end' 2>/dev/null || echo none)
[[ "$STATE" != "published" ]] || die "Release $TAG ist bereits veröffentlicht."

# --- macOS-Paket ---------------------------------------------------------------------------------------
step "Baue, signiere und notarisiere das macOS-Paket…"
scripts/package.sh
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw build/Knips.app/Contents/Info.plist)
BUILD=$(plutil -extract CFBundleVersion raw build/Knips.app/Contents/Info.plist)
[[ "$APP_VERSION" == "$VERSION" ]] || die "App-Version $APP_VERSION passt nicht zu $TAG."
DMG="build/Knips-$VERSION-$BUILD.dmg"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || die "$DMG oder $DMG.sha256 fehlt."
(cd build && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null) || die "Prüfsumme von $DMG stimmt nicht."
[[ -z "$(git status --porcelain)" ]] || die "Der Build hat eingecheckte Dateien verändert (git status)."

# --- Release-Text --------------------------------------------------------------------------------------
EXE="Knips_${VERSION}_x64-setup.exe"
NOTES="build/release-notes-$TAG.md"
PREV=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TAG^" 2>/dev/null || true)
{
  cat <<EOF
Knips $VERSION — Screenshots und Bildschirmaufnahmen mit Zensur, für macOS und Windows.

## Download

| System | Datei |
|---|---|
| macOS 14 (Sonoma) oder neuer, Apple Silicon und Intel | \`$(basename "$DMG")\` |
| Windows 10 und 11 (64 Bit) | \`$EXE\` |

Zu jeder Datei gehört eine \`.sha256\`-Datei mit der Prüfsumme.

## macOS

Das DMG ist mit der Developer ID der Birkholz & Rabitzsch GbR signiert und von Apple notarisiert.

1. DMG öffnen, Knips in „Programme“ ziehen und von dort starten.
2. **Bildschirmaufnahme erlauben:** Knips zeigt beim ersten Start, wo das geht (Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme). Danach Knips einmal neu starten.
3. **Mikrofon** braucht Knips nur für Aufnahmen mit Kommentar. macOS fragt erst, wenn Knips es zum ersten Mal braucht.
4. **Kürzel ⌘⇧3, ⌘⇧4, ⌘⇧5:** Knips fragt beim Start, ob es sie übernehmen darf, und schaltet dafür die gleichnamigen macOS-Kürzel für Bildschirmfotos ab.

**Deinstallieren:** Zuerst in Knips unter Einstellungen → Tastaturkürzel auf „macOS-Kürzel wiederherstellen“ klicken. Sonst bleiben ⌘⇧3/4/5 nach dem Löschen ohne Funktion (von Hand: Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Bildschirmfotos). Danach Knips aus „Programme“ löschen. Aufnahmen liegen in \`~/Pictures/Knips\`, Originale und Bearbeitungsstände in \`~/Library/Application Support/Knips\`.

Prüfsumme: \`shasum -a 256 -c $(basename "$DMG").sha256\` im Download-Ordner.

## Windows

Installer ausführen. Knips installiert sich nur für den angemeldeten Benutzer, ohne Administratorrechte.

Ist der Installer nicht signiert, warnt Windows SmartScreen mit „Der Computer wurde durch Windows geschützt“. Dann „Weitere Informationen“ → „Trotzdem ausführen“ wählen. Vorher am besten die Prüfsumme vergleichen: \`Get-FileHash .\\$EXE\` in PowerShell muss den Wert aus \`$EXE.sha256\` ergeben (Groß-/Kleinschreibung egal).

EOF
  if [[ -n "$PREV" ]]; then
    echo "## Änderungen seit $PREV"
    echo
    git log --no-merges --reverse --pretty='- %s' "$PREV..$TAG"
  else
    echo "## Erste öffentliche Version"
  fi
  echo
  echo "Knips ist freie Software unter der GNU General Public License, Version 3 oder neuer."
} >"$NOTES"

# --- Tag pushen, Entwurf anlegen -------------------------------------------------------------------------
step "Pushe $TAG (startet den Windows-Build)…"
git push origin "refs/tags/$TAG"
PUSHED=1

if [[ "$STATE" == "none" ]] && gh release view "$TAG" >/dev/null 2>&1; then STATE=draft; fi
if [[ "$STATE" == "draft" ]]; then
  step "Aktualisiere den vorhandenen Entwurf ${TAG}…"
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  gh release edit "$TAG" --title "Knips $VERSION" --notes-file "$NOTES"
else
  step "Lege den Release-Entwurf $TAG an…"
  gh release create "$TAG" "$DMG" "$DMG.sha256" --draft --verify-tag --title "Knips $VERSION" --notes-file "$NOTES"
fi

# --- Auf den Windows-Installer warten ------------------------------------------------------------------
step "Warte auf den Windows-Build (.github/workflows/release.yml)…"
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID=$(gh run list --workflow release.yml --limit 20 --json databaseId,headSha \
    -q "[.[] | select(.headSha == \"$HEAD_SHA\")][0].databaseId // empty" 2>/dev/null || true)
  [[ -n "$RUN_ID" ]] && break
  sleep 10
done
[[ -n "$RUN_ID" ]] ||
  die "Kein Lauf von release.yml für $TAG gefunden. Von Hand starten: gh workflow run release.yml -f tag=$TAG — dann den Entwurf prüfen."
echo "  https://github.com/$REPO/actions/runs/$RUN_ID"
gh run watch "$RUN_ID" --exit-status --interval 30 >/dev/null ||
  die "Windows-Build fehlgeschlagen: gh run view $RUN_ID --log-failed — neu starten: gh workflow run release.yml -f tag=$TAG"

ASSETS=$(gh release view "$TAG" --json assets -q '.assets[].name')
grep -qx "$EXE" <<<"$ASSETS" || die "$EXE hängt nicht am Release (vorhanden: $(paste -sd ' ' - <<<"$ASSETS"))."

URL=$(gh release view "$TAG" --json url -q .url)
cat <<EOF

✓ Entwurf $TAG ist vollständig: $URL
  Dateien: $(paste -sd ' ' - <<<"$ASSETS")

  Jetzt bitte selbst prüfen (Text lesen, beide Downloads einmal testen) und dann veröffentlichen:
    gh release edit $TAG --draft=false
  oder auf GitHub im Entwurf „Publish release“ klicken.
EOF
FINISHED=1
