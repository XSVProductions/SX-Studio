; SX Studio, Windows installer (Inno Setup 6). Per-user install, no admin needed.
;   build:  ui\tool\release.ps1 -Version 2.0.0   ->  build\windows\SX-Studio-windows-setup-<version>.exe
; The app's Update button runs it with /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1:
; /RELAUNCH=1 opens the new version when it is done. The PowerShell app's updater opens showxpress_helper.vbs instead.
#define AppVer GetEnv("SX_VERSION")
#if AppVer == ""
  #define AppVer "2.0.0"
#endif
#define Release "..\..\build\windows\x64\runner\Release"
; StopOld closes the PowerShell SX Studio (or SX Helper, or AIM MOVERS) this app replaces. It is PowerShell, base64-encoded so no quoting is needed:
;   Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
;     Where-Object { $_.CommandLine -like '*df_aim_gui*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
#define StopOld "-NoProfile -NonInteractive -EncodedCommand RwBlAHQALQBDAGkAbQBJAG4AcwB0AGEAbgBjAGUAIABXAGkAbgAzADIAXwBQAHIAbwBjAGUAcwBzACAALQBGAGkAbAB0AGUAcgAgACIATgBhAG0AZQA9ACcAcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlACcAIABPAFIAIABOAGEAbQBlAD0AJwBwAHcAcwBoAC4AZQB4AGUAJwAiACAAfAAgAFcAaABlAHIAZQAtAE8AYgBqAGUAYwB0ACAAewAgACQAXwAuAEMAbwBtAG0AYQBuAGQATABpAG4AZQAgAC0AbABpAGsAZQAgACcAKgBkAGYAXwBhAGkAbQBfAGcAdQBpACoAJwAgAH0AIAB8ACAARgBvAHIARQBhAGMAaAAtAE8AYgBqAGUAYwB0ACAAewAgAFMAdABvAHAALQBQAHIAbwBjAGUAcwBzACAALQBJAGQAIAAkAF8ALgBQAHIAbwBjAGUAcwBzAEkAZAAgAC0ARgBvAHIAYwBlACAALQBFAHIAcgBvAHIAQQBjAHQAaQBvAG4AIABTAGkAbABlAG4AdABsAHkAQwBvAG4AdABpAG4AdQBlACAAfQA="

[Setup]
; the PowerShell app's AppId and folder, so this upgrades it in place and keeps one entry in Windows' app list
AppId={{6B0F3C1E-7A41-4E7B-9C4C-2E1A5D8F4A31}
AppName=SX Studio
AppVersion={#AppVer}
AppVerName=SX Studio {#AppVer}
AppPublisher=XSV Productions
DefaultDirName={localappdata}\Programs\ShowXpress Helper
UsePreviousAppDir=no
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
; The app is 64-bit, like ShowXpress's interface driver it loads. The installer itself stays in 32-bit mode like the
; PowerShell app's, so it carries on that one's uninstall record instead of adding a second uninstaller.
ArchitecturesAllowed=x64compatible
OutputDir=..\..\..\build\windows
OutputBaseFilename=SX-Studio-windows-setup-{#AppVer}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\sx_studio.exe
UninstallDisplayName=SX Studio
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; PrepareToInstall below closes the app itself
CloseApplications=no

[Tasks]
Name: "desktopicon"; Description: "Put SX Studio on the Desktop"

[Files]
; the app, with the page phones and tablets load (web) and the Visual C++ runtime release.ps1 puts next to it
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs
; the PowerShell app's own updater opens this file when the installer is done: it starts the new app
Source: "showxpress_helper.vbs"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
; the PowerShell app this replaces (its settings live in %APPDATA%\ShowXpress Helper and stay)
Type: files; Name: "{app}\*.ps1"
Type: files; Name: "{app}\*.png"
Type: files; Name: "{app}\*.ico"
Type: files; Name: "{app}\version.txt"
Type: filesandordirs; Name: "{app}\fonts"
; an older version of this app: files a newer build no longer has must not stay behind
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\web"
; shortcuts and folders from the app's earlier names (SX Helper, ShowXpress Helper, AIM MOVERS)
Type: files; Name: "{autodesktop}\SX Helper.lnk"
Type: files; Name: "{autoprograms}\SX Helper.lnk"
Type: files; Name: "{autodesktop}\ShowXpress Helper.lnk"
Type: files; Name: "{autoprograms}\ShowXpress Helper.lnk"
Type: files; Name: "{autodesktop}\AIM MOVERS.lnk"
Type: files; Name: "{autoprograms}\AIM MOVERS.lnk"
Type: filesandordirs; Name: "{localappdata}\Programs\AIM MOVERS"

[Icons]
Name: "{autoprograms}\SX Studio"; Filename: "{app}\sx_studio.exe"; WorkingDir: "{app}"; AppUserModelID: "XSVProductions.SXStudio"; Comment: "Lighting control for ShowXpress - XSV Productions"
Name: "{autodesktop}\SX Studio"; Filename: "{app}\sx_studio.exe"; WorkingDir: "{app}"; AppUserModelID: "XSVProductions.SXStudio"; Comment: "Lighting control for ShowXpress - XSV Productions"; Tasks: desktopicon

[Run]
Filename: "{app}\sx_studio.exe"; Description: "Open SX Studio now"; Flags: postinstall nowait skipifsilent
; an update from the app itself: silent, then opens the new version
Filename: "{app}\sx_studio.exe"; Flags: nowait; Check: Relaunch

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM sx_studio.exe"; Flags: runhidden; RunOnceId: "StopApp"

[Code]
// True when the app started this installer for an update (/RELAUNCH=1)
function Relaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

// close a running SX Studio, this one or the PowerShell one, so an update takes effect straight away.
// The app quits by itself before its update installs: give it up to 10 s, then end it.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  R, I: Integer;
begin
  I := 0;
  while (I < 40) and (FindWindowByClassName('FLUTTER_RUNNER_WIN32_WINDOW') <> 0) do begin
    Sleep(250);
    I := I + 1;
  end;
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM sx_studio.exe', '', SW_HIDE, ewWaitUntilTerminated, R);
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '{#StopOld}', '', SW_HIDE, ewWaitUntilTerminated, R);
  Result := '';
end;
