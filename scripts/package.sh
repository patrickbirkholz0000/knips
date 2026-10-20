#!/bin/bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen „…“ in den Meldungen sind gewollt
# Baut das Installationspaket für andere Macs: build/Knips-<version>-<build>.dmg (Universal: Apple Silicon +
# Intel), signiert mit Developer ID, von Apple notarisiert und „gestapelt“ (Ticket im Paket, prüft auch offline),
# daneben die SHA-256-Prüfsumme. Ablauf: Build (RELEASE=1, Universal, Hardened Runtime, Zeitstempel) →
# App zippen → notarisieren → Ticket an die App → DMG (mit LICENSE und „Zuerst lesen.txt“) → DMG signieren →
# notarisieren → Ticket ans DMG → Prüfungen (codesign, spctl, stapler) → SHA-256.
#
# Einmalige Einrichtung (ausführlich in RELEASING.md):
#   1. Developer-ID-Zertifikat — kann nur der Account Holder des Teams anlegen:
#        Xcode → Settings… → Accounts → Team „Birkholz & Rabitzsch GbR“ (S8QR9YWZS7) → Manage Certificates… →
#        „+“ → „Developer ID Application“.  Prüfen: security find-identity -v -p codesigning
#   2. Zugang für die Notarisierung als Schlüsselbund-Profil „knips“ ablegen, entweder mit einem
#      App-Store-Connect-API-Schlüssel (Benutzer und Zugriff → Integrationen → Team-Schlüssel):
#        xcrun notarytool store-credentials knips --key ~/…/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
#      oder mit Apple-ID und app-spezifischem Passwort (account.apple.com → App-spezifische Passwörter):
#        xcrun notarytool store-credentials knips --apple-id kontakt@birkgroup.de --team-id S8QR9YWZS7
#      Prüfen: xcrun notarytool history --keychain-profile knips
#
# Variablen:
#   NOTARIZE=0             lokales Test-DMG ohne Notarisierung, mit der Identität, die build.sh für RELEASE=1
#                          wählt (Developer ID, sonst Apple Development) — NICHT zur Weitergabe
#   KNIPS_SIGN_IDENTITY    SHA-1 oder exakter Name der Signatur-Identität (sonst die erste „Developer ID Application“)
#   KNIPS_NOTARY_PROFILE   Schlüsselbund-Profil für notarytool (Standard: knips)
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=${NOTARIZE:-1}
PROFILE=${KNIPS_NOTARY_PROFILE:-knips}
APP=build/Knips.app
LICENSE_FILE=LICENSE
README_FILE="Resources/Zuerst lesen.txt"
TMP=$(mktemp -d -t knips-package)
MOUNT=""
FINISHED=0

