# Installer still installieren, Daten anlegen, still deinstallieren — einmal ohne, einmal mit
# „App-Daten löschen“ (/DELETEAPPDATA, siehe src-tauri/installer-hooks.nsh) — und prüfen, was bleibt.
# Nur für die CI: verändert HKCU, %LOCALAPPDATA%, %APPDATA% und %TEMP% des angemeldeten Benutzers.
# Ergebnis: <Out>\ergebnis.txt (+ Log der App). Exit 1, wenn etwas nicht stimmt.
#
#   ./scripts/uninstall-test.ps1 -Setup target/release/bundle/nsis/Knips_1.0.0_x64-setup.exe -Out shots/uninstall
param(
  [string]$Setup = "",
  [string]$Out = "shots/uninstall"
)
$ErrorActionPreference = "Stop"
if (-not $Setup) {
  $Setup = (Get-ChildItem "target/release/bundle/nsis/*-setup.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
$Setup = (Resolve-Path $Setup).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$summary = Join-Path $Out "ergebnis.txt"
Set-Content -Path $summary -Value "Deinstallation: $Setup"
$failures = New-Object System.Collections.Generic.List[string]

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  $line = if ($ok) { "OK      $name" } else { "FALSCH  $name  $detail" }
  Write-Host $line
  Add-Content -Path $summary -Value $line
  if (-not $ok) { $failures.Add($name) }
}

$id = "de.birkgroup.knips"
$instDir = Join-Path $env:LOCALAPPDATA "Knips"          # Installationsordner (currentUser)
$localData = Join-Path $env:LOCALAPPDATA $id             # Originale, WebView2, Logs
$roamingData = Join-Path $env:APPDATA $id                # settings.json
$oldRoaming = Join-Path $env:APPDATA "Knips"             # Einstellungen bis 1.0.0
$tempDir = Join-Path $env:TEMP "Knips"
$kbd = "HKCU:\Control Panel\Keyboard"
$snip = "PrintScreenKeyForSnippingEnabled"
$knipsKey = "HKCU:\Software\Knips"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

function Get-Snip { (Get-ItemProperty -Path $kbd -Name $snip -ErrorAction SilentlyContinue).$snip }
function Set-Snip($value) {
  if ($null -eq $value) { Remove-ItemProperty -Path $kbd -Name $snip -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path $kbd -Name $snip -Value $value -Type DWord }
}
$snipBefore = Get-Snip
Write-Host "Druck-Taste vorher: $(if ($null -eq $snipBefore) { 'kein Eintrag' } else { $snipBefore })"

# Wie Knips beim Übernehmen der Druck-Taste (hotkeys::set_snipping_key(false), Selbsttest `storage`).
function Take-PrintScreen {
  New-Item -Path $knipsKey -Force | Out-Null
  $current = Get-Snip
  if ($null -eq $current) { Remove-ItemProperty -Path $knipsKey -Name "PrintScreenKeyOriginal" -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path $knipsKey -Name "PrintScreenKeyOriginal" -Value $current -Type DWord }
  Set-ItemProperty -Path $knipsKey -Name "PrintScreenKeyTaken" -Value 1 -Type DWord
  Set-Snip 0
}

function Install {
  $p = Start-Process -FilePath $Setup -ArgumentList "/S" -Wait -PassThru
  $exe = Join-Path $instDir "knips.exe"
  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Path $exe)) { throw "knips.exe fehlt nach der Installation (Exit $($p.ExitCode))" }
  Write-Host "Installiert: $exe"
}

function Uninstall([string[]]$extra) {
  $uninst = Join-Path $instDir "uninstall.exe"
  if (-not (Test-Path $uninst)) { throw "uninstall.exe fehlt" }
  $p = Start-Process -FilePath $uninst -ArgumentList (@("/S") + $extra) -Wait -PassThru
  # NSIS startet sich als Kopie in %TEMP% neu (Un_A.exe) — auf das Ende dieser Kopie warten.
  $deadline = (Get-Date).AddSeconds(120)
  do {
    Start-Sleep -Milliseconds 500
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "Un_*" -or $_.ProcessName -eq "uninstall" }
  } while (($running -or (Test-Path $uninst)) -and (Get-Date) -lt $deadline)
  Start-Sleep -Seconds 2
  Write-Host "Deinstalliert ($($extra -join ' ')), Exit $($p.ExitCode)"
}

function Stop-Knips {
  Get-Process -Name "knips" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  # WebView2-Prozesse der App enden kurz danach von selbst.
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Process -Name "knips" -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  Start-Sleep -Seconds 4
}

