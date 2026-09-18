# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# System tray controller for the Just Syslog service (Windows) - parity
# with the macOS menu bar app. Shows service status (Get-Service + the loopback
# HTTP API) and controls the service via UAC-elevated actions. WinForms only,
# no third-party dependencies. Launch hidden via SyslogTray.vbs.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Single instance per session: a second launch (shortcut / auto-start / MSI) exits.
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, "SyslogCollectorTray", [ref]$created)
if (-not $created) { exit }

$ServiceName = "SyslogCollector"
$ConfigPath  = Join-Path $env:ProgramData "SyslogCollector\config.txt"
$FieldDefs = [ordered]@{
    log_dir        = "Log directory"
    udp_port       = "Syslog UDP port"
    ui_port        = "Viewer port"
    max_file_mb    = "Max file size (MB)"
    retention_days = "Retention (days)"
    max_total_mb   = "Max total size (MB)"
}

function Get-Config {
    $c = [ordered]@{
        log_dir = "C:\SyslogCollector\logs"; udp_port = "514"; ui_port = "8514"
        max_file_mb = "100"; retention_days = "30"; max_total_mb = "2048"
    }
    if (Test-Path $ConfigPath) {
        foreach ($line in Get-Content -LiteralPath $ConfigPath) {
            $t = $line.Trim()
            if ($t.StartsWith("#") -or ($t -notmatch "=")) { continue }
            $k, $v = $t -split "=", 2
            $k = $k.Trim()
            if ($c.Contains($k)) { $c[$k] = $v.Trim() }
        }
    }
    return $c
}

function Get-Status {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $running = ($null -ne $svc) -and ($svc.Status -eq "Running")
    $messages = 0
    if ($running) {
        try {
            $port = (Get-Config).ui_port
            $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/stats" -TimeoutSec 2
            $messages = [int]$r.total_messages
        } catch { }
    }
    return @{ running = $running; messages = $messages }
}

# Run a PowerShell command elevated (UAC), quoting-safe via -EncodedCommand.
function Invoke-Elevated([string]$command) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        Start-Process powershell.exe -Verb RunAs -Wait `
            -ArgumentList "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
    } catch { }  # user cancelled the UAC prompt
}

# -Wait blocks until sc.exe returns; try/catch tolerates a cancelled UAC prompt.
function Start-Svc { try { Start-Process sc.exe -ArgumentList "start", $ServiceName -Verb RunAs -Wait } catch { }; Update-Status }
function Stop-Svc  { try { Start-Process sc.exe -ArgumentList "stop",  $ServiceName -Verb RunAs -Wait } catch { }; Update-Status }

function Clear-Logs {
    $cfg = Get-Config
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Delete every .jsonl file in $($cfg.log_dir) and restart the collector?",
        "Clear Logs", "YesNo", "Warning")
    if ($ans -ne "Yes") { return }
    Invoke-Elevated "Remove-Item -LiteralPath '$($cfg.log_dir)\*.jsonl' -Force -ErrorAction SilentlyContinue; Restart-Service -Name '$ServiceName' -ErrorAction SilentlyContinue"
    Update-Status
}

function Show-Config {
    $cfg = Get-Config
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Just Syslog Configuration"
    $form.FormBorderStyle = "FixedDialog"; $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(430, 250)
    if ($script:Icon) { $form.Icon = $script:Icon }

    $boxes = @{}
    $y = 15
    foreach ($key in $FieldDefs.Keys) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $FieldDefs[$key]
        $lbl.Location = New-Object System.Drawing.Point(15, ($y + 3))
        $lbl.Size = New-Object System.Drawing.Size(150, 20)
        $form.Controls.Add($lbl)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = [string]$cfg[$key]
        $tb.Location = New-Object System.Drawing.Point(175, $y)
        $tb.Size = New-Object System.Drawing.Size(240, 22)
        $form.Controls.Add($tb)
        $boxes[$key] = $tb
        $y += 30
    }
    $save = New-Object System.Windows.Forms.Button
    $save.Text = "Save && Restart"; $save.DialogResult = "OK"
    $save.Location = New-Object System.Drawing.Point(215, ($y + 8)); $save.Size = New-Object System.Drawing.Size(120, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.DialogResult = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(345, ($y + 8)); $cancel.Size = New-Object System.Drawing.Size(70, 28)
    $form.Controls.Add($save); $form.Controls.Add($cancel)
    $form.AcceptButton = $save; $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne "OK") { return }

    $content = "# Just Syslog configuration (Windows)"
    foreach ($key in $FieldDefs.Keys) { $content += "`n$key=$($boxes[$key].Text.Trim())" }
    $tmp = Join-Path $env:TEMP ("syslog-cfg-" + [guid]::NewGuid().ToString() + ".txt")
    Set-Content -LiteralPath $tmp -Value $content -Encoding ASCII
    $dir = Split-Path $ConfigPath
    Invoke-Elevated "New-Item -ItemType Directory -Force -Path '$dir' | Out-Null; Copy-Item -LiteralPath '$tmp' -Destination '$ConfigPath' -Force; Remove-Item -LiteralPath '$tmp' -Force; Restart-Service -Name '$ServiceName' -ErrorAction SilentlyContinue"
    Update-Status
}

