# Releasing SX Studio for Windows

One command, from the top of the repository, on Windows with Flutter and Inno Setup 6 (jrsoftware.org) installed:

```
powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Version 2.0.1
```

It builds the phone page (web), the Windows app (which takes the web build into `Release\web`), then the installer, and writes in `build\windows`:

- `SX-Studio-windows-setup-<version>.exe`, a per-user installer, no admin needed
- `SHA256SUMS.txt`, its checksum

Upload both to a GitHub release of `XSVProductions/SX-Studio` tagged `v<version>`. A release with the Mac `SX-Studio-mac-<version>.pkg` needs one `SHA256SUMS.txt` that lists both. Pushing a `v*` tag runs `.github/workflows/build.yml`, which builds both, writes that file and publishes the release.

## How the app updates

Settings, Updates asks GitHub for the latest release, takes the first `.exe` asset (the Mac: `.pkg`), and downloads it and `SHA256SUMS.txt` from github.com only. A file that does not match is deleted: "The download was damaged. Try again." Then the app stops everything (lights, player, Auto Show, phones), quits, and runs the installer with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1`. `/RELAUNCH=1` makes the installer open the new version.

## From the PowerShell app

The installer keeps the PowerShell app's AppId and folder (`%LOCALAPPDATA%\Programs\ShowXpress Helper`), so its Update button installs this over it: it runs the `.exe` silently, then opens `showxpress_helper.vbs`, which now starts `sx_studio.exe`. The old scripts, icons and fonts go, the old shortcuts are replaced, and the settings in `%APPDATA%\ShowXpress Helper` and the shows stay.

`smoke.ps1` installs the built installer, opens the app and checks the engine and the phone page answer.
