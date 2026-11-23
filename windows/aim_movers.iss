; SX Helper (was AIM MOVERS) - Windows installer (Inno Setup 6). Per-user install, no admin needed.
;   build:  set AIM_VERSION=1.1.0  &  ISCC windows\aim_movers.iss   -> build\windows\SX-Helper-windows-setup-<version>.exe
#define AppVer GetEnv("AIM_VERSION")
#if AppVer == ""
  #define AppVer "1.0.0"
#endif
; StopGui closes a running SX Helper (or old AIM MOVERS) window server. It is PowerShell, base64-encoded so no quoting is needed:
;   Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
;     Where-Object { $_.CommandLine -like '*df_aim_gui*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
#define StopGui "-NoProfile -NonInteractive -EncodedCommand RwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBQAHIAbwBjAGUAcwBzACAALQBGAGkAbAB0AGUAcgAgACIATgBhAG0AZQA9ACcAcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlACcAIABPAFIAIABOAGEAbQBlAD0AJwBwAHcAcwBoAC4AZQB4AGUAJwAiACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAEMAbwBtAG0AYQBuAGQATABpAG4AZQAgAC0AbABpAGsAZQAgACcAKgBkAGYAXwBhAGkAbQBfAGcAdQBpACoAJwAgAH0AIAB8ACAARgBvAHIARQBhAGMAaAAtAE8AYgBqAGUAYwB0ACAAewAgAFMAdABvAHAALQBQAHIAbwBjAGUAcwBzACAALQBJAGQAIAAkAF8ALgBQAHIAbwBjAGUAcwBzAEkAZAAgAC0ARgBvAHIAYwBlACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAGkAbABlAG4AdABsAHkAQwBvAG4AdABpAG4AdQBlACAAfQA="

[Setup]
AppId={{6B0F3C1E-7A41-4E7B-9C4C-2E1A5D8F4A31}
AppName=SX Helper
AppVersion={#AppVer}
AppVerName=SX Helper {#AppVer}
AppPublisher=SX Helper
DefaultDirName={localappdata}\Programs\ShowXpress Helper
; same AppId as AIM MOVERS so it upgrades in place, but into the new folder (old folder + shortcuts removed below)
UsePreviousAppDir=no
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\windows
OutputBaseFilename=SX-Helper-windows-setup-{#AppVer}
SetupIconFile=..\assets\aim_movers.ico
UninstallDisplayIcon={app}\aim_movers.ico
UninstallDisplayName=SX Helper
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Put SX Helper on the Desktop"

[Files]
Source: "..\src\df_aim.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\df_aim_gui.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\skip_flash.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\rig.ps1";          DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\apc.ps1";          DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\speed.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\health.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\rig_test.ps1";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\preshow.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\color.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\gdrive.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\version.txt";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\show_common.ps1";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\sx_remote.ps1";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\dmx_out.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\showxpress_helper.vbs";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\aim_movers.ico";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\aim_movers_1024.png"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
; old shortcuts from when it was called ShowXpress Helper (user 2026-11-22: renamed SX Helper; the folders keep the old name)
Type: files; Name: "{autodesktop}\ShowXpress Helper.lnk"
Type: files; Name: "{autoprograms}\ShowXpress Helper.lnk"
; leftovers from when it was called AIM MOVERS
Type: files; Name: "{autodesktop}\AIM MOVERS.lnk"
Type: files; Name: "{autoprograms}\AIM MOVERS.lnk"
Type: filesandordirs; Name: "{localappdata}\Programs\AIM MOVERS"

[Icons]
Name: "{autoprograms}\SX Helper"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\showxpress_helper.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\aim_movers.ico"; Comment: "Aim the movers, tonight's rig, APC pads and speed faders for ShowXpress"
Name: "{autodesktop}\SX Helper"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\showxpress_helper.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\aim_movers.ico"; Comment: "Aim the movers, tonight's rig, APC pads and speed faders for ShowXpress"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\showxpress_helper.vbs"""; Description: "Open SX Helper now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#StopGui}"; Flags: runhidden; RunOnceId: "StopGui"

[Code]
// close a running SX Helper / AIM MOVERS so an update takes effect straight away
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  R: Integer;
begin
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '{#StopGui}', '', SW_HIDE, ewWaitUntilTerminated, R);
  Result := '';
end;
