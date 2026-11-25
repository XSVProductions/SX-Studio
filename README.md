<p align="center"><img src="assets/aim_movers_1024.png" width="120" alt=""></p>

# SX Studio

**SX Studio** by XSV Productions: a Windows + Mac app for **ShowXpress** that gets the lights ready for each venue and can play the show itself (the SX Player). It used to be called SX Helper (before that ShowXpress Helper, and AIM MOVERS).

Its main tabs:

- **Tonight's Rig:** you tick the heads that are hung tonight, and every chase scene on a live button (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH...) drops the steps that would be dark without them. Only whole steps are taken out, and a step that also lights a blinder or uplight is always kept. The full scenes are kept in `rig_state.json` in the show folder, so ticking every head again puts them back exactly.
- **Aim Movers:** you aim each head at the center of tonight's dancefloor (and, optionally, at one corner) in a single scene. The app writes the per-head offsets and sizes into every dancefloor movement scene, so all the patterns land on the floor. It also keeps the pattern shapes symmetrical.
- **Skip Flash:** you tap the heads that are set up tonight, and the **SKIP FLASH** scene is rebuilt with only those heads. A head that isn't hung leaves a dark gap in the chase, so leaving it out keeps the flash smooth.
- **APC mini:** shows the 8x8 pad grid in each pad's own colours, with the scene and page each pad plays and what the four faders do. Tap a pad, then tap another one to move it there (or swap the two). It flags pads that fire two buttons, mappings outside the 64 pads, and pads whose scene is missing.
- **Speed Faders:** lists every live button with the master speed fader it follows (MOVEMENTS, COLORS, STROBES, CHASES...). You can change any button, or a whole page at once.
- **Auto Show:** SX Studio presses your looks in ShowXpress one after another, each for a number of bars at your BPM, while you're busy mixing. You build the looks yourself from your ShowXpress buttons.
- **Scene Editor:** open any scene, change its steps (values, step times, fades; copy, move or delete steps; add or take out a channel) and see it on the lights as you go, then save. Only what you changed is written into the scene file; everything else stays exactly as ShowXpress wrote it.
- **Movement Editor:** open any movement (the Generator's `.gpj` files) and change its shape by dragging the points. You can also change its speed, how the heads follow each other, the other channels' graphs and each head's aim and size. The heads move on screen and on the lights as you go. Like the Scene Editor, only what you changed is written.
- **One-click Looks:** pick a template (contrast pairs, a colour chase, a beat strobe or a prism fan), choose the colours and the heads, see it on the lights, and SX Studio makes it as a **new** scene. No scene you have is changed and ShowXpress's live board isn't touched. You can put the new scene straight on one of the SX Player's own pages.
- **Phone & iPad:** the same SX Studio on your iPhone or iPad over the Wi-Fi, with touch-friendly screens and Aim live by finger. See [Phone & iPad](#phone--ipad).
- **Health Check:** a scan for problems that have caused trouble before. It looks for buttons whose scene is missing, scenes that use deleted fixtures, `beats = 0`, speed faders that don't exist, APC pads that fire two buttons, buttons stacked on the same spot, and colour chases that jump back across the colour wheel when they loop. Each problem comes with a recommended fix, and many can be fixed with one click. Every fix can be reverted.

> Built for a show using Chauvet Intimidator Hybrid 140SR / 251SR heads, with the scenes `DF AIM (ADJUST)`, `CENTER SPOT` and `SKIP FLASH`.

## Download

Get the latest installer from **[Releases](../../releases/latest)**:

| | File | First run |
|---|---|---|
| **Windows** | `SX-Studio-windows-setup-x.y.z.exe` | If Windows SmartScreen appears: **More info -> Run anyway**. |
| **Mac** | `SX-Studio-mac-x.y.z.pkg` | If macOS blocks it: **System Settings -> Privacy & Security -> Open Anyway** (or right-click the file -> Open). When SX Studio opens for the first time, it offers to install PowerShell 7 (free, from Microsoft). |

The installers aren't code-signed, which is why Windows and macOS ask the first time. Installing over AIM MOVERS replaces it, including its shortcuts.

**What gets installed**
- **Windows:** "SX Studio" on the Desktop and in the Start menu. Uninstall it from *Settings -> Apps*.
- **Mac:** *SX Studio* in Applications, plus an *SX Studio* shortcut on the Desktop. It opens in its own window with its own Dock icon (to keep it there: right-click the icon -> *Options -> Keep in Dock*).

SX Studio always opens on its **Home** page: the tabs, a **⚙ Settings** button (top right), **Launch / Close ShowXpress** at the top, and an **Update** button there when a newer version is on GitHub (it downloads and installs it for you). Put your own logo next to SX Studio's by saving it as `brand.png` in `%APPDATA%\ShowXpress Helper\` (Mac: `~/AwaazTools/brand.png`).

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
3. Open **SX Studio**, check the heads, set the overall size, and press **Apply to show**.
4. Open ShowXpress again. **DF CHECK 140 + 251** come on by themselves (with the remote on, see below). The beams should trace the floor corners.

**Aim live** - the quicker way (Windows and Mac). Press **Aim live** on the Aim Movers tab. ShowXpress closes (save first), and SX Studio drives the DMX interface itself, so the real head follows your mouse as you drag:
- Only the selected head is lit. Speed **Fine / Normal / Fast**, **Shift** = finer, **Ctrl** = faster, **arrow keys** nudge.
- **N / P** (or Tab) = next / previous head, **1 / 2** = center / corner step. **Flip** left/right or up/down per head if it moves the wrong way.
- **Save & finish** writes the aims into DF AIM (ADJUST) (or ROOM AIM), applies them, and opens ShowXpress again.
- On the Mac it uses the driver that comes with ShowXpress for Mac, so ShowXpress has to be installed there (in Applications, or its ShowXpress folder in Applications).
- Only one program can use the interface. If the NovaStar LED software (NovaLCT) is holding it, SX Studio offers to pause its USB scanner.

**One head per T-bar:** aim just one head of each T-bar pair (set up in Rig Test). The head next to it gets the same aim, unless you aim it too.

**Reset to normal** puts every head back to its default center and size.

**Aim Movers - Room** (the *Room* switch at the top of the tab) does the same for **AROUND ROOM** and **AROUND ROOM SLOW**, using the scene **ROOM AIM (ADJUST)** and checking with **ROOM CHECK** (both on the SETUP page; the tab adds them if they're missing). Width = across the room, Height = up and down the walls.

**GRAND ENTRANCE** (MOVEMENTS page) is one normal step scene that moves like AROUND ROOM, with per-head colours (a Generator scene can't give two movers different colours). Every room Apply / Home rebuilds its pan/tilt steps from `GRAND ENTRANCE.gpj`, so it follows the room aim. **Step 1 is the template**: whatever you set in step 1 (colours, prism, focus, dimmer, uplights ...) is copied to every step. A mover in the scene but taken out of `GRAND ENTRANCE.gpj` stays still where step 1 aims it (tonight: #4 + #7, white GOBO 4, slow rotate) - to re-aim it, change its pan/tilt in step 1. If you reshape AROUND ROOM in Generator, heads you never aimed for the room follow the new shape instead of drifting.

**Tonight's Color**
Pick the decor colour (quick picks, the wheel or a #hex code) and press **Save tonight's color**. It writes two scenes, each on a **TONIGHTS COLOR** button: on MOVER COLORS (every mover on the nearest colour of its wheel - colour only, so it goes on top of any movement) and on UPLIGHTS (the uplights and the Ovation in exactly that colour).

**APC mini** - tap a pad to move it, or pick its colour while playing and when idle.

**Rig Test** - **RIG ID** comes on in ShowXpress by itself when you open the tab (or press it on the SETUP page), tap each truss spot in the tab and pick the look you see, then **Save to 2D view**. RIG ID gives 140 #1-#8 a solid colour (white, deep red, light green, yellow, green, sky blue, blue, purple) and #9-#16 the same colours pulsing; the swatches in the tab match the real beams. If the tab says the RIG ID scene is the old one, close ShowXpress and press **Update RIG ID**. It moves the 140s in the 2D view (blinder top center, uplight bottom center) and, ticked by default, also saves Tonight's Rig and SKIP FLASH. *Bigger event* adds a top-middle and a bottom-middle tower.

**Pre-show Check** - one list of what to look at before the guests arrive. Where SX Studio can fix it there's a button (never sleep on the charger, USB power saving off, restart for Windows updates, launch ShowXpress, sync to Google Drive, or open the right tab).

**Skip Flash**
1. Close ShowXpress, open **SX Studio** and go to the **Skip Flash** tab.
2. Tap the heads you have tonight (amber = in use). **All** / **None** work per model.
3. Press **Save to SKIP FLASH**.

The flash order follows the original 16-head skip order, with any 251s spread in between. The step time and the flash colour come from the scene itself, so changes you make to them in ShowXpress are kept.

**APC mini / Speed Faders:** make your changes, then press **Save**. Only the pad notes or the `masterspeedfader` setting in `live.ini` change.

**Health Check**
1. Close ShowXpress and go to the **Health Check** tab. Each problem shows a **Fix:** line with the recommended fix.
2. Where there's a button next to it, press it to apply that fix.
3. Open ShowXpress and try it. If you don't like it, close ShowXpress and press **Revert** under *Fixes you applied*. Press **Keep** to forget the backup once you're happy.

The backups are kept in `health_fixes.json` in the show folder. If you change the same thing again in ShowXpress after a fix, Revert asks before it puts the old version back.

**Scene Editor**
1. Go to the **Scene Editor** tab and tap a scene (search by scene or button name).
2. Pick a step at the top (or a square in the grid: rows are heads, columns are steps, amber = lit), and one or more heads. Change the values with the sliders, the number, or the named ranges from the fixture (colours, shutter...). **fade** = the channel glides from the step before over this step's time.
3. **Copy step**, **Move**, **Delete step** and **Step time** work on the step you're on. **Add channel** / **×** add or take out a channel of the picked heads in every step.
4. **Show on the lights** (ShowXpress closes; save it first) sends the step you're on to the rig as you change it. **Play the scene** runs it with its step times and fades. Nothing is saved yet.
5. Press **Save scene**. While ShowXpress is open the save is queued, like the other tabs.

What's safe: saving changes only the values, steps and channels you changed. The rest of the file (things SX Studio doesn't know, spacing, line endings) is kept byte for byte, and SX Studio checks the result two ways before writing it. If the scene was changed in ShowXpress after you opened it, the save is refused (press Reload). Every save keeps the scene as it was before; **Earlier versions** puts one back. Backups are kept outside the show folder (`%APPDATA%\ShowXpress Helper\scene_backups`, Mac `~/AwaazTools/scene_backups`), so they don't go to Google Drive. A scene SX Studio can't read safely is shown read-only and stays a ShowXpress job. The live buttons, fixture patching, the 3D view and macros stay in ShowXpress.

If **Tonight's Rig** has trimmed the scene, the tab says so: the version you save counts as the full scene from then on.

**Movement Editor**
1. Go to the **Movement Editor** tab and tap a movement (search by movement or button name). In the **SX Player** you can also right-click (or long-press) any button and pick **Edit scene** / **Edit movement**.
2. **Pan / Tilt** is the shape the heads trace. Drag a point to move it, drag empty space to move the whole shape, double-click to add a point, and press Delete to remove the selected one. **Smaller / Bigger / Mirror / Reverse direction / Centre** change the whole shape. The coloured dots are the heads, moving as they will on the night.
3. On the right: **Plays** (ticked = the channel is sent), **Between points** (smooth curve, straight lines or jump), **Once round in** (the cycle time) and **Each next head behind by** (the shift that makes the heads chase each other).
4. The other channels (dimmer, colour, gobo...) are graphs: left to right is once round the cycle, bottom to top is the value.
5. **Heads** sets each head's aim and zoom. For movements that **Aim Movers** looks after, those come from the Aim Movers tab and are only shown here. The shape you draw is kept as you drew it the next time Aim Movers saves.
6. **Show on the lights** (ShowXpress closes; save it first) plays the movement on the rig as you change it. A movement only moves the heads, so pick a scene in **Light it with** to light them. Then press **Save movement** (queued while ShowXpress is open).

What's safe: the same rules as the Scene Editor. Only the values and points you changed are written, and the rest of the file stays byte for byte. The result is checked before writing. A movement changed in ShowXpress since you opened it is refused. Every save keeps a backup (**Earlier versions**; `%APPDATA%\ShowXpress Helper\move_backups`, Mac `~/AwaazTools/move_backups`). Reverse pan/tilt stays with **Reverse heads**. Saving **GRAND ENTRANCE** also makes its step scene again.

**One-click Looks**
1. Go to the **Looks** tab and pick a template:
   - **Contrast pairs**: two colours side by side (every other head, or first half / second half), swapping each hold time. Set up to 4 pairs; they play one after another.
   - **Colour chase**: tap colours in the order you want; **Back and forth** plays them there and back so the chase never jumps across the colour wheel. **Spread over the heads** puts each head a step further along.
   - **Strobe**: one flash each beat (put it on a player button with a BPM) or a steady strobe at the speed you set, in the colour you pick.
   - **Prism fan**: prisms in and spinning (direction and speed set per prism), with zoom and focus; it has no colour of its own, so play it with a colour look.
2. **Heads** picks which heads take part (by model). Heads SX Studio has no definition for, and groups of several heads, are left out and listed.
3. **How it looks** plays the look on screen. **Show on the lights** (ShowXpress closes; save it first) plays it on the rig. Nothing is written yet.
4. Give it a name and press **Make the scene**. Then you can put it on a page of the SX Player (a beat look gets the BPM flash), or open it in the **Scene Editor** to fine-tune it.

What's safe: a look is always a **new** scene file, written the way ShowXpress writes scenes and checked before it is saved. A name that's already in the show is refused, so no scene is ever overwritten. live.ini isn't touched: to have the look on a ShowXpress button, add it there yourself.

**Auto Show**
1. Press **+ New look** and pick the buttons that should play **together** (say one movement + a colour + the uplights), or set them up in ShowXpress and press **New look from what's playing**. To cycle through movements, make **one look per movement**: MOVEMENTS plays one button at a time, so the tab offers to split a look that has several of them.
2. Set how many bars each look plays, the order (in order / shuffle) and what happens when you stop.
3. Set the BPM (or **Tap** it), press **Start Auto Show**, and press **Bar 1 now** on a downbeat. **Next look**, **Back** and **Hold** work while it plays, and whatever you press on the APC still works on top.

ShowXpress doesn't send its beat to other apps, so the Auto Show counts bars from its own BPM. The looks are saved in `auto_show.json` in the show folder.

**ShowXpress remote:** RIG ID, DF CHECK, ROOM CHECK and the Auto Show use ShowXpress's *External App* remote (on this computer only). The first time, press **Turn on remote control** in any of those tabs; SX Studio switches it on in the show with a password only it uses. SX Studio never presses anything while something outside the SETUP page is playing, so a running show isn't cut.

SX Studio never writes anything while ShowXpress is open. Changes you save while it's open are queued (bar at the top). The moment ShowXpress closes, SX Studio does them and opens ShowXpress again.

## Phone & iPad

SX Studio also runs on your iPhone and iPad over Wi-Fi: rig setup (Rig Test, Tonight's Rig, Skip Flash), **Aim live with your finger**, Tonight's Color, the Pre-show Check and the Auto Show. All the other tabs work there too. The laptop still does the work, so SX Studio has to be open on it.

1. On the laptop, press **⚙** (top right) and go to **Phone & iPad** and tick **Let my phone and iPad connect**. The first time, Windows asks whether PowerShell may use the network: tick **Private networks** and press **Allow**. On a Mac, allow **pwsh** to accept incoming connections if macOS asks.
2. On the iPhone or iPad, open **Safari** and go to the address shown there, e.g. `http://DJ-LAPTOP.local:47322`. The `.local` address stays the same at every venue; the number address changes with the network.
3. **Share -> Add to Home Screen**, then open it from the Home Screen icon.
4. On the laptop, press **Pair a phone** and type the 6-digit code on the phone. Each phone or iPad is paired once and stays paired: after a restart of the phone, the laptop or SX Studio it connects straight away. **Unpair all phones** locks them all out again.

**Demo (no laptop needed):** https://xsvproductions.github.io/showxpress-helper/demo/ runs the same phone screens against a pretend show. Nothing reaches ShowXpress or the lights. Add it to the Home Screen (Share -> Add to Home Screen) and it works without internet too. It rebuilds by itself whenever SX Studio's page changes on `main` (`demo/build_demo.py`, `.github/workflows/demo.yml`).

**Aim live from the floor:** stand on the dance floor and drag your finger in the box to move the head. **Fine / Normal / Fast** set the speed, and **Next head** moves on. On an iPad with a keyboard or trackpad, the keys and mouse work as they do on the laptop. If the phone locks or loses Wi-Fi during live aim, the heads go dark after 30 s. Press **Reconnect**, and your aims so far are kept.

**Wi-Fi:** the phone and the laptop must be on the **same** network. Venue Wi-Fi often keeps devices apart. The surest way is your own small travel router, or the laptop on the iPhone's Personal Hotspot.

Phones get no updates or phone settings (those stay on the laptop). Anything a phone saves while ShowXpress is open is queued, the same as on the laptop. If ShowXpress asks whether to save when it closes, answer it on the laptop.

## Settings

Press **⚙** at the top right (or the **Settings** tile on Home):

- **Look:** Dark, Light or *Same as this device*. Each computer, phone and iPad keeps its own.
- **Tabs:** drag ☰ or use the arrows to change the tab order, and untick a tab to hide it (from Home too). The order is the same on the laptop, the phone and the iPad. **Reset** brings back the normal order.
- **Google Drive:** whether Google Drive for desktop is installed and signed in, **Open Google Drive** / **Get Google Drive** to sign in or install it, Sync and Import, the My Drive folder if SX Studio can't find it by itself, and the import backups.
- **Phone & iPad:** turn phone access on, pair, unpair.
- **ShowXpress:** open ShowXpress again after queued changes, and open the show folder.
- **Updates:** the version, **Check now**, and whether to check when SX Studio opens.

They're kept in `%APPDATA%\ShowXpress Helper\settings.json` (Mac: `~/AwaazTools/settings.json`). SX Studio can't sign in to Google itself: signing in is done in the Google Drive app.

## Google Drive

**Sync to Google Drive** (⚙ Settings, and Pre-show Check when it's due) copies the show into **Google Drive > AWAAZ > Lighting > *show folder name*** through the Google Drive for desktop app, which uploads it. One way only: new and changed files are copied, nothing is deleted, and a file that is newer on Google Drive is left alone. Close ShowXpress first so the saved show is copied.

**Import from Google Drive** (⚙ Settings) does the opposite: the Google Drive copy replaces the show on this computer. The old show is kept as a backup (newest 3, **Open import backups**), and if any file can't be read nothing is changed.

On the Mac, copy the show from Google Drive into `~/TheLightingController/LightShows` (or write its folder into `~/AwaazTools/show_path.txt`). SYNC FROM WINDOWS is gone; installing this version removes its Desktop shortcut.

## Show folder

SX Studio looks for the show in this order:
1. The folder written in `show_path.txt`:
   - **Windows:** `%APPDATA%\ShowXpress Helper\show_path.txt` (optional; the old `%APPDATA%\AIM MOVERS\show_path.txt` still works)
   - **Mac:** `~/AwaazTools/show_path.txt` (optional)
2. `~/TheLightingController/LightShows/Awaaz Lightshow`
3. The only show in `LightShows` that has a `CENTER SPOT` scene

## Building

The scene and movement editors' tests and the looks tests (`tools/test_scene_edit.ps1`, `tools/test_move_edit.ps1`, `tools/test_looks.ps1`) run before every release build, on Windows PowerShell 5.1 and PowerShell 7. `-Show <show folder>` also checks that every scene or movement of a real show reads back byte for byte (on a temporary copy).

Pushing a tag such as `v1.1.0` makes GitHub Actions build both installers and publish them as a release.
- **Windows:** Inno Setup, `windows/aim_movers.iss`
- **Mac:** `pkgbuild`, `mac/build_pkg.sh`
