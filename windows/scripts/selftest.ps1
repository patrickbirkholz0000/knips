# Alle Selbsttests nacheinander, je mit Zeitlimit. Ergebnis: <Out>\<test>\ (Bilder) + <Out>\<test>.log,
# Zusammenfassung in <Out>\ergebnis.txt. Exit 1, wenn ein Test fehlschlägt.
param(
  [string]$Exe = "target/release/knips.exe",
  [string]$Out = "shots",
  [string[]]$Tests = @("detect", "output", "selection", "capture", "record", "track", "video", "perf", "render", "ui")
)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$exePath = (Resolve-Path $Exe).Path
$summary = @()
$failed = 0
foreach ($test in $Tests) {
  $dir = Join-Path (Resolve-Path $Out).Path $test
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $log = Join-Path (Resolve-Path $Out).Path "$test.log"
  $err = Join-Path (Resolve-Path $Out).Path "$test.err.log"
  $args = @("--selftest", $test, "`"$dir`"")
  if ($test -eq "record") { $args += "3" }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $exePath -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $err
  $done = $p.WaitForExit(240000)
  $sw.Stop()
  if (-not $done) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $status = "ZEITÜBERSCHREITUNG"
  } elseif ($p.ExitCode -eq 0) {
    $status = "OK"
  } else {
    $status = "FEHLER ($($p.ExitCode))"
  }
  if ($status -ne "OK") { $failed++ }
  $line = "{0,-10} {1,-20} {2,6:N1} s" -f $test, $status, $sw.Elapsed.TotalSeconds
  $summary += $line
  Write-Host "::group::$test — $status"
  Get-Content $log -ErrorAction SilentlyContinue | Write-Host
  Get-Content $err -ErrorAction SilentlyContinue | Select-Object -Last 40 | Write-Host
  Write-Host "::endgroup::"
}
# Sandbox-Daten nicht ins Artefakt
Get-ChildItem -Path $Out -Recurse -Directory -Filter sandbox | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$summary | Set-Content (Join-Path $Out "ergebnis.txt")
Write-Host ""
$summary | ForEach-Object { Write-Host $_ }
if ($failed -gt 0) { exit 1 }
