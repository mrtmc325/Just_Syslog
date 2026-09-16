# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Removes the service, firewall rule, Programs and Features entry, and program
# files. Log files are left in place. Self-elevates via UAC, so it works both
# from an elevated prompt and from the Programs and Features "Uninstall" button.
[CmdletBinding()]
param([switch]$KeepBinary)
$ErrorActionPreference = "Stop"

# Self-elevate if not admin (Add/Remove Programs launches the uninstaller plain).
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) {
    $relaunch = @("-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($KeepBinary) { $relaunch += "-KeepBinary" }
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $relaunch
    exit
}

$dest = Join-Path $env:ProgramFiles "SyslogCollector"
$destExe = Join-Path $dest "syslogd.exe"
if (Test-Path $destExe) {
    & $destExe uninstall
    Start-Sleep -Seconds 2
} else {
    Write-Host "syslogd.exe not found in Program Files; attempting sc cleanup."
    sc.exe delete SyslogCollector | Out-Null
}

# Remove the Programs and Features (Add/Remove Programs) entry.
$regKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SyslogCollector"
if (Test-Path $regKey) { Remove-Item -Path $regKey -Recurse -Force }

if (-not $KeepBinary -and (Test-Path $dest)) {
    # This script lives inside $dest, so remove the folder from a detached
    # process after we exit (avoids locking ourselves). EncodedCommand sidesteps
    # all quoting of the path.
    $deleter = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$dest' -Recurse -Force -ErrorAction SilentlyContinue"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deleter))
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
        -ArgumentList "-NoProfile -EncodedCommand $enc" | Out-Null
    Write-Host "Removing $dest ..."
}
Write-Host "Uninstalled. Log files (if any) were left untouched."
