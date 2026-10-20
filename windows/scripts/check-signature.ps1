# Prüft eine signierte Knips-Datei (release.yml, Signatur-Probe in windows.yml): Authenticode-Status, optional den
# Fingerabdruck des Zertifikats, und die Metadaten, die SignPath für jede signierte Datei verlangt
# (ProductName „Knips“, ProductVersion = Version). Mit -Installer wird zusätzlich die knips.exe im
# NSIS-Installer (per 7-Zip ausgepackt) geprüft: Sie muss vom selben Zertifikat signiert sein.
# Exit 1 bei jeder Abweichung.
param(
  [Parameter(Mandatory = $true)] [string]$Path,
  [Parameter(Mandatory = $true)] [string]$Version,
  # Erwarteter SHA-1-Fingerabdruck; leer = jedes Zertifikat, dem Windows vertraut.
  [string]$Thumbprint = '',
  # SignPath-Testzertifikat: Kette endet bei einer Wurzel, der Windows nicht vertraut. Dann genügt eine
  # unversehrte Signatur (kein HashMismatch, nicht unsigniert).
  [switch]$AllowUntrustedRoot,
  [switch]$Installer
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Test-File([string]$File, [string]$ExpectedThumbprint) {
  $name = [IO.Path]::GetFileName($File)
  $sig = Get-AuthenticodeSignature -LiteralPath $File
  $status = [string]$sig.Status
  $cert = $sig.SignerCertificate
  Write-Host "$name"
  Write-Host "  Status:      $status  $($sig.StatusMessage)"
  if ($cert) {
    Write-Host "  Zertifikat:  $($cert.Subject)"
    Write-Host "  Aussteller:  $($cert.Issuer)"
    Write-Host "  SHA-1:       $($cert.Thumbprint)   gültig bis $($cert.NotAfter.ToString('yyyy-MM-dd'))"
  }
  if ($sig.TimeStamperCertificate) { Write-Host "  Zeitstempel: $($sig.TimeStamperCertificate.Subject)" }

  $ok = $status -eq 'Valid' -or ($AllowUntrustedRoot -and $cert -and @('UnknownError', 'NotTrusted') -contains $status)
  if (-not $ok) { throw "$name`: Signatur nicht gültig ($status)." }
  if ($ExpectedThumbprint -and $cert.Thumbprint -ne $ExpectedThumbprint) {
    throw "$name`: signiert mit $($cert.Thumbprint), erwartet $ExpectedThumbprint."
  }

  $info = (Get-Item -LiteralPath $File).VersionInfo
  Write-Host "  ProductName: $($info.ProductName)   ProductVersion: $($info.ProductVersion)   FileVersion: $($info.FileVersion)"
  if ($info.ProductName -ne 'Knips') { throw "$name`: ProductName ist '$($info.ProductName)', erwartet 'Knips'." }
  if ($info.ProductVersion -ne $Version) { throw "$name`: ProductVersion ist '$($info.ProductVersion)', erwartet '$Version'." }
  return $cert.Thumbprint
}

$file = (Resolve-Path -LiteralPath $Path).ProviderPath
$signer = Test-File $file $Thumbprint

if ($Installer) {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('knips-check-' + [guid]::NewGuid().ToString('N'))
  try {
    # 7-Zip liest NSIS-Installer und ist auf den GitHub-Windows-Runnern installiert.
    & 7z x -y "-o$dir" $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip konnte den Installer nicht auspacken ($LASTEXITCODE)." }
    $app = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'knips.exe')
    if ($app.Count -ne 1) { throw "Im Installer genau eine knips.exe erwartet, gefunden: $($app.Count)." }
    Write-Host "Im Installer:"
    Test-File $app[0].FullName $signer | Out-Null
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Write-Host "Signatur in Ordnung."
