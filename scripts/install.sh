#!/bin/zsh
# Baut Knips, ersetzt /Applications/Knips.app und startet die App.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

echo "→ Beende laufende Instanz…"
osascript -e 'tell application id "de.birkgroup.knips" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -xq Knips || break; sleep 0.2; done
pkill -x Knips 2>/dev/null || true

echo "→ Installiere nach /Applications…"
rm -rf /Applications/Knips.app
cp -R build/Knips.app /Applications/Knips.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Knips.app

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  open /Applications/Knips.app
fi
echo "✓ /Applications/Knips.app"
