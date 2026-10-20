<#
.SYNOPSIS
  Installiert Knips für Windows für den angemeldeten Benutzer.

.DESCRIPTION
  Knips: Screenshots und Bildschirmvideos mit Zensur, freie Software (GPL-3.0-or-later),
  https://github.com/patrickbirkholz0000/knips

  Das Skript holt den Installer der neuesten veröffentlichten Version von GitHub, prüft die SHA-256-Prüfsumme
  aus dem Release und, falls der Installer signiert ist, die Authenticode-Signatur. Dann installiert es still,
  nur für den angemeldeten Benutzer und ohne Administratorrechte, und startet Knips. Die heruntergeladene Datei
  wird danach gelöscht. Läuft unter Windows PowerShell 5.1 und PowerShell 7.

  Aufruf:
    irm https://knips.velno.ai/install.ps1 | iex

  Mit Parametern:
    & ([scriptblock]::Create((irm https://knips.velno.ai/install.ps1))) -Version 1.0.0

  Deinstallieren: Einstellungen -> Apps -> Installierte Apps -> Knips.

.PARAMETER Version
  Bestimmte Version statt der neuesten, z. B. 1.0.0.

.PARAMETER InstallerPath
  Lokale Setup-Datei statt eines Downloads (zum Testen). Liegt daneben eine gleichnamige .sha256-Datei,
  wird die Prüfsumme geprüft.

.PARAMETER NoStart
  Knips nach der Installation nicht starten.
#>
param(
  [string]$Version = '',
  [string]$InstallerPath = '',
  [switch]$NoStart
)

# Alles in einem eigenen Gültigkeitsbereich: Bei `irm … | iex` bleiben Einstellungen wie
# $ErrorActionPreference sonst in der Sitzung des Benutzers hängen.
& {
  param([string]$Version, [string]$InstallerPath, [bool]$NoStart, [bool]$AsFile)

  Set-StrictMode -Version 3.0
  $ErrorActionPreference = 'Stop'
  # Invoke-WebRequest ist unter Windows PowerShell 5.1 mit Fortschrittsanzeige um ein Vielfaches langsamer.
  $ProgressPreference = 'SilentlyContinue'

  $Repo = 'patrickbirkholz0000/knips'
  $ReleasesUrl = "https://github.com/$Repo/releases"
  $PrivacyUrl = "https://github.com/$Repo#datenschutz"
  # Signierte Installer müssen von diesem Herausgeber stammen (Code signing policy im README).
  $TrustedSigner = 'SignPath Foundation'
  $UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Knips'
  $UserAgent = 'knips-install-ps1'

  # Meldungen nur mit ASCII und Umlauten: Die Konsole von Windows PowerShell 5.1 kann oft nicht mehr darstellen.
  function Step([string]$Text) { Write-Host "-> $Text" -ForegroundColor Cyan }
  function Note([string]$Text) { Write-Host "   $Text" }
  function Warn([string]$Text) { Write-Host "   Hinweis: $Text" -ForegroundColor Yellow }
  function Fail([string]$Text) { throw (New-Object System.InvalidOperationException $Text) }

  function Get-HttpStatus($ErrorRecord) {
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
      try { return [int]$response.Value.StatusCode } catch { return 0 }
    }
    return 0
  }

  function Get-Release([string]$Wanted) {
    if ($Wanted) { $url = "https://api.github.com/repos/$Repo/releases/tags/v$Wanted" }
    else { $url = "https://api.github.com/repos/$Repo/releases/latest" }
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    try {
      return Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 30
    } catch {
      $code = Get-HttpStatus $_
      if ($code -eq 404) {
        if ($Wanted) { Fail "Version $Wanted gibt es nicht oder sie ist noch nicht veröffentlicht. Alle Versionen: $ReleasesUrl" }
        Fail "Es gibt noch keine veröffentlichte Version von Knips: $ReleasesUrl"
      }
      if ($code -eq 403 -or $code -eq 429) {
        Fail "GitHub hat die Anfrage abgelehnt (HTTP $code, meist zu viele Anfragen von dieser Internetadresse). Bitte später noch einmal versuchen oder den Installer von $ReleasesUrl laden."
      }
      Fail "GitHub ist nicht erreichbar: $($_.Exception.Message)"
    }
  }

  function Save-Asset($Asset, [string]$Target) {
    try {
      Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Target -UseBasicParsing -TimeoutSec 600 `
        -Headers @{ 'User-Agent' = $UserAgent }
    } catch {
      Fail "Download von $($Asset.name) fehlgeschlagen: $($_.Exception.Message)"
    }
  }

  # Erste 64 Hex-Zeichen der Datei, Format wie `shasum -a 256`: "<hash>  <dateiname>".
  function Read-Sha256File([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    if ($text -match '^\s*([0-9a-fA-F]{64})(\s|$)') { return $Matches[1].ToLowerInvariant() }
    Fail "Die Prüfsummen-Datei $Path hat nicht das erwartete Format."
  }

  function Test-Signature([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $status = [string]$sig.Status
    if ($status -eq 'NotSigned') {
      Warn 'Der Installer ist nicht signiert. Die Prüfsumme stimmt, die Datei ist also unverändert.'
      return $false
    }
    if ($status -ne 'Valid') {
      Fail "Die Signatur des Installers ist ungültig ($status). $($sig.StatusMessage) Abbruch, es wurde nichts installiert."
    }
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch ('(^|,\s*)CN="?' + [regex]::Escape($TrustedSigner) + '"?(,|$)')) {
      Fail "Der Installer ist von '$subject' signiert, erwartet wird '$TrustedSigner'. Abbruch, es wurde nichts installiert."
    }
    Note "Signatur gültig: $TrustedSigner"
    return $true
  }

  function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }

  $tempDir = $null
  try {
    # --- Voraussetzungen ---------------------------------------------------------------------------------
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Fail 'Dieses Skript installiert die Windows-Fassung von Knips und läuft nur unter Windows.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Knips braucht Windows 10 oder 11.' }
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'Knips braucht ein 64-Bit-Windows.' }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
      # Windows PowerShell 5.1 nimmt sonst je nach .NET-Stand noch TLS 1.0, GitHub verlangt TLS 1.2.
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $elevated = Test-Administrator
    if ($elevated) {
      Warn "PowerShell läuft als Administrator. Knips wird trotzdem nur für das Konto '$env:USERNAME' installiert."
    }

    if ($Version) {
      if ($Version -match '^v?(\d+\.\d+\.\d+)$') { $Version = $Matches[1] }
      else { Fail "Version '$Version' hat nicht die Form X.Y.Z, z. B. 1.0.0." }
    }

    # --- Installer besorgen und prüfen -----------------------------------------------------------------
    if ($InstallerPath) {
      if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { Fail "Datei nicht gefunden: $InstallerPath" }
      $installer = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
      Step "Verwende den lokalen Installer $installer"
      $shaFile = "$installer.sha256"
      if (Test-Path -LiteralPath $shaFile -PathType Leaf) {
        $expected = Read-Sha256File $shaFile
      } else {
        $expected = $null
        Warn "Keine Datei $([IO.Path]::GetFileName($shaFile)) daneben, die Prüfsumme wird nicht verglichen."
      }
      $label = [IO.Path]::GetFileName($installer)
    } else {
      if ($Version) { Step "Suche Knips $Version auf GitHub ..." } else { Step 'Suche die neueste Version von Knips auf GitHub ...' }
      $release = Get-Release $Version
      $assets = @($release.assets)
      $exeAssets = @($assets | Where-Object { $_.name -match '^Knips_\d+\.\d+\.\d+_x64-setup\.exe$' })
      if ($exeAssets.Count -ne 1) { Fail "Im Release $($release.tag_name) fehlt der Windows-Installer. Bitte später noch einmal versuchen: $ReleasesUrl" }
      $exeAsset = $exeAssets[0]
      $shaAssets = @($assets | Where-Object { $_.name -eq "$($exeAsset.name).sha256" })
      if ($shaAssets.Count -ne 1) { Fail "Im Release $($release.tag_name) fehlt die Prüfsumme $($exeAsset.name).sha256." }
      $label = "Knips $($release.tag_name -replace '^v', '')"

      $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('knips-install-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $tempDir | Out-Null
      $installer = Join-Path $tempDir $exeAsset.name
      $shaFile = "$installer.sha256"
      $sizeMb = [math]::Round($exeAsset.size / 1MB, 1)
      Step "Lade $($exeAsset.name) ($sizeMb MB) ..."
      Save-Asset $exeAsset $installer
      Save-Asset $shaAssets[0] $shaFile
      $expected = Read-Sha256File $shaFile
      # GitHub nennt seit 2025 selbst eine Prüfsumme je Datei; wenn vorhanden, muss sie ebenfalls passen.
      $digest = $exeAsset.PSObject.Properties['digest']
      if ($digest -and $digest.Value -and ([string]$digest.Value) -match '^sha256:([0-9a-fA-F]{64})$') {
        if ($Matches[1].ToLowerInvariant() -ne $expected) { Fail "Die Prüfsummen von GitHub und aus $($shaAssets[0].name) weichen voneinander ab. Abbruch." }
      }
    }

    if ($expected) {
      $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
      if ($actual -ne $expected) { Fail "Die Prüfsumme des Installers stimmt nicht (erwartet $expected, erhalten $actual). Abbruch, es wurde nichts installiert." }
      Note "Prüfsumme stimmt (SHA-256 $actual)"
    }
    $signed = Test-Signature $installer

    # --- Installieren ----------------------------------------------------------------------------------
    Step "Installiere $label für '$env:USERNAME' (ohne Administratorrechte) ..."
    Note 'Läuft Knips gerade, beendet der Installer es kurz.'
    # Direkt starten statt Start-Process -Wait: das wartet auch auf Kindprozesse wie das WebView2-Setup,
    # die länger weiterlaufen können.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $installer
    $psi.Arguments = '/S'
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process.WaitForExit(900000)) { Fail 'Der Installer ist nach 15 Minuten noch nicht fertig. Abbruch.' }
    if ($process.ExitCode -ne 0) { Fail "Der Installer ist mit Code $($process.ExitCode) abgebrochen." }

    # Tauri-NSIS, Modus „nur für diesen Benutzer“: Eintrag unter HKCU\…\Uninstall\Knips.
    if (-not (Test-Path $UninstallKey)) { Fail 'Der Installer hat sich beendet, aber Knips ist nicht als installiert eingetragen.' }
    $entry = Get-ItemProperty -Path $UninstallKey
    $location = $entry.PSObject.Properties['InstallLocation']
    if ($location -and $location.Value) { $installDir = ([string]$location.Value).Trim('"') }
    else { $installDir = Join-Path $env:LOCALAPPDATA 'Knips' }
    $displayVersion = $entry.PSObject.Properties['DisplayVersion']
    $installedVersion = if ($displayVersion) { [string]$displayVersion.Value } else { '' }
    $exe = Join-Path $installDir 'knips.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Fail "Knips ist eingetragen, aber $exe fehlt." }
    if ($signed) {
      $appSig = Get-AuthenticodeSignature -LiteralPath $exe
      if ([string]$appSig.Status -ne 'Valid') { Warn "Die Signatur von knips.exe ist nicht gültig ($($appSig.Status))." }
    }
    Write-Host "OK Knips $installedVersion ist installiert: $installDir" -ForegroundColor Green

    # --- Starten ---------------------------------------------------------------------------------------
    if ($NoStart) {
      Note 'Starten über das Startmenü: Knips.'
    } elseif ($elevated) {
      # Aus einer Administrator-Sitzung liefe Knips sonst ebenfalls mit Administratorrechten.
      Note 'Nicht automatisch gestartet, weil PowerShell als Administrator läuft. Bitte über das Startmenü starten: Knips.'
    } else {
      Start-Process -FilePath $exe -WorkingDirectory $installDir
      Note 'Knips läuft jetzt im Infobereich der Taskleiste (neben der Uhr).'
    }
    Note "Datenschutz: Knips fragt beim ersten Start, ob es eine anonyme Nutzungsstatistik senden darf. Ohne Zustimmung sendet es nichts. Abschalten jederzeit unter Einstellungen -> Datenschutz. Details: $PrivacyUrl"
    Note 'Deinstallieren: Einstellungen -> Apps -> Installierte Apps -> Knips.'
  } catch {
    $message = $_.Exception.Message
    if ($AsFile) {
      Write-Host "FEHLER: $message" -ForegroundColor Red
      exit 1
    }
    # Per `irm … | iex`: kein exit, das schlösse das PowerShell-Fenster.
    throw "Knips wurde nicht installiert: $message"
  } finally {
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
} $Version $InstallerPath ([bool]$NoStart) ([bool](Get-Variable -Name PSCommandPath -ValueOnly -ErrorAction SilentlyContinue))
