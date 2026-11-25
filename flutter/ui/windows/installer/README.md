# Releasing SX Studio

## A release

On Windows with Flutter and Inno Setup 6 (jrsoftware.org), from the `flutter` folder:

```
powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Version 2.0.1 [-MacPkg <SX-Studio-mac-2.0.1.pkg>]
```

It builds the phone page (web), the Windows app (which takes the web build into `Release\web`) and the installer, then signs. In `build\windows`:

- `SX-Studio-windows-setup-<version>.exe`: per-user installer, no admin needed
- `release.json`: per computer, the installer's file name, size, SHA-256 and install arguments
- `release.json.sig`: Ed25519 signature of `release.json`, made with the release key
- `SHA256SUMS.txt`: checksums for people; nothing trusts it

Upload them all (and the Mac `.pkg`) to a GitHub release of `XSVProductions/SX-Studio` tagged `v<version>`. The script prints the files and a `gh release create` line. A release holds exactly one `.exe`, the installer: the PowerShell SX Studio installs the first `.exe` of the newest release. A release without a `.pkg` gives Macs no update.

Signing happens only here, on the maintainer's computer. Pushing a release tag runs `.github/workflows/flutter.yml` at the top of the repository: it tests and builds both installers and never signs or publishes. Take the Mac `.pkg` from its `mac` artifact (`gh run download --name mac`). First time: `RELEASE_SETUP.md` in the `flutter` folder, which also says which tags the workflow answers.

## The release key

`release.json` is trusted only with a signature by the release key. Its public half is built into the app and the setup program (`packages/sx_release/lib/src/release_key.dart`). The private half is `%USERPROFILE%\.sx-release\release_key`, outside every repository and never on GitHub; `SX_RELEASE_KEY` points elsewhere. Keep a copy offline. Anyone holding it can ship an update every SX Studio installs; lose it and installed apps take no update until they are reinstalled with a new key.

New key, only if the old one is lost or leaked: `cd packages/sx_release && dart run sx_release:release_tool keygen`, put the public key it prints into `release_key.dart`, rebuild and re-sign the setup program, and reinstall SX Studio everywhere.

## The setup program

`SX-Studio-Setup.exe` installs the newest SX Studio on a new laptop: it asks GitHub for the latest release, checks `release.json` against the key built in, downloads the installer it names, checks size and SHA-256, and opens it. It knows no app version, so it is built and code-signed once:

```
powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Stub
signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 <certificate options> build\setup\SX-Studio-Setup.exe
gh release create setup --prerelease --latest=false --title "SX Studio setup" --notes "Installs the newest SX Studio." build\setup\SX-Studio-Setup.exe
```

It lives only in the release tagged `setup`, a pre-release that is never Latest, at `https://github.com/XSVProductions/SX-Studio/releases/download/setup/SX-Studio-Setup.exe`. Never put it in a normal release. Rebuild it only when the key changes or `release.json` gets a new `format`.

## How the app updates

Settings, Updates asks GitHub for the latest release. Update downloads `release.json` and its signature from github.com, checks the signature ("This update isn't signed by SX Studio. It was not installed."), checks the version is the release's, downloads the installer it names and checks its size and SHA-256 ("The download was damaged. Try again."). Then the app stops everything (lights, player, Auto Show, phones), quits, and runs the installer with the signed arguments (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS`). After any silent install the installer opens the new version.

## From the PowerShell app

The installer keeps the PowerShell app's AppId and folder (`%LOCALAPPDATA%\Programs\ShowXpress Helper`), so its Update button installs this over it. It runs the `.exe` silently: the installer closes the old app, removes its scripts, icons and fonts, replaces the shortcuts and opens the new app. The old updater then opens `showxpress_helper.vbs` from the same folder; the new one starts nothing when the app started in the last minute, otherwise it starts the app (old taskbar pins point at it). Settings in `%APPDATA%\ShowXpress Helper` and the shows stay. The old app checks no signature, so this one switch trusts GitHub's HTTPS alone.

`smoke.ps1` installs the built installer, opens the app and checks the engine and the phone page answer, then uninstalls it while it runs and checks nothing is left.
