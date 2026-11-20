<p align="center"><img src="assets/aim_movers_1024.png" width="120" alt=""></p>

# ShowXpress Helper

A small Windows + Mac app for **ShowXpress** that gets the moving heads ready for each new venue. It used to be called AIM MOVERS.

It has two tabs:

- **Aim Movers:** you aim each head at the center of tonight's dancefloor (and, optionally, at one corner) in a single scene. The app writes the per-head offsets and sizes into every dancefloor movement scene, so all the patterns land on the floor. It also keeps the pattern shapes symmetrical.
- **Skip Flash:** you tap the heads that are set up tonight, and the **SKIP FLASH** scene is rebuilt with only those heads. A head that isn't hung leaves a dark gap in the chase, so leaving it out keeps the flash smooth.

> Built for a show using Chauvet Intimidator Hybrid 140SR / 251SR heads, with the scenes `DF AIM (ADJUST)`, `CENTER SPOT` and `SKIP FLASH`.

## Download

Get the latest installer from **[Releases](../../releases/latest)**:

| | File | First run |
|---|---|---|
| **Windows** | `ShowXpress-Helper-windows-setup-x.y.z.exe` | If Windows SmartScreen appears: **More info -> Run anyway**. |
| **Mac** | `ShowXpress-Helper-mac-x.y.z.pkg` | If macOS blocks it: **System Settings -> Privacy & Security -> Open Anyway** (or right-click the file -> Open). When ShowXpress Helper opens for the first time, it offers to install PowerShell 7 (free, from Microsoft). |

The installers aren't code-signed, which is why Windows and macOS ask the first time. Installing over AIM MOVERS replaces it, including its shortcuts.

**What gets installed**
- **Windows:** "ShowXpress Helper" on the Desktop and in the Start menu. Uninstall it from *Settings -> Apps*.
- **Mac:** *ShowXpress Helper* in Applications, plus *ShowXpress Helper* and *SYNC FROM WINDOWS* on the Desktop.

## Weekly use

**Aim Movers**
1. In ShowXpress, open the scene **DF AIM (ADJUST)**.
   - **Step 1:** aim every head at the center of the dancefloor.
   - **Step 2 (optional):** aim a head at the same corner (front-left as seen from the DJ) to set its size.
2. Save, and close ShowXpress.
3. Open **ShowXpress Helper**, check the heads, set the overall size, and press **Apply to show**.
4. Open ShowXpress again and check the **DF CHECK 140 / 251** scenes. The beams should trace the floor corners.

**Reset to normal** puts every head back to its default center and size.

**Skip Flash**
1. Close ShowXpress, open **ShowXpress Helper** and go to the **Skip Flash** tab.
2. Tap the heads you have tonight (amber = in use). **All** / **None** work per model.
3. Press **Save to SKIP FLASH**.

The flash order follows the original 16-head skip order, with any 251s spread in between. The step time and the flash colour come from the scene itself, so changes you make to them in ShowXpress are kept.

ShowXpress Helper never writes anything while ShowXpress is open.

## Mac + Boot Camp

**SYNC FROM WINDOWS** copies the show from the Windows (Boot Camp) drive to the Mac, one way only. The first time, it asks which folder is the Mac show. Before every sync, the previous Mac show is kept in `~/AwaazTools/previous Mac show`.

## Show folder

ShowXpress Helper looks for the show in this order:
1. The folder written in `show_path.txt`:
   - **Windows:** `%APPDATA%\ShowXpress Helper\show_path.txt` (optional; the old `%APPDATA%\AIM MOVERS\show_path.txt` still works)
   - **Mac:** `~/AwaazTools/show_path.txt`, written by SYNC FROM WINDOWS
2. `~/TheLightingController/LightShows/Awaaz Lightshow`
3. The only show in `LightShows` that has a `CENTER SPOT` scene

## Building

Pushing a tag such as `v1.1.0` makes GitHub Actions build both installers and publish them as a release.
- **Windows:** Inno Setup, `windows/aim_movers.iss`
- **Mac:** `pkgbuild`, `mac/build_pkg.sh`
