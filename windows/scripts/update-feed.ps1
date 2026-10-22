# Updater-Signatur für einen fertigen Installer und latest.json dazu (release.yml; Probe in windows.yml: Job „signatur“
# und scripts/update-test.ps1). Aus windows/ aufrufen, nach `pnpm install`. Signiert genau die übergebene Datei — in
# release.yml also den endgültigen (SignPath-)Installer, der so auch im Release liegt.
#
# Schlüssel über die Umgebung, nie über die Befehlszeile: TAURI_SIGNING_PRIVATE_KEY (Inhalt der Schlüsseldatei) und,
# wenn der Schlüssel ein Passwort hat, TAURI_SIGNING_PRIVATE_KEY_PASSWORD. Fehlt der Schlüssel: Abbruch mit Grund.
# Geprüft wird die Signatur danach gegen den öffentlichen Schlüssel aus src-tauri/tauri.conf.json (oder -PubKey).
param(
  [Parameter(Mandatory = $true)] [string]$Installer,
  [Parameter(Mandatory = $true)] [string]$Version,
  [Parameter(Mandatory = $true)] [string]$Url,
  [Parameter(Mandatory = $true)] [string]$Out,
  [string]$Notes = '',
  [string]$PubKey = '',
  [switch]$AllowHttp
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not $env:TAURI_SIGNING_PRIVATE_KEY) {
  throw 'TAURI_SIGNING_PRIVATE_KEY fehlt: Ohne den Updater-Schlüssel gibt es keine latest.json, und installierte Fassungen fänden das Update nicht. Einrichtung: RELEASING.md, Abschnitt „Automatische Updates (Windows)“.'
}
if ($env:TAURI_SIGNING_PRIVATE_KEY_PATH) { throw 'TAURI_SIGNING_PRIVATE_KEY_PATH bitte nicht setzen (der Schlüssel kommt aus TAURI_SIGNING_PRIVATE_KEY).' }
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { throw "Installer fehlt: $Installer" }
$file = (Resolve-Path -LiteralPath $Installer).ProviderPath
$before = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash

Remove-Item -LiteralPath "$file.sig" -ErrorAction SilentlyContinue
# Schlüssel und Passwort liest `tauri signer sign` aus der Umgebung; --app-version bindet die Signatur an die Version
# (die App verlangt das: requireSignedVersion).
pnpm tauri signer sign --app-version $Version $file | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Updater-Signatur fehlgeschlagen ($LASTEXITCODE) — Schlüssel oder Passwort falsch?" }
if (-not (Test-Path -LiteralPath "$file.sig")) { throw "$file.sig fehlt nach dem Signieren." }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash -ne $before) { throw 'Der Installer hat sich beim Signieren verändert.' }

$feedArgs = @('scripts/update-feed.mjs', '--installer', $file, '--version', $Version, '--url', $Url, '--out', $Out)
if ($Notes) { $feedArgs += @('--notes', $Notes) }
if ($PubKey) { $feedArgs += @('--pubkey', $PubKey) }
if ($AllowHttp) { $feedArgs += '--allow-http' }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
node @feedArgs | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'latest.json nicht erzeugt: Die Signatur passt nicht zum öffentlichen Schlüssel in tauri.conf.json (oder -PubKey).' }
