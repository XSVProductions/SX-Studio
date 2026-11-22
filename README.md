<p align="center"><img src="assets/aim_movers_1024.png" width="120" alt=""></p>

# ShowXpress Helper

A small Windows + Mac app for **ShowXpress** that gets the moving heads ready for each new venue. It used to be called AIM MOVERS.

Its main tabs:

- **Tonight's Rig:** you tick the heads that are hung tonight, and every chase scene on a live button (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH...) drops the steps that would be dark without them. Only whole steps are taken out, and a step that also lights a blinder or uplight is always kept. The full scenes are kept in `rig_state.json` in the show folder, so ticking every head again puts them back exactly.
- **Aim Movers:** you aim each head at the center of tonight's dancefloor (and, optionally, at one corner) in a single scene. The app writes the per-head offsets and sizes into every dancefloor movement scene, so all the patterns land on the floor. It also keeps the pattern shapes symmetrical.
- **Skip Flash:** you tap the heads that are set up tonight, and the **SKIP FLASH** scene is rebuilt with only those heads. A head that isn't hung leaves a dark gap in the chase, so leaving it out keeps the flash smooth.
- **APC mini:** shows the 8x8 pad grid in each pad's own colours, with the scene and page each pad plays and what the four faders do. Tap a pad, then tap another one to move it there (or swap the two). It flags pads that fire two buttons, mappings outside the 64 pads, and pads whose scene is missing.
- **Speed Faders:** lists every live button with the master speed fader it follows (MOVEMENTS, COLORS, STROBES, CHASES...). You can change any button, or a whole page at once.
- **Auto Show:** the Helper presses your looks in ShowXpress one after another, each for a number of bars at your BPM, while you're busy mixing. You build the looks yourself from your ShowXpress buttons.
- **Health Check:** a scan for problems that have caused trouble before. It looks for buttons whose scene is missing, scenes that use deleted fixtures, `beats = 0`, speed faders that don't exist, APC pads that fire two buttons, buttons stacked on the same spot, and colour chases that jump back across the colour wheel when they loop. Each problem comes with a recommended fix, and many can be fixed with one click. Every fix can be reverted.

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
- **Mac:** *ShowXpress Helper* in Applications, plus a *ShowXpress Helper* shortcut on the Desktop. It opens in its own window with its own Dock icon (to keep it there: right-click the icon -> *Options -> Keep in Dock*).

The Helper always opens on its **Home** page: the tabs, a Google Drive backup button, **Launch / Close ShowXpress** at the top, and an **Update** button there when a newer version is on GitHub (it downloads and installs it for you). Put your own logo next to the Helper's by saving it as `brand.png` in `%APPDATA%\ShowXpress Helper\` (Mac: `~/AwaazTools/brand.png`).

## Weekly use

**Tonight's Rig**
1. Close ShowXpress and go to the **Tonight's Rig** tab.
2. Tap the heads that aren't hung tonight. The list below shows which steps each chase will lose (dashed red).
3. Press **Save tonight's rig**. Next week, press **All heads (put back)** and save.

If you edit a trimmed scene in ShowXpress, the edited version counts as the full scene from then on.

**Aim Movers**
1. In ShowXpress, open the scene **DF AIM (ADJUST)**.
   - **Step 1:** aim every head at the center of the dancefloor.
   - **Step 2 (optional):** aim a head at the same corner (front-left as seen from the DJ) to set its size.
2. Save, and close ShowXpress.
3. Open **ShowXpress Helper**, check the heads, set the overall size, and press **Apply to show**.
4. Open ShowXpress again. **DF CHECK 140 + 251** come on by themselves (with the remote on, see below). The beams should trace the floor corners.

**Aim live** - the quicker way (Windows and Mac). Press **Aim live** on the Aim Movers tab. ShowXpress closes (save first), and the Helper drives the DMX interface itself, so the real head follows your mouse as you drag:
- Only the selected head is lit. Speed **Fine / Normal / Fast**, **Shift** = finer, **Ctrl** = faster, **arrow keys** nudge.
- **N / P** (or Tab) = next / previous head, **1 / 2** = center / corner step. **Flip** left/right or up/down per head if it moves the wrong way.
- **Save & finish** writes the aims into DF AIM (ADJUST) (or ROOM AIM), applies them, and opens ShowXpress again.
- On the Mac it uses the driver that comes with ShowXpress for Mac, so ShowXpress has to be installed there (in Applications, or its ShowXpress folder in Applications).
- Only one program can use the interface. If the NovaStar LED software (NovaLCT) is holding it, the Helper offers to pause its USB scanner.

**One head per T-bar:** aim just one head of each T-bar pair (set up in Rig Test). The head next to it gets the same aim, unless you aim it too.

**Reset to normal** puts every head back to its default center and size.

