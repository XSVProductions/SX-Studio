; AIM MOVERS - Windows installer (Inno Setup 6). Per-user install, no admin needed.
;   build:  set AIM_VERSION=1.0.0  &  ISCC windows\aim_movers.iss   -> build\windows\AIM-MOVERS-windows-setup-<version>.exe
#define AppVer GetEnv("AIM_VERSION")
#if AppVer == ""
  #define AppVer "1.0.0"
#endif
; StopGui closes a running AIM MOVERS window server. It is PowerShell, base64-encoded so no quoting is needed:
;   Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
;     Where-Object { $_.CommandLine -like '*df_aim_gui*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
#define StopGui "-NoProfile -NonInteractive -EncodedCommand RwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBQAHIAbwBjAGUAcwBzACAALQBGAGkAbAB0AGUAcgAgACIATgBhAG0AZQA9ACcAcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlACcAIABPAFIAIABOAGEAbQBlAD0AJwBwAHcAcwBoAC4AZQB4AGUAJwAiACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAEMAbwBtAG0AYQBuAGQATABpAG4AZQAgAC0AbABpAGsAZQAgACcAKgBkAGYAXwBhAGkAbQBfAGcAdQBpACoAJwAgAH0AIAB8ACAARgBvAHIARQBhAGMAaAAtAE8AYgBqAGUAYwB0ACAAewAgAFMAdABvAHAALQBQAHIAbwBjAGUAcwBzACAALQBJAGQAIAAkAF8ALgBQAHIAbwBjAGUAcwBzAEkAZAAgAC0ARgBvAHIAYwBlACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAGkAbABlAG4AdABsAHkAQwBvAG4AdABpAG4AdQBlACAAfQA="

[Setup]
AppId={{6B0F3C1E-7A41-4E7B-9C4C-2E1A5D8F4A31}
AppName=AIM MOVERS
AppVersion={#AppVer}
AppVerName=AIM MOVERS {#AppVer}
AppPublisher=AIM MOVERS
DefaultDirName={localappdata}\Programs\AIM MOVERS
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\windows
OutputBaseFilename=AIM-MOVERS-windows-setup-{#AppVer}
SetupIconFile=..\assets\aim_movers.ico
UninstallDisplayIcon={app}\aim_movers.ico
UninstallDisplayName=AIM MOVERS
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Put AIM MOVERS on the Desktop"

[Files]
Source: "..\src\df_aim.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\df_aim_gui.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\aim_movers.vbs";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\aim_movers.ico";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\aim_movers_1024.png"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\AIM MOVERS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\aim_movers.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\aim_movers.ico"; Comment: "Aim the dancefloor movers"
Name: "{autodesktop}\AIM MOVERS"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\aim_movers.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\aim_movers.ico"; Comment: "Aim the dancefloor movers"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\aim_movers.vbs"""; Description: "Open AIM MOVERS now"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{#StopGui}"; Flags: runhidden; RunOnceId: "StopGui"

[Code]
// close a running AIM MOVERS so an update takes effect straight away
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  R: Integer;
begin
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '{#StopGui}', '', SW_HIDE, ewWaitUntilTerminated, R);
  Result := '';
end;
