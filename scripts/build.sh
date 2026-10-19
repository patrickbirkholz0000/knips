#!/bin/bash
# Baut build/Knips.app (Release) und signiert es — immer mit Hardened Runtime und Resources/Knips.entitlements.
#
# Signatur-Identität (es wird immer per SHA-1 signiert, Namen sind nicht eindeutig):
#   1. KNIPS_SIGN_IDENTITY (SHA-1 oder exakter Name aus `security find-identity -v -p codesigning`,
#      „-“ = ad hoc) — gilt für eigene und für Weitergabe-Builds
#   2. RELEASE=1 (Weitergabe, package.sh): die erste gültige „Developer ID Application“-Identität
#   3. sonst wie bisher die letzte „Apple Development“-Identität der Liste. Eigene Builds (install.sh)
#      bleiben damit bei derselben Identität, die Bildschirmaufnahme-Freigabe der installierten App bleibt.
#   4. sonst ad hoc (Freigabe muss nach jedem Build neu erteilt werden)
# Developer ID wird mit sicherem Zeitstempel signiert (braucht Netz), Apple Development ohne (schnell,
# offline). KNIPS_TIMESTAMP=1 bzw. =0 erzwingt bzw. unterdrückt ihn.
#
# Variablen: RELEASE=1 (ohne Entwickler-Code, ohne Symbole), UNIVERSAL=1 (arm64 + x86_64).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Knips.app
BUNDLE_ID=de.birkgroup.knips
ENTITLEMENTS=Resources/Knips.entitlements
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift

# --- Signatur-Identität bestimmen --------------------------------------------------------------------
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
# Name zu einer SHA-1 aus der Liste (leer, wenn nicht vorhanden).
identity_name() { awk -v h="$1" '$2 == h { sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }' <<<"$IDENTITIES"; }

IDENTITY=${KNIPS_SIGN_IDENTITY:-}
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  if [[ ! "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    MATCHES=$(awk -v n="$IDENTITY" 'index($0, "\"" n "\"") { print $2 }' <<<"$IDENTITIES" | sort -u)
    if [[ -z "$MATCHES" ]]; then
      echo "✗ KNIPS_SIGN_IDENTITY '${IDENTITY}' ist keine gültige Signatur-Identität." >&2; exit 1
    elif [[ $(wc -l <<<"$MATCHES") -gt 1 ]]; then
      echo "✗ KNIPS_SIGN_IDENTITY '${IDENTITY}' ist mehrdeutig — bitte die SHA-1 angeben:" >&2
      grep -F "\"$IDENTITY\"" <<<"$IDENTITIES" >&2; exit 1
    fi
    IDENTITY=$MATCHES
  fi
  IDENTITY=$(tr '[:lower:]' '[:upper:]' <<<"$IDENTITY")
  [[ -n "$(identity_name "$IDENTITY")" ]] || { echo "✗ Keine gültige Signatur-Identität mit SHA-1 $IDENTITY." >&2; exit 1; }
elif [[ -z "$IDENTITY" ]]; then
  if [[ "${RELEASE:-0}" == "1" ]]; then
    IDENTITY=$(awk '/"Developer ID Application: / { print $2; exit }' <<<"$IDENTITIES")
  fi
  # Unverändert die bisherige Auswahl (letzte „Apple Development“-Zeile), damit die Freigabe bleibt.
  [[ -n "$IDENTITY" ]] || IDENTITY=$(awk '/Apple Development/ {print $2}' <<<"$IDENTITIES" | tail -1)
fi

SIGN=(--force --options runtime --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID")
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "⚠︎ Keine Signatur-Identität gefunden — ad hoc signiert (Freigabe muss nach jedem Update neu erteilt werden)."
  IDENTITY="-"
  NAME="ad hoc"
  SIGN+=(--timestamp=none)
else
  NAME=$(identity_name "$IDENTITY")
  TIMESTAMP=0
  [[ "$NAME" == "Developer ID Application: "* ]] && TIMESTAMP=1
  TIMESTAMP=${KNIPS_TIMESTAMP:-$TIMESTAMP}
  if [[ "$TIMESTAMP" == "1" ]]; then SIGN+=(--timestamp); else SIGN+=(--timestamp=none); fi
fi

# Eigene Builds enthalten Selbsttests und Test-Befehle (KNIPS_DEV); RELEASE=1 lässt sie weg (Weitergabe).
SWIFT_ARGS=(-c release)
if [[ "${RELEASE:-0}" == "1" ]]; then
  echo "→ Kompiliere (Release, ohne Entwickler-Code)…"
else
  SWIFT_ARGS+=(-Xswiftc -DKNIPS_DEV)
  echo "→ Kompiliere (Release)…"
fi
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--arch arm64 --arch x86_64)
  # Die Universal-Ausgabe ist sehr lang: bei Erfolg nur Fehler/Warnungen zeigen, bei Misserfolg alles.
  # (Früher schluckte `… | grep … || true` hier Compilerfehler und baute mit einem alten Binary weiter.)
  LOG=$(mktemp -t knips-build)
  if ! swift build "${SWIFT_ARGS[@]}" >"$LOG" 2>&1; then
    cat "$LOG" >&2
    rm -f "$LOG"
    echo "✗ swift build (Universal) fehlgeschlagen." >&2
    exit 1
  fi
  grep -E "error|warning: unre" "$LOG" || true
  rm -f "$LOG"
else
  swift build "${SWIFT_ARGS[@]}"
fi
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/Knips"
[[ -x "$BIN" ]] || { echo "✗ Binary fehlt: $BIN" >&2; exit 1; }

echo "→ Baue App-Bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Knips"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Weitergabe-Build: Debug-Symbole entfernen (wie Xcode bei Release-Archiven).
if [[ "${RELEASE:-0}" == "1" ]]; then strip "$APP/Contents/MacOS/Knips"; fi

echo "→ Signiere ($IDENTITY — $NAME)…"
codesign "${SIGN[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP ($VERSION, Build $BUILD_NUMBER)"
