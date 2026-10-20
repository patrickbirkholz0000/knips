# Fotografiert die ersten Seiten des NSIS-Installers (Willkommen, Datenschutz und Lizenz) für die Durchsicht —
# nur in der CI, startet die echte Installer-Oberfläche und bricht dann ab, ohne zu installieren.
param(
  [Parameter(Mandatory = $true)] [string]$Installer,
  [string]$Out = 'shots/installer'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class KnipsWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[KnipsWin]::SetProcessDPIAware() | Out-Null
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Save-Window([IntPtr]$Handle, [string]$Name) {
  $r = New-Object KnipsWin+RECT
  [KnipsWin]::GetWindowRect($Handle, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
  $file = Join-Path $Out "$Name.png"
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Host "$file ($w x $h)"
}

$p = Start-Process -FilePath $Installer -PassThru
try {
  $deadline = (Get-Date).AddSeconds(60)
  while ($p.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; $p.Refresh() }
  if ($p.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Installer-Fenster erscheint nicht.' }
  Start-Sleep -Seconds 2
  [KnipsWin]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Save-Window $p.MainWindowHandle 'installer-1-willkommen'
  # „Weiter“ ist der Standardknopf.
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 2
  Save-Window $p.MainWindowHandle 'installer-2-datenschutz-und-lizenz'
} finally {
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
