# Handover for the Flutter port of SX Studio

For the coding agent picking this up, and for the maintainer. Written 25 November 2026.

**Since then:** 2.0.0 was released on 25 November 2026, so the Flutter app is what every laptop runs, and new features (the music detector in 2.0.5, the DMX output setting) go here. The sections below describe the port as it was handed over.

## What this is

This folder holds SX Studio rewritten in Dart and Flutter. It is a like-for-like port of the PowerShell app in `../src` as of commit `1b68d92` (version 1.9.15). Same tabs, same routes, same wording, same bytes in the ShowXpress show files. ShowXpress stays. The port adds no features.

Nothing here is released. The PowerShell app is still what every laptop runs, its files are untouched, and its workflow still publishes on `v*` tags. The Flutter app's version is 2.0.0 and nobody has installed it outside two test machines.

Read `CLAUDE.md` next. It has the rules for working in this code. This file covers the state of things.

## Layout

```
packages/sx_api      Wire types and the HTTP client. Compiles for web.
packages/sx_engine   The laptop side: show files, tools, DMX, MIDI, the HTTP API.
packages/sx_release  Signed releases: release.json, its Ed25519 signature, the setup program.
ui                   The Flutter app, one codebase for the laptop window and the phone page.
ui/windows/installer Inno Setup script, smoke test, release notes for maintainers.
ui/tool/release.ps1  Builds and signs a Windows release.
packaging/mac        The Mac .pkg and the DMX helper (Swift).
```

On the laptop the app starts the engine on its own isolate and talks to it over the loopback address on port 47321, the old port. A phone loads the web build from the same engine. Both sides call the same `/api/...` routes the PowerShell server had.

## Where each old file went

| PowerShell app | Flutter port |
|---|---|
| `src/df_aim_gui.ps1`, the server | `packages/sx_engine/lib/src/server/` and `server/routes/` |
| `src/df_aim_gui.ps1`, the page | `ui/lib/screens/<tab id>/`, `ui/lib/shell.dart`, `ui/lib/theme.dart` |
| `src/df_aim.ps1` | `tools/aim/` |
| `src/apc.ps1`, `speed.ps1`, `health.ps1`, `color.ps1`, `flip.ps1`, `rig.ps1`, `rig_test.ps1`, `skip_flash.ps1`, `preshow.ps1`, `looks.ps1`, `gdrive.ps1` | `tools/<same name>.dart` |
| `src/scene_edit.ps1`, `move_edit.ps1` | `tools/scene_edit.dart` and `tools/scene_edit/`, `tools/move_edit.dart` and `tools/move_edit/` |
| `src/apc40.ps1` | `tools/apc40.dart` (layout, Info, Save) and `apc40/` (the bridge, winmm MIDI) |
| `src/player.ps1` | `player/` |
| `src/dmx_out.ps1` | `dmx/` |
| `src/sx_remote.ps1` | `sx/sx_remote.dart`, `sx/auto_player.dart`, `tools/auto_show.dart` |
| `src/sx_quit.ps1` | `sx/` |
| `src/show_common.ps1` | `show/` |
| Settings, export and import, updates | `settings/` |
| `windows/aim_movers.iss` | `ui/windows/installer/sx_studio.iss` |
| `mac/build_pkg.sh`, `mac/dmx/main.swift` | `packaging/mac/` |

Paths in the right column without a package are under `packages/sx_engine/lib/src/`. Each ported function names the old function it came from in its doc comment, so searching the Dart code for a PowerShell function name finds its port.

## Running and testing

```
cd packages/sx_engine && dart pub get && dart test     # 843 tests
cd packages/sx_release && dart pub get && dart test    # 11 tests
cd ui && flutter test                                  # 220 tests
cd ui && flutter run -d windows                        # the app
```

The engine suite's weight is in `test/parity`, the old-versus-new checks. Each runs the PowerShell tool from `../src` and its Dart port on the same copy of a real show, then compares the answer and every file left behind, byte for byte. They need PowerShell on PATH and `SX_SHOW` set to a real show folder. Without those they skip themselves and the suite still passes, with 377 engine tests run where 843 would. A green run with no `SX_SHOW` proves much less, and that is what GitHub's run is, because a show folder is never in git. Set it on your own machine.

