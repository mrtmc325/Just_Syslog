; Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
;
; Inno Setup script -> a single distributable Setup.exe that installs Syslog
; Collector into Program Files, registers the auto-start service + firewall
; rule, and prompts for the log folder. Build both binaries first (build.ps1
; -X86), then compile this with the Inno Setup Compiler (ISCC.exe).

#define AppName "Syslog Collector"
#define AppVersion "1.0.0"
#define AppPublisher "Tristan Conner"

[Setup]
AppId={{7C2E9B10-6D3A-4F1E-9B0E-1A2B3C4D5E6F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\SyslogCollector
DefaultGroupName=Syslog Collector
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\syslogd.exe
OutputBaseFilename=SyslogCollector-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
; Install as 64-bit on x64 Windows (Program Files, not the x86 folder);
; falls back to 32-bit mode automatically on x86 Windows.
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
; x64 build on 64-bit Windows...
Source: "..\dist\x64\syslogd.exe"; DestDir: "{app}"; DestName: "syslogd.exe"; \
    Flags: ignoreversion; Check: Is64BitInstallMode
; ...x86 fallback on 32-bit Windows.
Source: "..\dist\x86\syslogd.exe"; DestDir: "{app}"; DestName: "syslogd.exe"; \
    Flags: ignoreversion; Check: not Is64BitInstallMode

[Icons]
Name: "{group}\Open Syslog Viewer"; Filename: "http://127.0.0.1:8514/"
Name: "{group}\Uninstall Syslog Collector"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\syslogd.exe"; \
    Parameters: "install --log-dir ""{code:GetLogDir}"" --udp-port 514 --ui-port 8514"; \
    StatusMsg: "Registering service and firewall rule..."; \
    Flags: runhidden waituntilterminated
Filename: "http://127.0.0.1:8514/"; Description: "Open the log viewer now"; \
    Flags: postinstall shellexec nowait skipifsilent

[UninstallRun]
Filename: "{app}\syslogd.exe"; Parameters: "uninstall"; \
    Flags: runhidden waituntilterminated; RunOnceId: "RemoveService"

[Code]
var
  LogPage: TInputDirWizardPage;

procedure InitializeWizard;
begin
  LogPage := CreateInputDirPage(wpSelectDir,
    'Log folder',
    'Where should collected syslog messages be stored?',
    'Log files are written to this folder. The first file is created only after the first message is received.' + #13#10 +
    'Choose a folder with enough free space, then click Next.',
    False, '');
  LogPage.Add('');
  LogPage.Values[0] := 'C:\SyslogCollector\logs';
end;

function GetLogDir(Param: String): String;
begin
  Result := LogPage.Values[0];
end;