# bash 3.2 meldet nach einem Fehler durch `set -u` im EXIT-Trap Status 0 — daher zusätzlich FINISHED.
cleanup() {
  local rc=$?
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
  rm -rf "$TMP" build/dmg
  if [[ $rc -eq 0 && $FINISHED != 1 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT

die() { echo "✗ $*" >&2; exit 1; }
indent() { sed "s/^/${1:-   }/"; }

not_for_distribution() {
  cat >&2 <<'EOF'

  ┌──────────────────────────────────────────────────────────────────────┐
  │  NOTARIZE=0 — TEST-DMG, NICHT ZUR WEITERGABE                         │
  │  Nicht notarisiert: Gatekeeper blockiert es auf anderen Macs.        │
  │  Für Weitergabe und GitHub-Releases: scripts/package.sh ohne         │
  │  NOTARIZE=0 (bzw. scripts/release.sh).                               │
  └──────────────────────────────────────────────────────────────────────┘

EOF
}

# --- Signatur-Identität (als SHA-1) ------------------------------------------------------------------
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
identity_name() { awk -v h="$1" '$2 == h { sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }' <<<"$IDENTITIES"; }

SHA=""
if [[ -n "${KNIPS_SIGN_IDENTITY:-}" ]]; then
  if [[ "$KNIPS_SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    SHA=$(tr '[:lower:]' '[:upper:]' <<<"$KNIPS_SIGN_IDENTITY")
  else
    SHA=$(awk -v n="$KNIPS_SIGN_IDENTITY" 'index($0, "\"" n "\"") { print $2 }' <<<"$IDENTITIES" | sort -u)
    [[ $(grep -c . <<<"$SHA") -le 1 ]] || die "KNIPS_SIGN_IDENTITY '${KNIPS_SIGN_IDENTITY}' ist mehrdeutig — bitte die SHA-1 angeben."
  fi
  [[ -n "$SHA" && -n "$(identity_name "$SHA")" ]] || die "KNIPS_SIGN_IDENTITY '${KNIPS_SIGN_IDENTITY}' ist keine gültige Signatur-Identität."
else
  SHA=$(awk '/"Developer ID Application: / { print $2; exit }' <<<"$IDENTITIES")
fi
NAME=""
if [[ -n "$SHA" ]]; then NAME=$(identity_name "$SHA"); fi

if [[ "$NOTARIZE" != "0" ]]; then
  if [[ "$NAME" != "Developer ID Application: "* ]]; then
    cat >&2 <<EOF
✗ Keine „Developer ID Application“-Identität${NAME:+ (gewählt: $NAME)}.
  Ohne Developer ID kann Apple Knips nicht notarisieren, und Gatekeeper blockiert es auf anderen Macs.

  Einmalig anlegen (nur als Account Holder des Teams „Birkholz & Rabitzsch GbR“, S8QR9YWZS7):
    Xcode → Settings… → Accounts → Team auswählen → Manage Certificates… → „+“ → „Developer ID Application“
  Danach muss es hier erscheinen:  security find-identity -v -p codesigning

  Nur ein lokales Test-DMG bauen (nicht zur Weitergabe):  NOTARIZE=0 scripts/package.sh
EOF
    exit 1
  fi
  [[ -f "$LICENSE_FILE" ]] || die "$LICENSE_FILE fehlt — die GPL verlangt, dass der Lizenztext mitgeliefert wird."
  export KNIPS_TIMESTAMP=1
else
  not_for_distribution
  [[ -f "$LICENSE_FILE" ]] || echo "⚠︎ $LICENSE_FILE fehlt — das Test-DMG kommt ohne Lizenztext." >&2
fi
[[ -f "$README_FILE" ]] || die "$README_FILE fehlt."
if [[ -n "$SHA" ]]; then export KNIPS_SIGN_IDENTITY="$SHA"; fi

# --- Build ---------------------------------------------------------------------------------------------
RELEASE=1 UNIVERSAL=1 scripts/build.sh
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Knips")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || die "Kein Universal-Binary (Architekturen: $ARCHS)."
if [[ -z "$SHA" ]]; then
  # build.sh hat mangels Developer ID die Apple-Development-Identität (oder ad hoc) genommen.
  AUTH=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')
  if [[ -n "$AUTH" ]]; then SHA=$(awk -v n="$AUTH" 'index($0, "\"" n "\"") { print $2; exit }' <<<"$IDENTITIES"); fi
  if [[ -n "$SHA" ]]; then NAME=$(identity_name "$SHA"); fi
fi

# Statische Prüfung der App-Signatur, bevor etwas zu Apple geht: check_app_signature <app>
check_app_signature() {
  local info ents
  info=$(codesign -dvv "$1" 2>&1)
  ents=$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info" || die "App ohne Hardened Runtime signiert."
  grep -q '^Timestamp=' <<<"$info" || die "App-Signatur ohne sicheren Zeitstempel."
  grep -q '^Authority=Developer ID Application: ' <<<"$info" || die "App nicht mit Developer ID signiert."
  grep -q '^TeamIdentifier=S8QR9YWZS7$' <<<"$info" || echo "⚠︎ TeamIdentifier ist nicht S8QR9YWZS7." >&2
  ! grep -q 'get-task-allow' <<<"$ents" || die "Entitlements enthalten get-task-allow — Apple lehnt das ab."
  grep -E '^(Identifier|CodeDirectory|Authority|Timestamp|TeamIdentifier)=?' <<<"$info" | indent
}

# --- Notarisierung -------------------------------------------------------------------------------------
PROFILE_OK=0
check_profile() {
  if [[ "$PROFILE_OK" == "1" ]]; then return 0; fi
  local err="$TMP/profile.err"
  if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null 2>"$err"; then
    indent <"$err" >&2
    cat >&2 <<EOF
✗ Notarisierung nicht möglich: Profil „${PROFILE}“ fehlt oder wird von Apple abgelehnt.
  Einmalig anlegen (API-Schlüssel aus App Store Connect → Benutzer und Zugriff → Integrationen):
    xcrun notarytool store-credentials $PROFILE --key ~/…/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
  oder mit Apple-ID und app-spezifischem Passwort:
    xcrun notarytool store-credentials $PROFILE --apple-id kontakt@birkgroup.de --team-id S8QR9YWZS7
  Bei HTTP 403 („agreement“): neue Vereinbarungen auf developer.apple.com/account annehmen (Account Holder).
  Prüfen: xcrun notarytool history --keychain-profile $PROFILE
  Die App ist gebaut und signiert ($APP), aber nicht notarisiert — nicht weitergeben.
EOF
    exit 1
  fi
  PROFILE_OK=1
}

# notarize <datei> <bezeichnung>: einreichen, warten, bei allem außer „Accepted“ das Protokoll zeigen und abbrechen.
notarize() {
  local file=$1 label=$2 out="$TMP/notary.json" err="$TMP/notary.err" id status
  check_profile
  echo "→ Notarisierung bei Apple: $label (meist 1–10 Minuten, höchstens 30)…"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 30m \
    --output-format json >"$out" 2>"$err" || true
  # Beim Zeitlimit steht das JSON (mit der ID) auf stderr statt stdout.
  id=$(plutil -extract id raw -o - "$out" 2>/dev/null || plutil -extract id raw -o - "$err" 2>/dev/null || true)
  status=$(plutil -extract status raw -o - "$out" 2>/dev/null || true)
  if [[ "$status" != "Accepted" ]]; then
    cat "$out" "$err" >&2
    if [[ -n "$id" && ( "$status" == "Invalid" || "$status" == "Rejected" ) ]]; then
      echo "→ Protokoll von Apple:" >&2
      xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    elif [[ -n "$id" ]]; then
      echo "  Einreichung $id ist noch nicht fertig. Später prüfen:" >&2
      echo "    xcrun notarytool info $id --keychain-profile $PROFILE" >&2
    fi
    die "Notarisierung von $label fehlgeschlagen (Status: ${status:-unbekannt})."
  fi
  echo "   ✓ Accepted ($id)"
}

if [[ "$NOTARIZE" != "0" ]]; then
  echo "→ Prüfe App-Signatur…"
  check_app_signature "$APP"
  ZIP="$TMP/Knips.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP" "Knips.app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- DMG -------------------------------------------------------------------------------------------------
STAGE=build/dmg
if [[ "$NOTARIZE" != "0" ]]; then
  DMG="build/Knips-$VERSION-$BUILD.dmg"
else
  DMG="build/Knips-$VERSION-$BUILD-nicht-notarisiert.dmg"
fi
echo "→ Baue ${DMG}…"
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Knips.app"
ln -s /Applications "$STAGE/Applications"
cp "$README_FILE" "$STAGE/"
if [[ -f "$LICENSE_FILE" ]]; then cp "$LICENSE_FILE" "$STAGE/LICENSE.txt"; fi
hdiutil create -volname "Knips $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "$SHA" ]]; then
  if [[ "$NAME" == "Developer ID Application: "* ]]; then TS=(--timestamp); else TS=(--timestamp=none); fi
  codesign --force "${TS[@]}" --sign "$SHA" "$DMG"
fi

if [[ "$NOTARIZE" != "0" ]]; then
  notarize "$DMG" "$(basename "$DMG")"
  xcrun stapler staple "$DMG"
fi

# --- Prüfungen ---------------------------------------------------------------------------------------------
echo "→ Prüfe Ergebnis…"
codesign --verify --deep --strict -vv "$APP"
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
[[ -d "$MOUNT/Knips.app" ]] || die "DMG enthält keine Knips.app."
echo "   DMG-Inhalt: $(cd "$MOUNT" && find . -maxdepth 1 -mindepth 1 ! -name '.*' | sed 's|^\./||' | sort | paste -sd ',' - | sed 's/,/, /g')"
codesign --verify --deep --strict "$MOUNT/Knips.app"
if [[ "$NOTARIZE" != "0" ]]; then
  check_app_signature "$MOUNT/Knips.app" >/dev/null
  xcrun stapler validate "$MOUNT/Knips.app"
  spctl -a -vvv -t exec "$MOUNT/Knips.app" 2>&1 | indent || true
  spctl -a -t exec "$MOUNT/Knips.app" 2>/dev/null || die "Gatekeeper lehnt die App im DMG ab."
fi
hdiutil detach "$MOUNT" -quiet
MOUNT=""

if [[ "$NOTARIZE" != "0" ]]; then
  APP_GK=$(spctl -a -vvv -t exec "$APP" 2>&1 || true)
  DMG_GK=$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)
  indent <<<"$APP_GK"
  indent <<<"$DMG_GK"
  [[ "$APP_GK" == *accepted* && "$APP_GK" == *"Notarized Developer ID"* ]] || die "Gatekeeper akzeptiert die App nicht als notarisiert."
  [[ "$DMG_GK" == *accepted* && "$DMG_GK" == *"Notarized Developer ID"* ]] || die "Gatekeeper akzeptiert das DMG nicht als notarisiert."
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
else
  # Zur Information: ohne Notarisierung lehnt Gatekeeper ab („Unnotarized Developer ID“ o. Ä.).
  spctl -a -vvv -t exec "$APP" 2>&1 | indent '   App: ' || true
  spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | indent '   DMG: ' || true
fi

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) — signiert: ${NAME:-ad hoc}"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG.sha256")  → $DMG.sha256"
if [[ "$NOTARIZE" != "0" ]]; then
  echo "  notarisiert und gestapelt — bereit zur Weitergabe."
else
  not_for_distribution
fi
FINISHED=1
