#!/bin/bash
# Erzeugt die winget-Manifeste (für microsoft/winget-pkgs) einer veröffentlichten Knips-Version aus den
# Vorlagen in windows/winget/.
#
#   scripts/winget-manifest.sh 1.0.0                      → build/winget/manifests/p/PatrickBirkholz/Knips/1.0.0/
#   scripts/winget-manifest.sh 1.0.0 --out <ordner>       anderer Zielordner (darunter manifests/p/…)
#   scripts/winget-manifest.sh 1.0.0 --installer <datei>  SHA-256 aus einer lokalen Datei, ohne Netz (zum Testen)
#
# Ohne --installer muss das Release v<version> veröffentlicht sein (kein Entwurf): Das Skript lädt den Installer
# über dieselbe URL wie winget, prüft ihn gegen die .sha256 aus dem Release und trägt URL, SHA-256 und Datum ein.
# Mit python3 + jsonschema + PyYAML prüft es die Dateien zusätzlich gegen die offiziellen JSON-Schemas.
# Einreichen: RELEASING.md, Abschnitt winget.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "✗ $*" >&2; exit 1; }

REPO=patrickbirkholz0000/knips
ID=PatrickBirkholz.Knips
TEMPLATES=windows/winget
SCHEMA_VERSION=1.28.0

VERSION=${1:-}
[[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Aufruf: scripts/winget-manifest.sh X.Y.Z [--out <ordner>] [--installer <datei>]"
VERSION=${VERSION#v}
shift
OUT=build/winget
LOCAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT=${2:?--out braucht einen Ordner}; shift 2 ;;
    --installer) LOCAL=${2:?--installer braucht eine Datei}; shift 2 ;;
    *) die "Unbekannte Option: $1" ;;
  esac
done

EXE="Knips_${VERSION}_x64-setup.exe"
URL="https://github.com/$REPO/releases/download/v$VERSION/$EXE"

if [[ -n "$LOCAL" ]]; then
  [[ -f "$LOCAL" ]] || die "Datei nicht gefunden: $LOCAL"
  SHA=$(shasum -a 256 "$LOCAL" | cut -d' ' -f1)
  DATE=$(date -u +%Y-%m-%d)
  echo "→ SHA-256 aus $LOCAL (nicht aus dem Release)"
else
  echo "→ Hole Release v${VERSION}…"
  RELEASE=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/tags/v$VERSION") ||
    die "Release v$VERSION nicht gefunden oder noch nicht veröffentlicht (Entwürfe sind für winget nicht erreichbar)."
  DATE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["published_at"][:10])' <<<"$RELEASE")
  ASSET_URL=$(python3 -c 'import json,sys
r = json.load(sys.stdin)
print(next((a["browser_download_url"] for a in r["assets"] if a["name"] == sys.argv[1]), ""))' "$EXE" <<<"$RELEASE")
  [[ "$ASSET_URL" == "$URL" ]] || die "$EXE hängt nicht am Release v$VERSION (gefunden: '${ASSET_URL}')."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "→ Lade $EXE und $EXE.sha256…"
  curl -fsSL -o "$TMP/$EXE" "$URL" || die "Download von $URL fehlgeschlagen."
  curl -fsSL -o "$TMP/$EXE.sha256" "$URL.sha256" || die "Download von $URL.sha256 fehlgeschlagen."
  (cd "$TMP" && shasum -a 256 -c "$EXE.sha256" >/dev/null) || die "Prüfsumme von $EXE stimmt nicht mit $EXE.sha256 überein."
  SHA=$(shasum -a 256 "$TMP/$EXE" | cut -d' ' -f1)
fi
SHA=$(tr '[:lower:]' '[:upper:]' <<<"$SHA")

DIR="$OUT/manifests/p/PatrickBirkholz/Knips/$VERSION"
mkdir -p "$DIR"
for template in "$TEMPLATES"/"$ID".*yaml; do
  name=$(basename "$template")
  # Erste Zeile der Vorlage (Hinweis „Vorlage für …“) durch die Herkunft ersetzen.
  {
    echo "# Erzeugt mit scripts/winget-manifest.sh aus https://github.com/$REPO"
    tail -n +2 "$template" | sed -e "s|{{VERSION}}|$VERSION|g" -e "s|{{SHA256}}|$SHA|g" -e "s|{{RELEASE_DATE}}|$DATE|g"
  } >"$DIR/$name"
  if grep -q '{{' "$DIR/$name"; then die "$DIR/$name enthält noch Platzhalter."; fi
done
echo "✓ Manifeste in $DIR:"
for file in "$DIR"/*.yaml; do echo "    $(basename "$file")"; done

# Prüfen gegen die offiziellen Schemas (https://aka.ms/winget-manifest.<typ>.<version>.schema.json).
if python3 -c 'import jsonschema, yaml' 2>/dev/null; then
  python3 - "$DIR" "$SCHEMA_VERSION" <<'PY'
import json, pathlib, sys, urllib.request
import jsonschema, yaml

folder, version = pathlib.Path(sys.argv[1]), sys.argv[2]
failed = False
for path in sorted(folder.glob("*.yaml")):
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    kind = data["ManifestType"]
    url = f"https://aka.ms/winget-manifest.{kind}.{version}.schema.json"
    with urllib.request.urlopen(url, timeout=30) as response:
        schema = json.load(response)
    # YAML liest Datumsangaben als date — das Schema erwartet Zeichenketten.
    data = json.loads(json.dumps(data, default=str))
    errors = list(jsonschema.Draft7Validator(schema).iter_errors(data))
    for error in errors:
        print(f"✗ {path.name}: {'/'.join(map(str, error.path))}: {error.message}")
    failed |= bool(errors)
    if not errors:
        print(f"  Schema ok: {path.name} ({kind} {version})")
sys.exit(1 if failed else 0)
PY
else
  echo "  (Schema-Prüfung übersprungen: python3 mit jsonschema und PyYAML fehlt — pip install jsonschema pyyaml)"
fi

cat <<EOF

Nächste Schritte (RELEASING.md, Abschnitt winget):
  - Unter Windows prüfen:   winget validate --manifest $DIR
                            winget install --manifest $DIR   (lokale Manifeste erlauben: winget settings --enable LocalManifestFiles)
  - Einreichen: Ordner manifests/p/PatrickBirkholz/Knips/$VERSION in einen Fork von microsoft/winget-pkgs
    kopieren und einen Pull Request stellen (oder: wingetcreate submit $DIR).
EOF
