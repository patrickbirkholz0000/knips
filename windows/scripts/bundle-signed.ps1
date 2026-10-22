# Baut den NSIS-Installer um eine schon signierte knips.exe (release.yml, Signatur-Probe in windows.yml).
# Aus windows/ aufrufen, nach `pnpm install` und scripts/set-version.mjs. Ausgabe: voller Pfad des Installers.
#
# SignPath kann NSIS-Installer nicht von innen signieren. Deshalb: App-EXE signieren lassen, hier den Installer
# neu bündeln, dann den Installer signieren lassen. `tauri bundle` würde die EXE sonst „patchen“ (Bundle-Typ für
# den Updater) und damit die Signatur zerstören — daher --no-binary-patching. Ohne Bundle-Typ sucht der Updater in
# latest.json nur den Eintrag `windows-x86_64` (statt zuerst `windows-x86_64-nsis`) — genau den schreibt release.yml.
param(
  [Parameter(Mandatory = $true)] [string]$SignedExe,
  [Parameter(Mandatory = $true)] [string]$Version,
  [string]$Thumbprint = '',
  [switch]$AllowUntrustedRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$check = Join-Path $PSScriptRoot 'check-signature.ps1'
& $check -Path $SignedExe -Version $Version -Thumbprint $Thumbprint -AllowUntrustedRoot:$AllowUntrustedRoot | Out-Host
$signedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SignedExe).Hash

$target = 'target/release/knips.exe'
New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
Copy-Item -LiteralPath $SignedExe -Destination $target -Force
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue 'target/release/bundle/nsis'

pnpm tauri bundle --bundles nsis --no-binary-patching | Out-Host
if ($LASTEXITCODE -ne 0) { throw "tauri bundle fehlgeschlagen ($LASTEXITCODE)" }

if ((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash -ne $signedHash) {
  throw 'tauri bundle hat die signierte knips.exe verändert.'
}
$setup = @(Get-ChildItem 'target/release/bundle/nsis' -Filter "Knips_$($Version)_x64-setup.exe")
if ($setup.Count -ne 1) { throw "Erwartet genau einen Installer Knips_$($Version)_x64-setup.exe, gefunden: $($setup.Count)." }
# Steckt die signierte EXE wirklich im neuen Installer? (Der Installer selbst ist hier noch unsigniert.)
$probe = Join-Path ([IO.Path]::GetTempPath()) ('knips-bundle-' + [guid]::NewGuid().ToString('N'))
try {
  & 7z x -y "-o$probe" $setup[0].FullName | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "7-Zip konnte den Installer nicht auspacken ($LASTEXITCODE)." }
  $inner = @(Get-ChildItem -LiteralPath $probe -Recurse -File -Filter 'knips.exe')
  if ($inner.Count -ne 1 -or (Get-FileHash -Algorithm SHA256 -LiteralPath $inner[0].FullName).Hash -ne $signedHash) {
    throw 'Der neue Installer enthält nicht die signierte knips.exe.'
  }
} finally {
  Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Installer mit signierter App: $($setup[0].Name)"
Write-Output $setup[0].FullName
