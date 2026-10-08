#!/bin/zsh
# Baut build/Knips.app (Release) und signiert es.
# Signatur: KNIPS_SIGN_IDENTITY (SHA-1 oder Name), sonst die jüngste gültige „Apple Development“-Identität,
# sonst ad hoc. Mit fester Identität bleibt die Bildschirmaufnahme-Freigabe über Updates hinweg erhalten.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Knips.app
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift

# Eigene Builds enthalten Selbsttests und Test-Befehle (KNIPS_DEV); RELEASE=1 lässt sie weg (Weitergabe).
FLAGS=(-Xswiftc -DKNIPS_DEV)
[[ "${RELEASE:-0}" == "1" ]] && FLAGS=()
echo "→ Kompiliere (Release${RELEASE:+, ohne Entwickler-Code})…"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64 "${FLAGS[@]}" 2>&1 | grep -E "error|warning: unre" || true
  BIN="$(swift build -c release --arch arm64 --arch x86_64 "${FLAGS[@]}" --show-bin-path)/Knips"
else
  swift build -c release "${FLAGS[@]}"
  BIN=.build/release/Knips
fi

echo "→ Baue App-Bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Knips"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Weitergabe-Build: Debug-Symbole entfernen (wie Xcode bei Release-Archiven).
[[ "${RELEASE:-0}" == "1" ]] && strip "$APP/Contents/MacOS/Knips"

IDENTITY=${KNIPS_SIGN_IDENTITY:-}
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2}' | tail -1)
fi
if [[ -z "$IDENTITY" ]]; then
  echo "⚠︎ Keine Signatur-Identität gefunden — ad hoc signiert (Freigabe muss nach jedem Update neu erteilt werden)."
  IDENTITY="-"
fi
echo "→ Signiere ($IDENTITY)…"
codesign --force --sign "$IDENTITY" --identifier de.birkgroup.knips "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP ($VERSION, Build $BUILD_NUMBER)"
