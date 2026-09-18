# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Zero-extra-tooling installer. Copies syslogd.exe into Program Files, registers
# it as an auto-start Windows service with a firewall rule, and adds an
# Add/Remove Programs (Programs and Features) entry.
# Run from an elevated PowerShell:  powershell -ExecutionPolicy Bypass -File install.ps1
[CmdletBinding()]
param(
    [string]$LogDir = "$env:ProgramData\SyslogCollector\logs",
    [int]$UdpPort = 514,
    [int]$UiPort  = 8514,
    [string]$BinaryPath = ""   # defaults to dist\x64 (falls back to dist\x86)
)
$ErrorActionPreference = "Stop"

# --- must be elevated ---
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { throw "Run this from an elevated (Administrator) PowerShell." }

# --- locate the binary (prefer x64) ---
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BinaryPath) {
    $cand = @(
        (Join-Path $here "..\dist\x64\syslogd.exe"),
        (Join-Path $here "..\dist\x86\syslogd.exe"),
        (Join-Path $here "..\target\release\syslogd.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cand) { throw "syslogd.exe not found. Build it first (see build.ps1) or pass -BinaryPath." }
    $BinaryPath = $cand
}
if (-not (Test-Path $BinaryPath)) { throw "Binary not found: $BinaryPath" }

# --- install into Program Files ---
$dest = Join-Path $env:ProgramFiles "SyslogCollector"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$destExe = Join-Path $dest "syslogd.exe"

# Stop an existing service before overwriting the exe.
if (Get-Service -Name "SyslogCollector" -ErrorAction SilentlyContinue) {
    Write-Host "Existing service found - removing first..."
    & $destExe uninstall 2>$null
    Start-Sleep -Seconds 2
}
# Stop a running tray controller too, so its files aren't locked during copy
# (parity with the macOS installer and uninstall.ps1).
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*\tray\SyslogTray.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Copy-Item -Path $BinaryPath -Destination $destExe -Force
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# --- register service + firewall via the binary's own installer ---
Write-Host "Registering service (log dir: $LogDir, UDP/$UdpPort, UI 127.0.0.1:$UiPort)..."
& $destExe install --log-dir "$LogDir" --udp-port $UdpPort --ui-port $UiPort
if ($LASTEXITCODE -ne 0) { throw "Service registration failed (exit $LASTEXITCODE)." }

# --- Programs and Features (Add/Remove Programs) entry ---
# Copy the uninstaller next to the exe so the entry can call it standalone.
$srcUninstall = Join-Path $here "uninstall.ps1"
if (Test-Path $srcUninstall) {
    $destUninstall = Join-Path $dest "uninstall.ps1"
    Copy-Item -Path $srcUninstall -Destination $destUninstall -Force
    $psExe  = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $regKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SyslogCollector"
    New-Item -Path $regKey -Force | Out-Null
    $arp = [ordered]@{
        DisplayName          = "Just Syslog"
        DisplayVersion       = "1.0.2"
        Publisher            = "Tristan Conner"
        InstallLocation      = $dest
        DisplayIcon          = $destExe
        UninstallString      = "`"$psExe`" -ExecutionPolicy Bypass -File `"$destUninstall`""
        QuietUninstallString = "`"$psExe`" -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destUninstall`""
        EstimatedSize        = [int]((Get-Item $destExe).Length / 1024)  # KB
        NoModify             = 1
        NoRepair             = 1
    }
    foreach ($name in $arp.Keys) {
        $type = if ($arp[$name] -is [int]) { "DWord" } else { "String" }
        New-ItemProperty -Path $regKey -Name $name -Value $arp[$name] -PropertyType $type -Force | Out-Null
    }
    $arpNote = "listed in Programs and Features"
} else {
    $arpNote = "uninstall.ps1 not found next to install.ps1 - skipped Programs and Features entry"
}

# --- System tray controller (parity with the macOS menu bar app) ---
$srcTray = Join-Path $here "tray"
if (Test-Path $srcTray) {
    $destTray = Join-Path $dest "tray"
    New-Item -ItemType Directory -Force -Path $destTray | Out-Null
    Copy-Item -Path (Join-Path $srcTray "*") -Destination $destTray -Recurse -Force
    $trayVbs = Join-Path $destTray "SyslogTray.vbs"
    # Start the tray at each login (all users).
    $runKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    New-ItemProperty -Path $runKey -Name "SyslogCollectorTray" `
        -Value "wscript.exe `"$trayVbs`"" -PropertyType String -Force | Out-Null
    # Start Menu + Desktop shortcuts (all users) to the tray controller.
    $wsh = New-Object -ComObject WScript.Shell
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    foreach ($dir in @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath("CommonPrograms"))) {
        $lnk = $wsh.CreateShortcut((Join-Path $dir "Just Syslog.lnk"))
        $lnk.TargetPath = $wscript
        $lnk.Arguments = "`"$trayVbs`""
        $lnk.WorkingDirectory = $destTray
        $lnk.IconLocation = (Join-Path $destTray "syslog.ico")
        $lnk.Description = "Open the Just Syslog tray controller"
        $lnk.Save()
    }
    # Launch now in the current (non-elevated) desktop session via Explorer.
    Start-Process explorer.exe -ArgumentList "`"$trayVbs`""
    $trayNote = "tray + Start Menu/Desktop shortcuts installed (starts at login)"
} else {
    $trayNote = "tray\ folder not found - skipped tray icon"
}

Write-Host ""
Write-Host "Installed. Service 'SyslogCollector' is set to start automatically at boot."
Write-Host "  Viewer : http://127.0.0.1:$UiPort/"
Write-Host "  Logs   : $LogDir  (first file appears after the first message)"
Write-Host "  Manage : services.msc  ->  Just Syslog"
Write-Host "  Tray   : $trayNote"
Write-Host "  Remove : $arpNote"
