<p align="center"><img src="assets/aim_movers_1024.png" width="120" alt=""></p>

# AIM MOVERS

A small Windows + Mac app for **ShowXpress** that re-places the moving-head dancefloor patterns at each new venue.

You aim each head at the center of tonight's dancefloor (and, optionally, at one corner) in a single scene. AIM MOVERS then
writes the per-head offsets and sizes into every dancefloor movement scene, so all the patterns land on the floor. It also keeps the pattern shapes symmetrical.

> Built for a show using Chauvet Intimidator Hybrid 140SR / 251SR heads, with the scenes `DF AIM (ADJUST)` and `CENTER SPOT`.

## Download

Get the latest installer from **[Releases](../../releases/latest)**:

| | File | First run |
|---|---|---|
| **Windows** | `AIM-MOVERS-windows-setup-x.y.z.exe` | If Windows SmartScreen appears: **More info -> Run anyway**. |
| **Mac** | `AIM-MOVERS-mac-x.y.z.pkg` | If macOS blocks it: **System Settings -> Privacy & Security -> Open Anyway** (or right-click the file -> Open). When AIM MOVERS opens for the first time, it offers to install PowerShell 7 (free, from Microsoft). |

The installers aren't code-signed, which is why Windows and macOS ask the first time.

**What gets installed**
- **Windows:** "AIM MOVERS" on the Desktop and in the Start menu. Uninstall it from *Settings -> Apps*.
- **Mac:** *AIM MOVERS* in Applications, plus *AIM MOVERS* and *SYNC FROM WINDOWS* on the Desktop.

## Weekly use

1. In ShowXpress, open the scene **DF AIM (ADJUST)**.
   - **Step 1:** aim every head at the center of the dancefloor.
   - **Step 2 (optional):** aim a head at the same corner (front-left as seen from the DJ) to set its size.
2. Save, and close ShowXpress.
3. Open **AIM MOVERS**, check the heads, set the overall size, and press **Apply to show**.
4. Open ShowXpress again and check the **DF CHECK 140 / 251** scenes. The beams should trace the floor corners.

**Reset to normal** puts every head back to its default center and size.

AIM MOVERS never writes anything while ShowXpress is open.

## Mac + Boot Camp

**SYNC FROM WINDOWS** copies the show from the Windows (Boot Camp) drive to the Mac, one way only. The first time, it asks which folder is the Mac show. Before every sync, the previous Mac show is kept in `~/AwaazTools/previous Mac show`.

## Show folder

AIM MOVERS looks for the show in this order:
1. The folder written in `show_path.txt`:
   - **Windows:** `%APPDATA%\AIM MOVERS\show_path.txt` (optional)
   - **Mac:** `~/AwaazTools/show_path.txt`, written by SYNC FROM WINDOWS
2. `~/TheLightingController/LightShows/Awaaz Lightshow`
3. The only show in `LightShows` that has a `CENTER SPOT` scene

## Building

Pushing a tag such as `v1.0.1` makes GitHub Actions build both installers and publish them as a release.
- **Windows:** Inno Setup, `windows/aim_movers.iss`
- **Mac:** `pkgbuild`, `mac/build_pkg.sh`
