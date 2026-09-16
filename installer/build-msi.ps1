# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Build a single-file x64 .msi. Requires: Rust + MSVC build tools (to compile
# syslogd.exe) and the WiX v5 CLI (`dotnet tool install --global wix`).
[CmdletBinding()]
param([switch]$SkipExeBuild)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # repo root
$exe  = Join-Path $root "target\x86_64-pc-windows-msvc\release\syslogd.exe"

if (-not $SkipExeBuild) {
    Write-Host "== Building syslogd.exe (x64 release) =="
    rustup target add x86_64-pc-windows-msvc | Out-Null
    Push-Location $root
    try { cargo build --release --target x86_64-pc-windows-msvc } finally { Pop-Location }
}
if (-not (Test-Path $exe)) { throw "syslogd.exe not found at $exe - build it first (drop -SkipExeBuild)." }

# WiX v5 CLI
if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    throw "WiX CLI not found. Install it with:  dotnet tool install --global wix   (needs the .NET SDK: winget install Microsoft.DotNet.SDK.8)"
}
Write-Host "== Ensuring WiX Firewall extension =="
wix extension add -g WixToolset.Firewall.wixext | Out-Null

$wxs = Join-Path $root "installer\syslog-collector.wxs"
$out = Join-Path $root "SyslogCollector-1.0.0-x64.msi"
Write-Host "== Building MSI =="
wix build $wxs -arch x64 -ext WixToolset.Firewall.wixext -d "ExeSource=$exe" -o $out

Write-Host ""
Write-Host "MSI built: $out"
Write-Host "Install:   msiexec /i `"$out`"            (add LOGDIR=`"D:\Logs`" to set the log folder)"
Write-Host "Silent:    msiexec /i `"$out`" /qn LOGDIR=`"D:\Logs`""
Write-Host "Uninstall: msiexec /x `"$out`"            (removes service + firewall rule)"
