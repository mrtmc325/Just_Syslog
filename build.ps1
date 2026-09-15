# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Build release binaries on Windows. x64 always; add -X86 for the 32-bit fallback.
# Requires: rustup + the MSVC build tools (Visual Studio C++ workload).
[CmdletBinding()]
param([switch]$X86)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
    New-Item -ItemType Directory -Force -Path "dist\x64" | Out-Null

    Write-Host "== Building x64 (x86_64-pc-windows-msvc) =="
    rustup target add x86_64-pc-windows-msvc | Out-Null
    cargo build --release --target x86_64-pc-windows-msvc
    Copy-Item "target\x86_64-pc-windows-msvc\release\syslogd.exe" "dist\x64\syslogd.exe" -Force

    if ($X86) {
        Write-Host "== Building x86 (i686-pc-windows-msvc) =="
        New-Item -ItemType Directory -Force -Path "dist\x86" | Out-Null
        rustup target add i686-pc-windows-msvc | Out-Null
        cargo build --release --target i686-pc-windows-msvc
        Copy-Item "target\i686-pc-windows-msvc\release\syslogd.exe" "dist\x86\syslogd.exe" -Force
    }

    Write-Host ""
    Write-Host "Done. Binaries in dist\ :"
    Get-ChildItem -Recurse dist\*.exe | ForEach-Object { "  $($_.FullName)  ($([math]::Round($_.Length/1KB)) KB)" }
    Write-Host ""
    Write-Host "Next: installer\install.ps1  (elevated)  - or build the Inno Setup installer."
}
finally { Pop-Location }
