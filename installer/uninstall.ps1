# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Removes the service + firewall rule and deletes the program files.
# Log files are left in place. Run from an elevated PowerShell.
[CmdletBinding()]
param([switch]$KeepBinary)
$ErrorActionPreference = "Stop"

$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) { throw "Run this from an elevated (Administrator) PowerShell." }

$dest = Join-Path $env:ProgramFiles "SyslogCollector"
$destExe = Join-Path $dest "syslogd.exe"
if (Test-Path $destExe) {
    & $destExe uninstall
    Start-Sleep -Seconds 2
} else {
    Write-Host "syslogd.exe not found in Program Files; attempting sc cleanup."
    sc.exe delete SyslogCollector | Out-Null
}

if (-not $KeepBinary -and (Test-Path $dest)) {
    Remove-Item -Recurse -Force $dest
    Write-Host "Removed $dest"
}
Write-Host "Uninstalled. Log files (if any) were left untouched."