function Open-Viewer { Start-Process "http://127.0.0.1:$((Get-Config).ui_port)/" }

function Quit-Tray {
    # Parity with macOS: stop the service too, then exit. Only prompt if running.
    if ((Get-Status).running) {
        try { Start-Process sc.exe -ArgumentList "stop", $ServiceName -Verb RunAs -Wait } catch { }
    }
    $script:Notify.Visible = $false
    $script:Notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# --- icon ---
$iconPath = Join-Path $PSScriptRoot "syslog.ico"
$script:Icon = if (Test-Path $iconPath) { New-Object System.Drawing.Icon $iconPath }
               else { [System.Drawing.SystemIcons]::Application }

# --- tray icon + menu ---
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:ItemHeader = $menu.Items.Add("Checking...");        $script:ItemHeader.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$script:ItemViewer = $menu.Items.Add("Open Viewer");      $script:ItemViewer.Add_Click({ Open-Viewer })
$itemConfig        = $menu.Items.Add("Configuration...");   $itemConfig.Add_Click({ Show-Config })
$script:ItemStart  = $menu.Items.Add("Start Service");    $script:ItemStart.Add_Click({ Start-Svc })
$script:ItemStop   = $menu.Items.Add("Stop Service");     $script:ItemStop.Add_Click({ Stop-Svc })
$itemClear         = $menu.Items.Add("Clear Logs...");      $itemClear.Add_Click({ Clear-Logs })
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$itemQuit          = $menu.Items.Add("Quit");             $itemQuit.Add_Click({ Quit-Tray })

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = $script:Icon
$script:Notify.Text = "Just Syslog"
$script:Notify.ContextMenuStrip = $menu
$script:Notify.Add_MouseDoubleClick({ Open-Viewer })
$script:Notify.Visible = $true

function Update-Status {
    $st = Get-Status
    if ($st.running) {
        $script:Notify.Text = "Just Syslog: Running ($($st.messages) msgs)"
        $script:ItemHeader.Text = "Running - $($st.messages) messages"
        $script:ItemStart.Enabled = $false; $script:ItemStop.Enabled = $true; $script:ItemViewer.Enabled = $true
    } else {
        $script:Notify.Text = "Just Syslog: Stopped"
        $script:ItemHeader.Text = "Stopped"
        $script:ItemStart.Enabled = $true; $script:ItemStop.Enabled = $false; $script:ItemViewer.Enabled = $false
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Status })
Update-Status
$timer.Start()

# Cold start: if the service is stopped, bring it up now so launching the app
# starts everything (tray + web + syslog listener). Prompts for UAC once;
# cancelling just leaves the tray up with the service stopped.
if (-not (Get-Status).running) { Start-Svc }

[System.Windows.Forms.Application]::Run()