The counts above are from Linux with PowerShell 7. The suites also pass on Windows 11 with Windows PowerShell 5.1, where the engine count is 840 because three tests of the Mac DMX helper don't run there. That run matters because the two PowerShells differ (number formatting, sort order of ties, JSON layout) and the port follows 5.1.

## Keeping the two apps in step

Until the switch, the PowerShell app is the released one and bug fixes land there first. Every change to `../src` after `1b68d92` needs the same change here, or the port falls behind. This already happened once: versions 1.9.5 to 1.9.15 came out while the port was being written, and were ported afterwards. That is a good worked example of the routine:

| Change in the PowerShell app | Where it went |
|---|---|
| APC40 mk2 tab and bridge (`apc40.ps1`, `/api/apc40*`) | `sx_api/lib/src/apc40.dart`, `tools/apc40.dart`, `apc40/`, `routes/apc40.dart`, `ui/lib/screens/apc40/` |
| Pad drag, right-click menu and click-away on the APC mini | `ui/lib/screens/apc/` |
| Settings export and import (`/api/config/*`) | `sx_api/lib/src/config.dart`, `settings/config_io.dart`, `routes/config.dart`, `ui/lib/screens/settings/config_card.dart` |
| Skip Flash tab renamed Strobe | `ui/lib/tabs.dart`, the queue label, `settings_store.dart` |
| MIDI device 0 only | `tools/apc.dart`, `tools/health.dart`, `player/player_show.dart` |
| Old app windows closed at start (`Close-OldWindows`) | `ui/lib/boot/old_windows.dart` |

The routine for a new change:

1. Read the diff of `../src`.
2. Port it by the steps in `CLAUDE.md` under "Porting an area".
3. Write or extend the parity test, so the old tool and the new one are compared on a real show.
4. Record the commit of `../src` the port now matches, by updating the commit id at the top of this file.

A change that only fixes the PowerShell page's HTML or CSS still needs a look at the matching screen in `ui/lib/screens/`.

## What differs from the PowerShell app, on purpose

The rule was that nothing differs unless there is a reason. These are the differences.

**Updates are signed.** The PowerShell app installs the first `.exe` of the newest GitHub release and checks nothing. This app installs only what a signed `release.json` names, after checking size and SHA-256. `ui/windows/installer/README.md` has the details. A small setup program, `SX-Studio-Setup.exe`, installs the newest release on a new laptop.

**The window is a real window.** The PowerShell app opens a browser in app mode. This one is a Flutter desktop window. Phones still get a web page from the laptop.

**Tools write more carefully.** The old tools wrote show files first and their own state last with no way back. The port writes each file to a temporary name and swaps it in, writes state last, and puts earlier files back when a later write fails. It writes an empty state file where the old tools deleted one, because Google Drive import could bring a deleted file back.

**Every route that changes something is a POST.** That includes asking for a phone pairing code, which was a GET.

**Health Check's "Match the 251s" fix works.** The old server refused it.

**Refusals are JSON.** Same status codes and same words, in a JSON body where the old server sent plain text.

**The console menus are gone.** The `.ps1` tools could be run from a terminal with prompts and menus. The app never used those, and they were not ported.

**Smaller ones:**

- The firewall note in Settings says "SX Studio" where it said PowerShell, because SX Studio is now the program that listens.
- A size that isn't a number gets a refusal. The old app crashed.
- The APC40 bridge runs inside the app, so its status shows the app's process id.
- On a touch screen a pad drags after a long press, so a swipe over the grid still scrolls. Phones get no pad menu, which matches what an iPhone showed with the old page.
- The settings export is laid out with two-space JSON indents. Keys, nesting and types are the same, and files move between the two apps in both directions.
- While a settings import runs, the card shows a line of text where the old page had a full-screen overlay.

**Old bugs kept as they are**, because copying them was safer than guessing at intent. Each is worth a decision:

- A new pairing code does not lift a phone lockout.
- When a pad or fader import is refused, the warning starts with a lowercase letter.
- The settings export looks at only the first 50 device keys, so a rig with many heads can lose some live-aim flip choices.
- Two settings imports in the same second share one backup folder.
- On the APC40, switching page while holding a flash pad leaves the button on in ShowXpress.
- An APC40 fader value of 3000000000 or more in the layout file breaks Info and Save.

