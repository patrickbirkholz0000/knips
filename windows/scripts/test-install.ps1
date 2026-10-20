# CI-Test für install.ps1 (windows.yml) — installiert wirklich, also nur auf Rechnern ohne Nutzer.
#
#   test-install.ps1 -Installer <setup.exe>            unsignierter Installer aus dem Build:
#       Installation und Deinstallation unter PowerShell 7 und Windows PowerShell 5.1, falsche Prüfsumme,
#       Aufruf als Skriptblock (wie `irm … | iex`, Fehler beendet die Sitzung nicht), unbekannte Version auf GitHub.
#   test-install.ps1 -Installer <setup.exe> -ProbeThumbprint <sha1>
#       Installer mit Wegwerf-Zertifikat signiert (Signatur-Probe): install.ps1 lehnt fremden Herausgeber und
#       manipulierte Datei ab; still installiert trägt die knips.exe dieselbe Signatur.
param(
  [Parameter(Mandatory = $true)] [string]$Installer,
  [string]$ProbeThumbprint = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$installScript = (Resolve-Path (Join-Path $PSScriptRoot '../install.ps1')).ProviderPath
$source = (Resolve-Path -LiteralPath $Installer).ProviderPath
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Knips'
$appExe = Join-Path $env:LOCALAPPDATA 'Knips\knips.exe'
$work = Join-Path ([IO.Path]::GetTempPath()) ('knips-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0

function Check([bool]$Condition, [string]$Text) {
  if ($Condition) { Write-Host "  ok    $Text" -ForegroundColor Green }
  else { Write-Host "  FEHLT $Text" -ForegroundColor Red; $script:failures++ }
}

# Kopie (mit passender oder falscher .sha256 daneben), damit der Build-Ordner unberührt bleibt.
function New-Copy([string]$Name, [string]$Hash) {
  $dir = Join-Path $work $Name
  New-Item -ItemType Directory -Path $dir | Out-Null
  $file = Join-Path $dir ([IO.Path]::GetFileName($source))
  Copy-Item -LiteralPath $source -Destination $file
  if ($Hash) { [IO.File]::WriteAllText("$file.sha256", "$Hash  $([IO.Path]::GetFileName($file))`n") }
  return $file
}

function Invoke-Script([string]$Shell, [string[]]$Arguments) {
  if ($Shell -eq 'powershell') { $exe = 'powershell.exe'; $pre = @('-NoProfile', '-ExecutionPolicy', 'Bypass') }
  else { $exe = 'pwsh'; $pre = @('-NoProfile') }
  # Meldungen nur über ASCII-Teile prüfen: Umlaute aus Kindprozessen kommen je nach Codepage anders an.
  $ErrorActionPreference = 'Continue'
  $output = & $exe @pre @Arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  Write-Host ($output.TrimEnd() -replace '(?m)^', '        ')
  return [pscustomobject]@{ Code = $code; Output = $output }
}

function Test-Installed {
  if (-not (Test-Path $uninstallKey)) { return $false }
  return (Test-Path -LiteralPath $appExe -PathType Leaf)
}

function Uninstall-Knips {
  $entry = Get-ItemProperty -Path $uninstallKey
  $uninstaller = ([string]$entry.UninstallString).Trim('"')
  # Der NSIS-Deinstaller kopiert sich nach %TEMP% und läuft dort weiter — also auf das Ergebnis warten.
  Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait
  $deadline = (Get-Date).AddSeconds(120)
  while ((Test-Installed) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 2
}

function Test-InstallCycle([string]$Shell) {
  Write-Host "Installation mit install.ps1 unter $Shell"
  $file = New-Copy "ok-$Shell" (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
  $r = Invoke-Script $Shell @('-File', $installScript, '-InstallerPath', $file, '-NoStart')
  Check ($r.Code -eq 0) "Exit-Code 0 (ist $($r.Code))"
  Check ($r.Output -match '\(SHA-256 [0-9a-f]{64}\)') 'Prüfsumme verglichen'
  Check ($r.Output -match 'nicht signiert') 'Hinweis auf fehlende Signatur'
  Check ($r.Output -match 'Knips \d+\.\d+\.\d+ ist installiert') 'Erfolgsmeldung mit Version'
  Check ($r.Output -match 'Nutzungsstatistik') 'Datenschutz-Hinweis'
  Check (Test-Installed) "installiert: $appExe"
  if (Test-Path $uninstallKey) {
    $entry = Get-ItemProperty -Path $uninstallKey
    Check ($entry.Publisher -eq 'Patrick Birkholz') "Herausgeber im Uninstall-Eintrag ($($entry.Publisher))"
    Check ($entry.DisplayVersion -match '^\d+\.\d+\.\d+$') "Version im Uninstall-Eintrag ($($entry.DisplayVersion))"
    Check (-not (Get-Process -Name knips -ErrorAction SilentlyContinue)) '-NoStart: Knips läuft nicht'
    Uninstall-Knips
  }
  Check (-not (Test-Installed)) 'nach dem Deinstallieren entfernt'
}

try {
  # Windows PowerShell 5.1 liest .ps1-Dateien ohne BOM als ANSI — dann wären alle Umlaute kaputt.
  $head = [IO.File]::ReadAllBytes($installScript)[0..2]
  Check (($head[0] -eq 0xEF) -and ($head[1] -eq 0xBB) -and ($head[2] -eq 0xBF)) 'install.ps1 ist UTF-8 mit BOM'

  if (-not $ProbeThumbprint) {
    Test-InstallCycle 'pwsh'
    Test-InstallCycle 'powershell'

    Write-Host 'Falsche Prüfsumme'
    $bad = New-Copy 'bad-hash' ('0' * 64)
    $r = Invoke-Script 'pwsh' @('-File', $installScript, '-InstallerPath', $bad, '-NoStart')
    Check ($r.Code -ne 0) "Exit-Code ungleich 0 (ist $($r.Code))"
    Check ($r.Output -match 'des Installers stimmt nicht \(erwartet 0{64}') 'Meldung zur Prüfsumme'
    Check (-not (Test-Installed)) 'nichts installiert'

    # Wie `& ([scriptblock]::Create((irm …))) -Parameter`: ein Fehler wirft, statt die Sitzung zu beenden.
    foreach ($shell in @('pwsh', 'powershell')) {
      Write-Host "Aufruf als Skriptblock unter $shell"
      $command = "try { & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '$installScript'))) -InstallerPath '$bad' -NoStart } " +
        "catch { 'GEFANGEN: ' + `$_.Exception.Message }; 'SITZUNG-LEBT'"
      $r = Invoke-Script $shell @('-Command', $command)
      Check ($r.Output -match 'GEFANGEN: Knips wurde nicht installiert: .*stimmt nicht') 'Fehler als Ausnahme mit Grund'
      Check ($r.Output -match 'SITZUNG-LEBT') 'Sitzung läuft weiter (kein exit)'
      Check (-not (Test-Installed)) 'nichts installiert'
    }

    Write-Host 'Unbekannte Version auf GitHub'
    $r = Invoke-Script 'powershell' @('-File', $installScript, '-Version', '0.0.1', '-NoStart')
    Check ($r.Code -ne 0) "Exit-Code ungleich 0 (ist $($r.Code))"
    Check ($r.Output -match 'Version 0\.0\.1 gibt es nicht|GitHub hat die Anfrage abgelehnt') 'verständliche Meldung von der GitHub-API'
  } else {
    Write-Host 'Signierter Installer, aber nicht von der SignPath Foundation'
    $foreign = New-Copy 'probe-signed' ''
    $r = Invoke-Script 'pwsh' @('-File', $installScript, '-InstallerPath', $foreign, '-NoStart')
    Check ($r.Code -ne 0) "Exit-Code ungleich 0 (ist $($r.Code))"
    Check ($r.Output -match "erwartet wird 'SignPath Foundation'") 'fremder Herausgeber abgelehnt'
    Check (-not (Test-Installed)) 'nichts installiert'

    Write-Host 'Signierter Installer, nachträglich verändert'
    $tampered = New-Copy 'tampered' ''
    $bytes = [IO.File]::ReadAllBytes($tampered)
    $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
    [IO.File]::WriteAllBytes($tampered, $bytes)
    Check ([string](Get-AuthenticodeSignature -LiteralPath $tampered).Status -eq 'HashMismatch') 'Windows meldet HashMismatch'
    $r = Invoke-Script 'powershell' @('-File', $installScript, '-InstallerPath', $tampered, '-NoStart')
    Check ($r.Code -ne 0) "Exit-Code ungleich 0 (ist $($r.Code))"
    Check ($r.Output -match 'Signatur des Installers ist ung.{1,3}ltig \(HashMismatch\)') 'ungültige Signatur abgelehnt'
    Check (-not (Test-Installed)) 'nichts installiert'

    Write-Host 'Still installiert: signierte knips.exe'
    $p = Start-Process -FilePath $source -ArgumentList '/S' -Wait -PassThru
    Check ($p.ExitCode -eq 0) "Installer-Exit-Code 0 (ist $($p.ExitCode))"
    Check (Test-Installed) 'installiert'
    if (Test-Installed) {
      $sig = Get-AuthenticodeSignature -LiteralPath $appExe
      Check ([string]$sig.Status -eq 'Valid' -and $sig.SignerCertificate.Thumbprint -eq $ProbeThumbprint) "installierte knips.exe signiert ($($sig.Status))"
      Uninstall-Knips
    }
    Check (-not (Test-Installed)) 'nach dem Deinstallieren entfernt'
  }
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures Prüfung(en) fehlgeschlagen." -ForegroundColor Red; exit 1 }
Write-Host 'Alle Prüfungen bestanden.' -ForegroundColor Green
