#!/bin/bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen „…“ in den Meldungen sind gewollt
# Ende-zu-Ende-Test der automatischen Updates (Sparkle) — ohne GitHub, ohne Fenster, ohne den Bildschirm zu benutzen:
#
#   scripts/update-test.sh [<ausgabeordner>]      (Standard: build/aktualisierungstest; SKIP_BUILD=1 nimmt build/Knips.app)
#
# 1. baut build/Knips.app (scripts/build.sh, eigener Build mit Selbsttests),
# 2. legt in einem Temp-Ordner zwei Fassungen an, alt (Build N) und neu (Build N+1), mit der Testkennung
#    de.birkgroup.knips.aktualisierungstest (eigene Einstellungen, Caches und eigener Installer) und dem öffentlichen
#    Teil eines Wegwerf-Schlüssels, signiert mit derselben Identität wie build/Knips.app,
# 3. packt die neue wie scripts/package.sh in ein DMG, signiert es mit Sparkles sign_update (Wegwerf-Schlüssel), prüft
#    die Signatur gegen SUPublicEDKey der alten App und schreibt mit scripts/appcast.sh vier Feeds: richtig, falsch
#    signiert, gleiche und ältere Version,
# 4. `--selftest update` in der alten Fassung: lokaler Server auf 127.0.0.1, Gegenproben (Einstellung aus, gleiche und
#    ältere Version, falsche Signatur im Hintergrund und von Hand), dann lädt und prüft sie das neue Update und beendet
#    sich,
# 5. `--selftest update-installed` (aus build/Knips.app) wartet, bis Sparkle Build N+1 an dieselbe Stelle gelegt hat —
#    ohne Neustart und ohne Fenster —, danach prüft codesign die Signatur.
#
# Die installierte App, die echten Einstellungen (de.birkgroup.knips), laufende Knips-Instanzen und der echte Schlüssel
# im Schlüsselbund bleiben unberührt. KEEP=1 lässt den Temp-Ordner stehen.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_ID=de.birkgroup.knips.aktualisierungstest
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
BUILT=build/Knips.app
OUT=${1:-build/aktualisierungstest}
TMP=$(mktemp -d -t knips-aktualisierung)
FINISHED=0

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }
indent() { sed "s/^/   /"; }

# Alles, was nur zur Testkennung gehört: Einstellungen, Caches, Sparkles launchd-Aufträge.
forget_test_id() {
  defaults delete "$TEST_ID" >/dev/null 2>&1 || true
  rm -f "${HOME:?}/Library/Preferences/$TEST_ID.plist"
  rm -rf "${HOME:?}/Library/Caches/$TEST_ID" "${HOME:?}/Library/HTTPStorages/$TEST_ID" "${HOME:?}/Library/HTTPStorages/$TEST_ID.binarycookies"
  launchctl list 2>/dev/null | awk -v id="$TEST_ID" 'index($3, id) == 1 { print $3 }' | while read -r label; do
    launchctl remove "$label" 2>/dev/null || true
  done
}

