# Ende-zu-Ende-Test der automatischen Aktualisierung (windows.yml) — installiert wirklich, nur für die CI: verändert
# HKCU, %LOCALAPPDATA%, %APPDATA% und den Bilder-Ordner des angemeldeten Benutzers. Aus windows/ aufrufen, nach
# `pnpm install` und dem Selbsttest-Build (`cargo build --profile selftest -p knips --features dev,custom-protocol`):
# Die beiden Installer entstehen mit demselben Profil, neu gebaut wird nur die App.
#
#   0. Wegwerf-Updater-Schlüssel nur für diesen Lauf (nicht das Secret von release.yml), zwei Entwickler-Installer
#      0.0.1 und 0.0.2 mit dessen öffentlichem Schlüssel (Feature `dev`: nur dort gibt es den Testkanal
#      KNIPS_UPDATE_FEED). 0.0.2 signiert und latest.json erzeugt wie in release.yml (scripts/update-feed.ps1), Feed
#      über scripts/update-server.mjs auf 127.0.0.1.
#   1. 0.0.1 still installieren; Einstellungen, eine Aufnahme (Ablage + Original) und den Druck-Tasten-Vermerk anlegen.
#   2. Gegenproben mit laufender 0.0.1: veränderter Installer, Feed nennt eine andere Version als die Signatur,
#      gleiche und ältere Version → nichts installiert, Knips läuft weiter.
#   3. Einstellung „Automatisch aktualisieren“ aus → keine automatische Suche.
#   4. Ohne Testkanal (Entwickler-Build wie in Selbsttests und CI) → nie eine Suche.
#   5. „Neu starten und aktualisieren“: automatisch suchen, laden, installieren → 0.0.2 installiert und läuft wieder;
#      Einstellungen, Ablage und Druck-Taste erhalten, Zwischenspeicher aufgeräumt.
#   6. Beenden: zurück auf 0.0.1, „Jetzt suchen“, Beenden → 0.0.2 installiert, Knips bleibt beendet.
#   7. Zwischenspeicher: zurück auf 0.0.1 → das beim Beenden geladene Update steht nach dem Start ohne Download bereit.
# Bedient wird die App über die Test-Befehle knips://debug-update-check|debug-update-install|debug-quit (nur
# Entwickler-Builds mit Testkanal). Ergebnis: <Out>\ergebnis.txt, Protokolle der App je Schritt und des Servers.
# Achtung: PowerShell liest „ und “ als Anführungszeichen — Texte mit deutschen Anführungszeichen in '…' schreiben.
param(
  [string]$Out = "shots/aktualisierung",
  [string]$CargoProfile = "selftest"
)
$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$summary = Join-Path $Out "ergebnis.txt"
Set-Content -Path $summary -Value "Aktualisierung Ende-zu-Ende"
$failures = New-Object System.Collections.Generic.List[string]

function Check([string]$name, [bool]$ok, [string]$detail = "") {
  $line = if ($ok) { "OK      $name" } else { "FALSCH  $name  $detail" }
  Write-Host $line
  Add-Content -Path $summary -Value $line
  if (-not $ok) { $failures.Add($name) }
}
function Step([string]$text) {
  Write-Host ""
  Write-Host "== $text" -ForegroundColor Cyan
  Add-Content -Path $summary -Value "== $text"
}

$id = "de.birkgroup.knips"
$instDir = Join-Path $env:LOCALAPPDATA "Knips"
$appExe = Join-Path $instDir "knips.exe"
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Knips"
$localData = Join-Path $env:LOCALAPPDATA $id
$logDir = Join-Path $localData "logs"
$cacheDir = Join-Path $localData "update"
$roamingData = Join-Path $env:APPDATA $id
$settingsFile = Join-Path $roamingData "settings.json"
$saveDir = Join-Path ([Environment]::GetFolderPath("MyPictures")) "Knips"
$capture = Join-Path $saveDir "Knips Aktualisierungstest.png"
$kbd = "HKCU:\Control Panel\Keyboard"
$snip = "PrintScreenKeyForSnippingEnabled"
$knipsKey = "HKCU:\Software\Knips"
$work = Join-Path ([IO.Path]::GetTempPath()) ("knips-update-" + [guid]::NewGuid().ToString("N"))
$feedDir = Join-Path $work "feed"
$serverLog = Join-Path $Out "server.log"
$server = $null

