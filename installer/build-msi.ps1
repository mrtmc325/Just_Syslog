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
# Pin the extension to the installed WiX version, or `wix build` can't resolve it.
$wixRaw = (& wix --version | Select-Object -First 1)
if ($wixRaw -match '(\d+\.\d+\.\d+)') { $wixVersion = $Matches[1] }
else { throw "Could not read WiX version from '$wixRaw'." }
Write-Host "   WiX $wixVersion"
$fwExt = "WixToolset.Firewall.wixext/$wixVersion"
& wix extension add -g $fwExt
if ($LASTEXITCODE -ne 0) { throw "Could not add $fwExt - check network / NuGet access, then retry." }

$wxs = Join-Path $root "installer\syslog-collector.wxs"
$out = Join-Path $root "JustSyslog-1.0.2-x64.msi"
Write-Host "== Building MSI =="
# -b: bind path so the tray files (Source="tray\...") resolve from installer\.
& wix build $wxs -arch x64 -ext $fwExt -b (Split-Path -Parent $wxs) -d "ExeSource=$exe" -o $out
if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE) - no MSI produced." }

Write-Host ""
Write-Host "MSI built: $out"
Write-Host "Install:   msiexec /i `"$out`"            (add LOGDIR=`"D:\Logs`" to set the log folder)"
Write-Host "Silent:    msiexec /i `"$out`" /qn LOGDIR=`"D:\Logs`""
Write-Host "Uninstall: msiexec /x `"$out`"            (removes service + firewall rule)"
