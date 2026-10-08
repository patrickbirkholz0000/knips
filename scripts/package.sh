#!/bin/zsh
# Baut ein Installationspaket (DMG) für andere Macs: Universal (Apple Silicon + Intel), mit Anleitung.
#
# Ohne Developer-ID-Zertifikat: signiert mit der eigenen „Apple Development“-Identität. Auf anderen Macs
# muss Knips dann einmal unter Datenschutz & Sicherheit freigegeben werden (steht in „Zuerst lesen“).
#
# Mit Developer ID + Notarisierung (keine Warnung beim Kollegen):
#   KNIPS_SIGN_IDENTITY="Developer ID Application: …" KNIPS_NOTARY_PROFILE=knips scripts/package.sh
#   Profil einmalig anlegen: xcrun notarytool store-credentials knips --apple-id <mail> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=1 UNIVERSAL=1 scripts/build.sh
APP=build/Knips.app
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !f {print $2; f=1}')

if [[ -n "${KNIPS_NOTARY_PROFILE:-}" ]]; then
  echo "→ Hardened Runtime für die Notarisierung…"
  codesign --force --options runtime --timestamp --entitlements Resources/Knips.entitlements \
    --sign "${KNIPS_SIGN_IDENTITY:?Developer-ID-Identität angeben}" --identifier de.birkgroup.knips "$APP"
fi

STAGE=build/dmg
DMG="build/Knips-$VERSION-$BUILD.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Zuerst lesen.txt" "$STAGE/"
hdiutil create -volname "Knips $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${KNIPS_NOTARY_PROFILE:-}" ]]; then
  codesign --force --timestamp --sign "$KNIPS_SIGN_IDENTITY" "$DMG"
  echo "→ Notarisierung bei Apple…"
  xcrun notarytool submit "$DMG" --keychain-profile "$KNIPS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG" 2>/dev/null || true
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) — signiert: ${IDENTITY:-ad hoc}"
