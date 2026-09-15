# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Zero-extra-tooling installer. Copies syslogd.exe into Program Files and
# registers it as an auto-start Windows service with a firewall rule.
# Run from an elevated PowerShell:  powershell -ExecutionPolicy Bypass -File install.ps1
[CmdletBinding()]
param(
    [string]$LogDir = "C:\SyslogCollector\logs",
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
Copy-Item -Path $BinaryPath -Destination $destExe -Force
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# --- register service + firewall via the binary's own installer ---
Write-Host "Registering service (log dir: $LogDir, UDP/$UdpPort, UI 127.0.0.1:$UiPort)..."
& $destExe install --log-dir "$LogDir" --udp-port $UdpPort --ui-port $UiPort
if ($LASTEXITCODE -ne 0) { throw "Service registration failed (exit $LASTEXITCODE)." }

Write-Host ""
Write-Host "Installed. Service 'SyslogCollector' is set to start automatically at boot."
Write-Host "  Viewer : http://127.0.0.1:$UiPort/"
Write-Host "  Logs   : $LogDir  (first file appears after the first message)"
Write-Host "  Manage : services.msc  ->  Syslog Collector"
