# Release setup, first time

For the maintainer who publishes SX Studio releases, and for the coding agent helping them. An agent can run every command here. It asks the maintainer only where a step says **ask**.

Releases are signed on the maintainer's own Windows computer with a key that never leaves it. GitHub builds and tests. It never signs.

## 1. Tools (once)

Install these, then open a new terminal:

```
winget install --id Git.Git -e
winget install --id GitHub.cli -e
winget install --id JRSoftware.InnoSetup -e
```

Flutter: follow https://docs.flutter.dev/get-started/install/windows, then `flutter doctor`. It needs Visual Studio's "Desktop development with C++" workload. `flutter doctor` must show no errors for Windows and Chrome/web.

GitHub: `gh auth login`. **Ask** the maintainer to sign in with an account that can write to `XSVProductions/SX-Studio`. Then:

```
gh repo clone XSVProductions/SX-Studio
cd SX-Studio
cd packages\sx_release; dart pub get; dart test; cd ..\..
```

## 2. The release key (once, ever)

```
cd packages\sx_release
dart run sx_release:release_tool keygen
```

- This writes the private key to `%USERPROFILE%\.sx-release\release_key`. It refuses to overwrite an existing key and refuses to write inside a git folder.
- It prints the **public** key: one line of base64.
- **Ask** the maintainer to back up `release_key` offline, for example on a USB stick in a drawer and in a password manager.
  - Anyone with this file can push an update that every SX Studio installs.
  - Lose it and installed apps can't take updates until they are reinstalled.
- Never commit it, paste it into chat, or upload it anywhere, including GitHub secrets.

Send the **public** key line to the person who holds the code-signing certificate. It isn't secret.

## 3. Build the key into the app (once, ever)

Either side can do this.

1. Put the public key in `packages/sx_release/lib/src/release_key.dart`: `const releasePublicKey = '<public key>';`
2. Check it matches: `dart run sx_release:release_tool pubkey` must print the same line.
3. Run `dart test`, then commit and push.

The setup program has the key built in, so it has to be rebuilt and signed after this:

```
powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Stub
```

This makes `build\setup\SX-Studio-Setup.exe`.

- The certificate holder signs it with signtool: `signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 <certificate options> SX-Studio-Setup.exe`
- They upload the signed file to the release tagged `setup`. It is a pre-release and must never be marked Latest:

```
gh release create setup --prerelease --latest=false --title "SX Studio setup" --notes "Installs the newest SX Studio." SX-Studio-Setup.exe
```

If `setup` already exists, use `gh release upload setup SX-Studio-Setup.exe --clobber` instead.

New laptops get SX Studio from https://github.com/XSVProductions/SX-Studio/releases/download/setup/SX-Studio-Setup.exe. The stub is rebuilt only when the key changes or `release.json` gets a new `format`. Normal releases never touch it.

## 4. Every release

Replace `2.0.1` below with the new version.

1. Tag the commit and push the tag. GitHub then runs the tests and builds both installers (`.github/workflows/build.yml`):

   ```
   git tag v2.0.1
   git push origin v2.0.1
   gh run watch
   ```

   Stop if it fails.

2. Get the Mac installer that GitHub built:

   ```
   gh run download --name mac --dir build\mac-ci
   ```

   If several runs show up, pick the one for the tag. You can also pass the run id from `gh run list`.

3. Build the Windows installer here and sign `release.json`:

   ```
   powershell -ExecutionPolicy Bypass -File ui\tool\release.ps1 -Version 2.0.1 -MacPkg build\mac-ci\SX-Studio-mac-2.0.1.pkg
   ```

4. Run the `gh release create v2.0.1 ...` line it prints. A release must hold exactly one `.exe`, the installer. The script checks this.

5. Check the release: on an installed SX Studio, go to Settings, Updates. It should offer 2.0.1 and install it.

A release without a `.pkg` gives Macs no update. One without `release.json.sig` installs nowhere: the app and the setup program refuse anything not signed with the key from step 2.

More detail is in `ui/windows/installer/README.md`: what the app checks, the silent install, and the switch from the PowerShell app.