## What was checked, and what was not

Checked:

- All three suites, on Linux with PowerShell 7 and on Windows with Windows PowerShell 5.1.
- A real install on Windows 11 with real ShowXpress: the silent switch from the PowerShell app, all tabs, the save queue while ShowXpress is open, force close, closing the window with the Auto Show running, the five-minute idle quit, phone pairing and the laptop-only refusals, a silent reinstall, the setup program refusing an unsigned release, uninstall.
- The Mac package builds on Apple Silicon, the app starts, opens and closes real ShowXpress, and the DMX helper loads both of ShowXpress's Mac drivers (Intel under Rosetta and Apple Silicon).
- Settings files exported by each app import into the other with the same result. On Windows the export lands in Downloads, "Show the file" selects it in Explorer, and the Import dialog works. The same three work in the built Mac app with Finder.
- The switch from an installed 1.9.15 with its window open: the installer stops the old server, the new app comes up on port 47321 and closes the old window, and other browser windows are left alone. The old APC40 bridge process exits by itself.
- The APC40 bridge in the installed Windows app with no controller: it reports the APC40 as missing, keeps polling, and the app stays up.
- The MIDI code against the real `winmm.dll`: listing devices, a missing device, and the whole output side (short message, sysex, reset, close) through Windows' built-in synth.

Not checked, and the reason:

- **No light has gone through a DMX interface.** There was no interface on either test machine. Live output, the SX Player and Rig Test are ported and tested against recorded frames, and that is all. Try these first with a real rig.
- **No APC40 or APC mini was plugged in.** The APC40 bridge's logic is tested with fakes. Its MIDI code (`apc40/win_midi.dart`) is new FFI code. The input side, which is how a pad press arrives, cannot run without a controller and never has. Sysex has not gone to a real APC40.
- **An update from a real GitHub release.** The update path was tested against local files and a staged release, never against a published one.
- **`flutter.yml` has never run on GitHub.** It was written and read, and its steps were run by hand on the test machines.
- **The Mac package was not installed.** It was built and its contents were run from the build folder. `packaging/mac/smoke.sh` installs it and needs `sudo`.
- **The setup program is not code-signed.** That needs the certificate holder.
- **Pointer lock for live aim** was not tried by hand.

## Before the first release

In this order. `RELEASE_SETUP.md` has the commands.

1. **Replace the release key.** `packages/sx_release/lib/src/release_key.dart` holds a test public key. Its private half sits on a test machine and will be deleted. The maintainer generates the real key on the computer releases will come from, and the public half goes in that file. Until then nothing built here can take an update.
2. **Rebuild and code-sign the setup program**, and upload it to a pre-release tagged `setup`.
3. **Run `flutter.yml` once** by hand or with a `flutter-v2.0.0` tag, and fix whatever GitHub's runners disagree with.
4. **Try the app at a real gig setup**, with the DMX interface and the APC controllers.
5. **Switch the tags.** `build.yml` goes to `legacy-v*` and `flutter.yml` to `v*`, in one commit. From then on a `v2.x` tag is a Flutter release, and the next time a PowerShell install checks for updates it installs the Flutter app over itself. Settings and shows stay where they are. The installer keeps the old AppId and folder so that works.

Step 5 is the point of no easy return. An installed PowerShell app that updates is on the Flutter app from then on.

## Open decisions for the maintainer

- **Console menus.** Does anyone run the `.ps1` tools from a terminal? If so they need porting or keeping. If not, nothing to do.
- **Oldest Mac.** The Flutter app needs macOS 12 or newer. The PowerShell app's `Info.plist` says 10.15.
- **The kept bugs** in the list above. Fix them here, in `../src`, or both.
- **When to switch.** Nothing forces a date. The two apps can sit side by side as long as changes to `../src` keep getting ported.
- **Fixes for the PowerShell app.** Twelve small fixes to `../src` turned up while porting: write safety, a phone being able to restart the laptop, unescaped show names on the page, and others. They are pull request #20 (`audit-fixes`), separate from this folder and safe to take or leave on their own. The port already behaves the fixed way.
