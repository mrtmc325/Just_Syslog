' Copyright (c) 2026 Tristan Conner <tristan@conner.house>
' SPDX-License-Identifier: MIT
' Launch the tray controller with no visible PowerShell console window.
Dim shell, dir, ps1
Set shell = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps1 = dir & "SyslogTray.ps1"
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
