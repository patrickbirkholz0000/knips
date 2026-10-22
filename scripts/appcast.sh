#!/bin/bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen „…“ in den Meldungen sind gewollt
# Schreibt das appcast.xml für die automatischen Updates der Mac-App (Sparkle) mit genau einer Version auf stdout:
#
#   scripts/appcast.sh <Knips.app> <dmg> <dmg-url> <release-seite> <eddsa-signatur> > appcast.xml
#
# Version (sparkle:shortVersionString), Build-Nummer (sparkle:version) und das mindestens nötige macOS kommen aus der
# Info.plist der gebauten App, die Länge aus dem DMG, die Signatur von Sparkles sign_update. Jedes Release hängt sein
# eigenes appcast.xml an; Knips liest immer das des neuesten veröffentlichten Releases
# (SUFeedURL = …/releases/latest/download/appcast.xml). Aufgerufen von scripts/release.sh und scripts/update-test.sh.
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Aufruf: scripts/appcast.sh <Knips.app> <dmg> <dmg-url> <release-seite> <eddsa-signatur>" >&2
  exit 2
fi
APP=$1
DMG=$2
URL=$3
LINK=$4
SIGNATURE=$5
PLIST="$APP/Contents/Info.plist"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
LENGTH=$(stat -f %z "$DMG")
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "✗ Build-Nummer „$BUILD“ ist keine Zahl." >&2; exit 1; }
[[ "$LENGTH" -gt 0 ]] || { echo "✗ $DMG ist leer." >&2; exit 1; }
# Nur Zeichen, die in XML nichts bedeuten (Versionen, URLs, base64) — dann muss nichts maskiert werden.
for value in "$VERSION" "$MIN_OS" "$URL" "$LINK" "$SIGNATURE"; do
  [[ "$value" =~ ^[A-Za-z0-9._:/+=%~_-]+$ ]] || { echo "✗ Unerwartetes Zeichen in „$value“." >&2; exit 1; }
done

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Knips</title>
    <link>${LINK%%/releases/*}</link>
    <description>Neue Versionen von Knips für macOS</description>
    <language>de</language>
    <item>
      <title>Knips $VERSION</title>
      <link>$LINK</link>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