# bash 3.2 meldet nach einem Fehler durch `set -u` im EXIT-Trap Status 0 — daher zusätzlich FINISHED.
cleanup() {
  local rc=$?
  forget_test_id
  if [[ "${KEEP:-0}" == "1" ]]; then echo "  Temp-Ordner bleibt: $TMP"; else rm -rf "$TMP"; fi
  if [[ $rc -eq 0 && $FINISHED != 1 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
forget_test_id

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then scripts/build.sh; fi
[[ -d "$BUILT" ]] || die "$BUILT fehlt — scripts/build.sh"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "sign_update fehlt ($SPARKLE_BIN) — swift package resolve"
N=$(plutil -extract CFBundleVersion raw "$BUILT/Contents/Info.plist")
VERSION=$(plutil -extract CFBundleShortVersionString raw "$BUILT/Contents/Info.plist")
NEW=$((N + 1))
mkdir -p "$OUT"

# Signatur-Identität von build/Knips.app (SHA-1 des Zertifikats wie in `security find-identity`), sonst ad hoc.
codesign -d --extract-certificates="$TMP/zertifikat" "$BUILT" 2>/dev/null || true
if [[ -f "$TMP/zertifikat0" ]]; then
  IDENTITY=$(shasum -a 1 "$TMP/zertifikat0" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')
else
  IDENTITY=-
fi

step "Wegwerf-Schlüssel (EdDSA) für diesen Test…"
PUBLIC=$(swift scripts/update-signature.swift new-key "$TMP/schluessel")

# make_copy <ordner> <build>: Testkopie von build/Knips.app mit Testkennung, Wegwerf-Schlüssel und Build-Nummer.
# Neu signiert wird nur die App selbst (Sparkle.framework darin hat build.sh schon signiert), ohne --deep.
make_copy() {
  local app="$1/Knips.app"
  mkdir -p "$1"
  ditto "$BUILT" "$app"
  plutil -replace CFBundleIdentifier -string "$TEST_ID" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$2" "$app/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$PUBLIC" "$app/Contents/Info.plist"
  codesign --force --options runtime --entitlements Resources/Knips.entitlements --identifier "$TEST_ID" \
    --timestamp=none --sign "$IDENTITY" "$app" 2>/dev/null
  codesign --verify --deep --strict "$app"
}
step "Testkopien in $TMP: alt (Build $N) und neu (Build $NEW)…"
make_copy "$TMP/alt" "$N"
make_copy "$TMP/neu" "$NEW"

step "DMG wie scripts/package.sh…"
FEED="$TMP/feed"
STAGE="$TMP/dmg"
DMG_NAME="Knips-$VERSION-$NEW.dmg"
mkdir -p "$FEED" "$STAGE"
ditto "$TMP/neu/Knips.app" "$STAGE/Knips.app"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Zuerst lesen.txt" "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"
hdiutil create -volname "Knips $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$FEED/$DMG_NAME" >/dev/null
if [[ "$IDENTITY" != "-" ]]; then codesign --force --timestamp=none --sign "$IDENTITY" "$FEED/$DMG_NAME" 2>/dev/null; fi

step "Signatur mit sign_update (Wegwerf-Schlüssel), Prüfung gegen SUPublicEDKey der alten App…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --ed-key-file "$TMP/schluessel" -p "$FEED/$DMG_NAME") || die "sign_update: $SIGNATURE"
swift scripts/update-signature.swift verify "$TMP/alt/Knips.app" "$FEED/$DMG_NAME" "$SIGNATURE" | indent
# Gültige Signatur, aber über andere Daten — muss abgelehnt werden.
WRONG=$("$SPARKLE_BIN/sign_update" --ed-key-file "$TMP/schluessel" -p LICENSE) || die "sign_update: $WRONG"
if swift scripts/update-signature.swift verify "$TMP/alt/Knips.app" "$FEED/$DMG_NAME" "$WRONG" >/dev/null 2>&1; then
  die "Gegenprobe: Die falsche Signatur gilt als richtig."
fi
echo "   ✓ Gegenprobe: falsche Signatur abgelehnt"

step "Feeds (scripts/appcast.sh)…"
scripts/appcast.sh "$TMP/neu/Knips.app" "$FEED/$DMG_NAME" "__BASE__/$DMG_NAME" \
  "https://github.com/patrickbirkholz0000/knips/releases/tag/v$VERSION" "$SIGNATURE" >"$FEED/appcast.xml"
# derive <ziel> <suchen> <ersetzen>: Variante des richtigen Feeds; bricht ab, wenn nichts ersetzt wurde.
derive() {
  FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$FEED/appcast.xml" >"$FEED/$1"
  ! cmp -s "$FEED/appcast.xml" "$FEED/$1" || die "$1: nichts ersetzt."
}
derive appcast-falsch.xml "sparkle:edSignature=\"$SIGNATURE\"" "sparkle:edSignature=\"$WRONG\""
derive appcast-gleich.xml "<sparkle:version>$NEW</sparkle:version>" "<sparkle:version>$N</sparkle:version>"
derive appcast-aelter.xml "<sparkle:version>$NEW</sparkle:version>" "<sparkle:version>$((N - 1))</sparkle:version>"
xmllint --noout "$FEED"/appcast*.xml
cp "$FEED/appcast.xml" "$OUT/appcast-beispiel.xml"
sed 's/^/   /' "$FEED/appcast.xml"

# Der Beobachter läuft schon während der alten Fassung: Er sieht die ganze Zeit nach Fenstern (Testkopie, Sparkles
# Installer) und wartet auf Build N+1.
"$BUILT/Contents/MacOS/Knips" --selftest update-installed "$OUT/installiert" "$TMP/alt/Knips.app" "$NEW" >"$TMP/beobachter.log" 2>&1 &
WATCHER=$!

step "Alte Fassung: Gegenproben, dann das Update laden und prüfen (--selftest update)…"
if ! "$TMP/alt/Knips.app/Contents/MacOS/Knips" --selftest update "$OUT/alt" "$FEED"; then
  kill "$WATCHER" 2>/dev/null || true
  die "Selbsttest update in der alten Fassung fehlgeschlagen."
fi

step "Installation beim Beenden (--selftest update-installed, lief nebenher)…"
if ! wait "$WATCHER"; then
  cat "$TMP/beobachter.log"
  die "Installation nicht wie erwartet."
fi
grep -v -e "^OK$" -e "sandbox_extension" "$TMP/beobachter.log"
codesign --verify --deep --strict "$TMP/alt/Knips.app" || die "codesign: Signatur der aktualisierten App ungültig."
codesign -dvv "$TMP/alt/Knips.app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)=' | head -3 | indent
INSTALLED=$(plutil -extract CFBundleVersion raw "$TMP/alt/Knips.app/Contents/Info.plist")
[[ "$INSTALLED" == "$NEW" ]] || die "In $TMP/alt liegt Build $INSTALLED statt $NEW."

echo "✓ Build $N → $NEW aktualisiert, ohne Neustart und ohne Fenster; codesign --verify --strict: gültig"
FINISHED=1