function New-OldItem([string]$itemsDir) {
  $uuid = [guid]::NewGuid().ToString()
  $dir = Join-Path $itemsDir $uuid
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # Ein winziges, gültiges PNG (1×1) als „Original“.
  [IO.File]::WriteAllBytes((Join-Path $dir "original.png"), [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $item = @{ id = $uuid; kind = "image"; createdAt = $now; filePath = (Join-Path $env:TEMP "knips-uninstall-test.png"); pixelWidth = 1; pixelHeight = 1; scale = 1.0; revision = 1 }
  Set-Content -Path (Join-Path $dir "item.json") -Value ($item | ConvertTo-Json -Compress) -Encoding utf8NoBOM
  return $uuid
}

try {
  Stop-Knips
  foreach ($p in @($instDir, $localData, $roamingData, $oldRoaming, $tempDir)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }

  # ---------------------------------------------------------------- 1. Version 1.0.0 → neu: Umzug
  Install
  # So lag es bis 1.0.0: Originale im Installationsordner, Einstellungen in %APPDATA%\Knips.
  $oldId = New-OldItem (Join-Path $instDir "items")
  New-Item -ItemType Directory -Force -Path $oldRoaming | Out-Null
  Set-Content -Path (Join-Path $oldRoaming "settings.json") -Value '{"telemetryInstallId":"alte-kennung"}' -Encoding utf8NoBOM
  # Reste eines Absturzes: unzensierte Video-Einzelbilder, abgebrochener Export.
  New-Item -ItemType Directory -Force -Path (Join-Path $tempDir "video-thumbs") | Out-Null
  Set-Content -Path (Join-Path $tempDir "video-thumbs\$oldId-1-0.jpg") -Value "unzensiert"
  Set-Content -Path (Join-Path $tempDir "export-alt.mp4") -Value "unzensiert"

  $app = Start-Process -FilePath (Join-Path $instDir "knips.exe") -PassThru
  $migrated = Join-Path $localData "items\$oldId\original.png"
  $deadline = (Get-Date).AddSeconds(45)
  while (-not ((Test-Path $migrated) -and (Test-Path (Join-Path $localData "EBWebView"))) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 3
  Check "App läuft" (-not $app.HasExited) "Exit $($app.ExitCode)"
  Check "Umzug: Original aus dem Installationsordner geholt" ((Test-Path $migrated) -and -not (Test-Path (Join-Path $instDir "items")))
  $settingsText = Get-Content (Join-Path $roamingData "settings.json") -Raw -ErrorAction SilentlyContinue
  Check "Umzug: Einstellungen nach %APPDATA%\$id" (($settingsText -match "alte-kennung") -and -not (Test-Path $oldRoaming))
  Check "Start räumt %TEMP%\Knips auf" (-not (Test-Path (Join-Path $tempDir "video-thumbs\$oldId-1-0.jpg")) -and -not (Test-Path (Join-Path $tempDir "export-alt.mp4")))
  $autostart = $null -ne (Get-ItemProperty -Path $runKey -Name "Knips" -ErrorAction SilentlyContinue)
  Write-Host "Autostart nach dem ersten Start eingetragen: $autostart"
  $appLog = Get-ChildItem (Join-Path $localData "logs") -Filter *.log -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($appLog) { Copy-Item $appLog.FullName (Join-Path $Out "knips-erster-start.log") }
  Stop-Knips

  # ---------------------------------------------------------------- 2. Deinstallieren ohne „App-Daten löschen“
  Take-PrintScreen
  Set-Content -Path (Join-Path $tempDir "export-abgestuerzt.mp4") -Value "unzensiert"
  Uninstall @()
  Check "ohne Datenlöschen: Installationsordner weg (keine Originale mehr darin)" (-not (Test-Path $instDir)) "$(Get-ChildItem $instDir -Recurse -ErrorAction SilentlyContinue | ForEach-Object FullName)"
  Check "ohne Datenlöschen: Originale und Einstellungen bleiben" ((Test-Path $migrated) -and (Test-Path (Join-Path $roamingData "settings.json")))
  $snipNow = Get-Snip
  Check "Druck-Taste zurückgegeben" ($snipNow -eq $snipBefore) "vorher $snipBefore, jetzt $snipNow"
  Check "Vermerk HKCU\Software\Knips entfernt" (-not (Test-Path $knipsKey))
  if ($autostart) { Check "Autostart entfernt" ($null -eq (Get-ItemProperty -Path $runKey -Name "Knips" -ErrorAction SilentlyContinue)) }
  Check "knips://-Verknüpfung entfernt" (-not (Test-Path "HKCU:\Software\Classes\knips"))

  # ---------------------------------------------------------------- 3. Deinstallieren mit „App-Daten löschen“
  Install
  # Nicht gestartet: noch Originale am alten Ort (Installationsordner) und alte Einstellungen.
  $leftId = New-OldItem (Join-Path $instDir "items")
  New-Item -ItemType Directory -Force -Path $oldRoaming | Out-Null
  Set-Content -Path (Join-Path $oldRoaming "settings.json") -Value '{"telemetryInstallId":"noch-eine"}' -Encoding utf8NoBOM
  New-Item -ItemType Directory -Force -Path (Join-Path $tempDir "video-thumbs") | Out-Null
  Set-Content -Path (Join-Path $tempDir "video-thumbs\$leftId-2-0.jpg") -Value "unzensiert"
  Take-PrintScreen
  Uninstall @("/DELETEAPPDATA")
  foreach ($p in @(
      @("Installationsordner samt alter Originale", $instDir),
      @("Originale, WebView2, Logs (%LOCALAPPDATA%\$id)", $localData),
      @("Einstellungen (%APPDATA%\$id)", $roamingData),
      @("alte Einstellungen (%APPDATA%\Knips)", $oldRoaming),
      @("Zwischendateien (%TEMP%\Knips)", $tempDir))) {
    $left = if (Test-Path $p[1]) { (Get-ChildItem $p[1] -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object FullName) -join ", " } else { "" }
    Check "mit Datenlöschen weg: $($p[0])" (-not (Test-Path $p[1])) $left
  }
  $snipNow = Get-Snip
  Check "Druck-Taste zurückgegeben (mit Datenlöschen)" ($snipNow -eq $snipBefore) "vorher $snipBefore, jetzt $snipNow"
  Check "Vermerk entfernt (mit Datenlöschen)" (-not (Test-Path $knipsKey))
}
catch {
  Check "Ablauf" $false "$($_.Exception.Message)"
}
finally {
  Stop-Knips
  Set-Snip $snipBefore
  Remove-Item -Recurse -Force $knipsKey -ErrorAction SilentlyContinue
}

Write-Host ""
Get-Content $summary | ForEach-Object { Write-Host $_ }
if ($failures.Count -gt 0) { exit 1 }