function Get-Snip { (Get-ItemProperty -Path $kbd -Name $snip -ErrorAction SilentlyContinue).$snip }
function Set-Snip($value) {
  if ($null -eq $value) { Remove-ItemProperty -Path $kbd -Name $snip -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -Path $kbd -Name $snip -Value $value -Type DWord }
}
$snipBefore = Get-Snip

function Wait-Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $condition) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return [bool](& $condition)
}

function Get-InstalledVersion {
  $entry = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
  if ($entry) { return [string]$entry.DisplayVersion }
  return ""
}

function Get-AppProcess {
  @(Get-Process -Name "knips" -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $appExe })
}

# Protokoll der App (alle Dateien in logs\), lesbar, während die App schreibt.
function Get-AppLog {
  $text = ""
  foreach ($f in @(Get-ChildItem -Path $logDir -Filter *.log -ErrorAction SilentlyContinue)) {
    $stream = [IO.File]::Open($f.FullName, "Open", "Read", "ReadWrite, Delete")
    try { $text += (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $stream.Dispose() }
  }
  return $text
}
function Wait-Log([string]$pattern, [int]$count = 1, [int]$seconds = 60) {
  Wait-Until { ([regex]::Matches((Get-AppLog), $pattern)).Count -ge $count } $seconds
}
function Save-Log([string]$name) { Set-Content -Path (Join-Path $Out "knips-$name.log") -Value (Get-AppLog) -Encoding utf8NoBOM }
function Clear-Log { Remove-Item -Path (Join-Path $logDir "*.log") -Force -ErrorAction SilentlyContinue }

function Get-Hits([string]$path) {
  if (-not (Test-Path $serverLog)) { return 0 }
  @(Get-Content $serverLog | Where-Object { $_ -match (" GET " + [regex]::Escape($path) + " ") }).Count
}
function Get-AllHits { if (Test-Path $serverLog) { @(Get-Content $serverLog).Count } else { 0 } }
function Set-Feed([string]$name) { Copy-Item (Join-Path $work $name) (Join-Path $feedDir "latest.json") -Force }

function Get-Settings { Get-Content -Raw $settingsFile | ConvertFrom-Json }
function Set-Setting([string]$name, $value) {
  $s = Get-Settings
  $s | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
  Set-Content -Path $settingsFile -Value ($s | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
}

# App starten, im Testkanal (Feed auf 127.0.0.1, erste automatische Suche nach 2 s) oder ohne.
function Start-App([switch]$NoFeed) {
  if ($NoFeed) { Remove-Item Env:KNIPS_UPDATE_FEED -ErrorAction SilentlyContinue }
  else { $env:KNIPS_UPDATE_FEED = "http://127.0.0.1:$port/latest.json" }
  $env:KNIPS_UPDATE_DELAY = "2"
  $p = Start-Process -FilePath $appExe -PassThru
  $env:KNIPS_UPDATE_FEED = "http://127.0.0.1:$port/latest.json"
  if (-not (Wait-Log "Knips \d+\.\d+\.\d+ gestartet" 1 60)) { Write-Host "Knips meldet keinen Start." }
  return $p
}
# Test-Befehl an die laufende App (zweiter Start → Einzelinstanz → knips://-Link).
function Send-App([string]$command) {
  $p = Start-Process -FilePath $appExe -ArgumentList "knips://$command" -PassThru
  if (-not $p.WaitForExit(30000)) { $p.Kill() }
}
function Stop-App {
  Get-Process -Name "knips" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  [void](Wait-Until { -not (Get-Process -Name "knips" -ErrorAction SilentlyContinue) } 20)
  Start-Sleep -Seconds 2
}
# Installer still ausführen und warten, bis auch ein Installer aus einer Aktualisierung fertig ist.
function Wait-Installer {
  [void](Wait-Until { -not (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "Knips*installer*" -or $_.ProcessName -like "Knips_*setup*" }) } 180)
  Start-Sleep -Seconds 2
}
function Install-Setup([string]$file) {
  $p = Start-Process -FilePath $file -ArgumentList "/S" -Wait -PassThru
  Wait-Installer
  return $p.ExitCode
}

$itemFile = ""
function Test-Data([string]$when) {
  $s = Get-Settings
  Check "Einstellungen erhalten ($when)" ($s.quickAccessSeconds -eq 42 -and $s.appearance -eq "dark" -and $s.gifWidth -eq 640 -and $s.tookSnippingKey -eq $true) ($s | ConvertTo-Json -Compress)
  Check "Ablage und Original erhalten ($when)" ((Test-Path $capture) -and (Test-Path $itemFile) -and (Test-Path (Join-Path (Split-Path $itemFile) "original.png")))
  $taken = (Get-ItemProperty -Path $knipsKey -Name "PrintScreenKeyTaken" -ErrorAction SilentlyContinue).PrintScreenKeyTaken
  Check "Druck-Taste bleibt bei Knips ($when)" ((Get-Snip) -eq 0 -and $taken -eq 1) "Snipping $(Get-Snip), Vermerk $taken"
}

try {
  Stop-App
  if (Test-Path $uninstallKey) {
    $u = Join-Path $instDir "uninstall.exe"
    if (Test-Path $u) { Start-Process -FilePath $u -ArgumentList "/S" -Wait; [void](Wait-Until { -not (Test-Path $uninstallKey) } 60) }
  }
  foreach ($p in @($instDir, $localData, $roamingData)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $feedDir, (Join-Path $feedDir "manipuliert") | Out-Null

  # ---------------------------------------------------------------- 0. Schlüssel, Installer, Feed
  Step "Wegwerf-Schlüssel, Entwickler-Installer 0.0.1 und 0.0.2, Feed auf 127.0.0.1"
  $keyFile = Join-Path $work "updater.key"
  # Passwort nur in der Umgebung dieses Laufs (wie das Secret in release.yml), nie in einer Befehlszeile.
  $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
  node -e "require('@tauri-apps/cli').run(['signer', 'generate', '--ci', '-w', process.argv[1], '-p', process.env.TAURI_SIGNING_PRIVATE_KEY_PASSWORD], 'tauri').catch((e) => { console.error(String(e)); process.exit(1); })" $keyFile | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$keyFile.pub")) { throw "Wegwerf-Schlüssel nicht erzeugt" }
  $pub = (Get-Content -Raw "$keyFile.pub").Trim()

  $setups = @{}
  foreach ($v in @("0.0.1", "0.0.2")) {
    $conf = Join-Path $work "tauri-$v.json"
    $override = @{ version = $v; plugins = @{ updater = @{ pubkey = $pub } } }
    Set-Content -Path $conf -Value ($override | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
    Write-Host "::group::tauri build $v (Feature dev, Profil $CargoProfile)"
    pnpm tauri build --features dev --config $conf -- --profile $CargoProfile | Out-Host
    $code = $LASTEXITCODE
    Write-Host "::endgroup::"
    if ($code -ne 0) { throw "tauri build $v fehlgeschlagen ($code)" }
    $built = "target/$CargoProfile/bundle/nsis/Knips_$($v)_x64-setup.exe"
    if (-not (Test-Path $built)) { throw "$built fehlt" }
    $setups[$v] = Join-Path $work "Knips_$($v)_x64-setup.exe"
    Copy-Item $built $setups[$v]
  }
  Check "zwei Installer gebaut" ((Test-Path $setups["0.0.1"]) -and (Test-Path $setups["0.0.2"]))

  $portFile = Join-Path $work "port.txt"
  $server = Start-Process -FilePath "node" -ArgumentList @("scripts/update-server.mjs", "`"$feedDir`"", "`"$portFile`"", "`"$serverLog`"") -PassThru -WindowStyle Hidden
  if (-not (Wait-Until { Test-Path $portFile } 20)) { throw "Feed-Server startet nicht" }
  $port = (Get-Content -Raw $portFile).Trim()
  Write-Host "Feed-Server: http://127.0.0.1:$port/"

  # 0.0.2 signieren und latest.json erzeugen wie release.yml (nur hier mit Wegwerf-Schlüssel und HTTP auf 127.0.0.1).
  $new = Join-Path $feedDir "Knips_0.0.2_x64-setup.exe"
  Copy-Item $setups["0.0.2"] $new
  $env:TAURI_SIGNING_PRIVATE_KEY = (Get-Content -Raw $keyFile).Trim()
  ./scripts/update-feed.ps1 -Installer $new -Version "0.0.2" -Url "http://127.0.0.1:$port/Knips_0.0.2_x64-setup.exe" -Out (Join-Path $work "feed-gut.json") -PubKey $pub -Notes "Knips 0.0.2 (Test)" -AllowHttp
  Remove-Item Env:TAURI_SIGNING_PRIVATE_KEY, Env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
  $good = Get-Content -Raw (Join-Path $work "feed-gut.json") | ConvertFrom-Json
  # Gegenproben: veränderte Datei unter eigener Adresse, andere Versionsnummer, gleiche und ältere Version.
  $bytes = [IO.File]::ReadAllBytes($new)
  $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
  [IO.File]::WriteAllBytes((Join-Path $feedDir "manipuliert\Knips_0.0.2_x64-setup.exe"), $bytes)
  function Write-Variant([string]$name, [string]$version, [string]$url) {
    $f = $good | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $f.version = $version
    $f.platforms."windows-x86_64".url = $url
    Set-Content -Path (Join-Path $work $name) -Value ($f | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
  }
  $goodUrl = $good.platforms."windows-x86_64".url
  Write-Variant "feed-manipuliert.json" "0.0.2" "http://127.0.0.1:$port/manipuliert/Knips_0.0.2_x64-setup.exe"
  Write-Variant "feed-version.json" "0.0.3" $goodUrl
  Write-Variant "feed-gleich.json" "0.0.1" $goodUrl
  Write-Variant "feed-aelter.json" "0.0.0" $goodUrl
  Copy-Item (Join-Path $work "feed-*.json") $Out

  # ---------------------------------------------------------------- 1. 0.0.1 installieren, Daten anlegen
  Step "0.0.1 installieren, Einstellungen, Aufnahme und Druck-Taste anlegen"
  $code = Install-Setup $setups["0.0.1"]
  Check "0.0.1 still installiert (Exit $code)" ($code -eq 0 -and (Get-InstalledVersion) -eq "0.0.1" -and (Test-Path $appExe)) (Get-InstalledVersion)
  New-Item -ItemType Directory -Force -Path $roamingData, $saveDir | Out-Null
  # Wie nach einiger Zeit mit Knips: eigene Einstellungen, keine Fragen beim Start, kein Autostart.
  $settings = [ordered]@{ quickAccessSeconds = 42; appearance = "dark"; gifWidth = 640; autoUpdate = $true; didFirstLaunch = $true; askedShortcutTakeover = $true; launchAtLogin = $false; tookSnippingKey = $true; telemetryConsent = $false }
  Set-Content -Path $settingsFile -Value ($settings | ConvertTo-Json) -Encoding utf8NoBOM
  $uuid = [guid]::NewGuid().ToString()
  $itemDir = Join-Path $localData "items\$uuid"
  New-Item -ItemType Directory -Force -Path $itemDir | Out-Null
  $png = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
  [IO.File]::WriteAllBytes($capture, $png)
  [IO.File]::WriteAllBytes((Join-Path $itemDir "original.png"), $png)
  $item = @{ id = $uuid; kind = "image"; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); filePath = $capture; pixelWidth = 1; pixelHeight = 1; scale = 1.0; revision = 1; outputScale = 1.0 }
  $itemFile = Join-Path $itemDir "item.json"
  Set-Content -Path $itemFile -Value ($item | ConvertTo-Json -Compress) -Encoding utf8NoBOM
  # Wie hotkeys::set_snipping_key(false): Knips hat die Druck-Taste übernommen.
  New-Item -Path $knipsKey -Force | Out-Null
  Set-ItemProperty -Path $knipsKey -Name "PrintScreenKeyTaken" -Value 1 -Type DWord
  Set-Snip 0

  # ---------------------------------------------------------------- 2. Gegenproben
  Step "Gegenproben mit laufender 0.0.1"
  Clear-Log
  Set-Feed "feed-manipuliert.json"
  $app = Start-App
  Check "Testkanal aktiv" (Wait-Log "Aktualisierung: Testkanal http://127\.0\.0\.1" 1 30)
  Check "veränderter Installer: Signatur abgelehnt" (Wait-Log "Aktualisierung abgelehnt \(Signatur\)" 1 120)
  Check "… nachdem er wirklich geladen wurde" ((Get-Hits "/manipuliert/Knips_0.0.2_x64-setup.exe") -ge 1)
  Set-Feed "feed-version.json"
  Send-App "debug-update-check"
  Check "Feed nennt 0.0.3, signiert ist 0.0.2: abgelehnt" (Wait-Log "Aktualisierung abgelehnt \(Signatur\)" 2 120)
  Set-Feed "feed-gleich.json"
  Send-App "debug-update-check"
  Check "gleiche Version (0.0.1): nichts zu tun" (Wait-Log "Aktualisierung: aktuell" 1 60)
  Set-Feed "feed-aelter.json"
  Send-App "debug-update-check"
  Check "ältere Version (0.0.0): nichts zu tun" (Wait-Log "Aktualisierung: aktuell" 2 60)
  Check "kein Update im Zwischenspeicher" (-not (Test-Path $cacheDir))
  Check "installiert bleibt 0.0.1" ((Get-InstalledVersion) -eq "0.0.1") (Get-InstalledVersion)
  Check "Knips läuft weiter (derselbe Prozess)" (-not $app.HasExited)
  Send-App "debug-quit"
  Check "Beenden ohne Update: Knips beendet sich, installiert nichts" ((Wait-Until { $app.HasExited } 30) -and (Get-InstalledVersion) -eq "0.0.1")
  Save-Log "2-gegenproben"
  Stop-App

  # ---------------------------------------------------------------- 3. Einstellung aus
  Step 'Einstellung „Automatisch aktualisieren“ aus'
  Set-Setting "autoUpdate" $false
  Set-Setting "updateLastCheck" $null
  Clear-Log
  Set-Feed "feed-gut.json"
  $hits = Get-Hits "/latest.json"
  $app = Start-App
  Check "automatische Suche aus (Protokoll)" (Wait-Log "automatische Suche aus" 1 30)
  Start-Sleep -Seconds 5
  Check "keine Anfrage an den Feed" ((Get-Hits "/latest.json") -eq $hits) "$(Get-Hits '/latest.json') statt $hits"
  Send-App "debug-quit"
  [void](Wait-Until { $app.HasExited } 30)
  Save-Log "3-einstellung-aus"
  Stop-App
  Set-Setting "autoUpdate" $true

  # ---------------------------------------------------------------- 4. Ohne Testkanal
  Step "Entwickler-Build ohne Testkanal"
  Clear-Log
  $hits = Get-AllHits
  $app = Start-App -NoFeed
  Check "Suche aus in dieser Sitzung (Protokoll)" (Wait-Log "Aktualisierung: aus in dieser Sitzung" 1 30)
  Start-Sleep -Seconds 8
  Check "keine Anfrage an irgendeinen Feed" ((Get-AllHits) -eq $hits)
  Save-Log "4-ohne-testkanal"
  Stop-App

  # ---------------------------------------------------------------- 5. Neu starten und aktualisieren
  Step "Neu starten und aktualisieren: 0.0.1 → 0.0.2"
  Clear-Log
  Set-Feed "feed-gut.json"
  $app = Start-App
  Check "automatisch gesucht, geladen und geprüft" (Wait-Log "Aktualisierung: 0\.0\.2 geladen und geprüft" 1 180)
  Check "Installer im Zwischenspeicher" (Test-Path (Join-Path $cacheDir "Knips-setup.exe"))
  Send-App "debug-update-install"
  Check "0.0.1 beendet sich für den Installer" (Wait-Until { $app.HasExited } 60)
  Check "installiert: 0.0.2" (Wait-Until { (Get-InstalledVersion) -eq "0.0.2" } 240) (Get-InstalledVersion)
  Wait-Installer
  Check "Knips läuft wieder" (Wait-Until { (Get-AppProcess).Count -ge 1 } 120)
  Check "knips.exe ist 0.0.2" ((Get-Item $appExe).VersionInfo.ProductVersion -eq "0.0.2") (Get-Item $appExe).VersionInfo.ProductVersion
  Check "0.0.2 gestartet (Protokoll)" (Wait-Log "Knips 0\.0\.2 gestartet" 1 60)
  Check "Zwischenspeicher nach dem Start aufgeräumt" (Wait-Until { -not (Test-Path $cacheDir) } 60)
  Check "Installer passiv mit Neustart (Protokoll)" ((Get-AppLog) -match "installiere 0\.0\.2 \(danach Neustart\)")
  Test-Data "nach dem Neustart"
  Save-Log "5-neustart"
  Stop-App

  # ---------------------------------------------------------------- 6. Beim Beenden
  Step "Beenden: 0.0.1 → 0.0.2 ohne Neustart"
  $code = Install-Setup $setups["0.0.1"]
  Check "zurück auf 0.0.1 (Exit $code)" ((Get-InstalledVersion) -eq "0.0.1") (Get-InstalledVersion)
  Clear-Log
  $app = Start-App
  Send-App "debug-update-check"
  Check '„Jetzt suchen“: geladen und geprüft' (Wait-Log "Aktualisierung: 0\.0\.2 geladen und geprüft" 1 180)
  Send-App "debug-quit"
  Check "Knips beendet sich" (Wait-Until { $app.HasExited } 60)
  Check "beim Beenden installiert: 0.0.2" (Wait-Until { (Get-InstalledVersion) -eq "0.0.2" } 240) (Get-InstalledVersion)
  Wait-Installer
  Start-Sleep -Seconds 10
  Check "Knips bleibt beendet (kein Neustart)" ((Get-AppProcess).Count -eq 0)
  Check "knips.exe ist 0.0.2" ((Get-Item $appExe).VersionInfo.ProductVersion -eq "0.0.2")
  Check "Installer ohne Neustart (Protokoll)" ((Get-AppLog) -match "installiere 0\.0\.2 \(beim Beenden\)")
  Test-Data "nach dem Beenden"
  Save-Log "6-beenden"

  # ---------------------------------------------------------------- 7. Zwischenspeicher
  Step "Zwischenspeicher: geladenes Update übersteht einen Neustart"
  $code = Install-Setup $setups["0.0.1"]
  Check "zurück auf 0.0.1 (Exit $code)" ((Get-InstalledVersion) -eq "0.0.1") (Get-InstalledVersion)
  Clear-Log
  $downloads = Get-Hits "/Knips_0.0.2_x64-setup.exe"
  $app = Start-App
  Check "0.0.2 sofort bereit (Protokoll)" (Wait-Log "0\.0\.2 aus dem Zwischenspeicher bereit" 1 60)
  Start-Sleep -Seconds 5
  Check "ohne neuen Download" ((Get-Hits "/Knips_0.0.2_x64-setup.exe") -eq $downloads)
  Save-Log "7-zwischenspeicher"
  Stop-App
}
catch {
  Check "Ablauf" $false "$($_.Exception.Message)"
  Save-Log "abbruch"
}
finally {
  Stop-App
  if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  $u = Join-Path $instDir "uninstall.exe"
  if (Test-Path $u) {
    Start-Process -FilePath $u -ArgumentList "/S", "/DELETEAPPDATA" -Wait
    [void](Wait-Until { -not (Test-Path $uninstallKey) } 120)
  }
  Remove-Item -Force $capture -ErrorAction SilentlyContinue
  Set-Snip $snipBefore
  Remove-Item -Recurse -Force $knipsKey, $work -ErrorAction SilentlyContinue
  Remove-Item Env:KNIPS_UPDATE_FEED, Env:KNIPS_UPDATE_DELAY, Env:TAURI_SIGNING_PRIVATE_KEY, Env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
}

Write-Host ""
Get-Content $summary | ForEach-Object { Write-Host $_ }
if ($failures.Count -gt 0) { exit 1 }
exit 0