**Aim Movers - Room** (the *Room* switch at the top of the tab) does the same for **AROUND ROOM** and **AROUND ROOM SLOW**, using the scene **ROOM AIM (ADJUST)** and checking with **ROOM CHECK** (both on the SETUP page; the tab adds them if they're missing). Width = across the room, Height = up and down the walls.

**GRAND ENTRANCE** (MOVEMENTS page) is one normal step scene that moves like AROUND ROOM, with per-head colours (a Generator scene can't give two movers different colours). Every room Apply / Home rebuilds its pan/tilt steps from `GRAND ENTRANCE.gpj`, so it follows the room aim. **Step 1 is the template**: whatever you set in step 1 (colours, prism, focus, dimmer, uplights ...) is copied to every step. A mover in the scene but taken out of `GRAND ENTRANCE.gpj` stays still where step 1 aims it (tonight: #4 + #7, white GOBO 4, slow rotate) - to re-aim it, change its pan/tilt in step 1. If you reshape AROUND ROOM in Generator, heads you never aimed for the room follow the new shape instead of drifting.

**Tonight's Color**
Pick the decor colour (quick picks, the wheel or a #hex code) and press **Save tonight's color**. It writes two scenes, each on a **TONIGHTS COLOR** button: on MOVER COLORS (every mover on the nearest colour of its wheel - colour only, so it goes on top of any movement) and on UPLIGHTS (the uplights and the Ovation in exactly that colour).

**APC mini** - tap a pad to move it, or pick its colour while playing and when idle.

**Rig Test** - **RIG ID** comes on in ShowXpress by itself when you open the tab (or press it on the SETUP page), tap each truss spot in the tab and pick the look you see, then **Save to 2D view**. RIG ID gives 140 #1-#8 a solid colour (white, deep red, light green, yellow, green, sky blue, blue, purple) and #9-#16 the same colours pulsing; the swatches in the tab match the real beams. If the tab says the RIG ID scene is the old one, close ShowXpress and press **Update RIG ID**. It moves the 140s in the 2D view (blinder top center, uplight bottom center) and, ticked by default, also saves Tonight's Rig and SKIP FLASH. *Bigger event* adds a top-middle and a bottom-middle tower.

**Pre-show Check** - one list of what to look at before the guests arrive. Where the Helper can fix it there's a button (never sleep on the charger, USB power saving off, restart for Windows updates, launch ShowXpress, sync to Google Drive, or open the right tab).

**Skip Flash**
1. Close ShowXpress, open **ShowXpress Helper** and go to the **Skip Flash** tab.
2. Tap the heads you have tonight (amber = in use). **All** / **None** work per model.
3. Press **Save to SKIP FLASH**.

The flash order follows the original 16-head skip order, with any 251s spread in between. The step time and the flash colour come from the scene itself, so changes you make to them in ShowXpress are kept.

**APC mini / Speed Faders:** make your changes, then press **Save**. Only the pad notes or the `masterspeedfader` setting in `live.ini` change.

**Health Check**
1. Close ShowXpress and go to the **Health Check** tab. Each problem shows a **Fix:** line with the recommended fix.
2. Where there's a button next to it, press it to apply that fix.
3. Open ShowXpress and try it. If you don't like it, close ShowXpress and press **Revert** under *Fixes you applied*. Press **Keep** to forget the backup once you're happy.

The backups are kept in `health_fixes.json` in the show folder. If you change the same thing again in ShowXpress after a fix, Revert asks before it puts the old version back.

**Auto Show**
1. Press **+ New look** and pick the buttons that should play **together** (say one movement + a colour + the uplights), or set them up in ShowXpress and press **New look from what's playing**. To cycle through movements, make **one look per movement**: MOVEMENTS plays one button at a time, so the tab offers to split a look that has several of them.
2. Set how many bars each look plays, the order (in order / shuffle) and what happens when you stop.
3. Set the BPM (or **Tap** it), press **Start Auto Show**, and press **Bar 1 now** on a downbeat. **Next look**, **Back** and **Hold** work while it plays, and whatever you press on the APC still works on top.

ShowXpress doesn't send its beat to other apps, so the Auto Show counts bars from its own BPM. The looks are saved in `auto_show.json` in the show folder.

**ShowXpress remote:** RIG ID, DF CHECK, ROOM CHECK and the Auto Show use ShowXpress's *External App* remote (on this computer only). The first time, press **Turn on remote control** in any of those tabs; the Helper switches it on in the show with a password only it uses. The Helper never presses anything while something outside the SETUP page is playing, so a running show isn't cut.

ShowXpress Helper never writes anything while ShowXpress is open. Changes you save while it's open are queued (bar at the top). The moment ShowXpress closes, the Helper does them and opens ShowXpress again.

## Google Drive

**Sync to Google Drive** (Home page, and Pre-show Check when it's due) copies the show into **Google Drive > AWAAZ > Lighting > *show folder name*** through the Google Drive for desktop app, which uploads it. One way only: new and changed files are copied, nothing is deleted, and a file that is newer on Google Drive is left alone. Close ShowXpress first so the saved show is copied.

On the Mac, copy the show from Google Drive into `~/TheLightingController/LightShows` (or write its folder into `~/AwaazTools/show_path.txt`). SYNC FROM WINDOWS is gone; installing this version removes its Desktop shortcut.

## Show folder

ShowXpress Helper looks for the show in this order:
1. The folder written in `show_path.txt`:
   - **Windows:** `%APPDATA%\ShowXpress Helper\show_path.txt` (optional; the old `%APPDATA%\AIM MOVERS\show_path.txt` still works)
   - **Mac:** `~/AwaazTools/show_path.txt` (optional)
2. `~/TheLightingController/LightShows/Awaaz Lightshow`
3. The only show in `LightShows` that has a `CENTER SPOT` scene

## Building

Pushing a tag such as `v1.1.0` makes GitHub Actions build both installers and publish them as a release.
- **Windows:** Inno Setup, `windows/aim_movers.iss`
- **Mac:** `pkgbuild`, `mac/build_pkg.sh`
