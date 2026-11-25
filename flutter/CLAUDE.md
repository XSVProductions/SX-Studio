# SX Studio, Flutter port

A like-for-like port of SX Studio from PowerShell to Dart and Flutter. Same features, same ShowXpress file handling, same wording. No new features.

The old app is the answer key. A piece is done when the old tool and the new one give the same answer and leave the same bytes on disk.

## Layout

```
packages/sx_api      Wire types and the HTTP client. No dart:io, compiles for web.
packages/sx_engine   The laptop side. Show files, tools, DMX, the HTTP API.
ui                   The Flutter app. Talks to the engine only through SxClient.
```

On the laptop the app starts the engine on its own isolate and connects to it on the loopback address. A phone loads the web build from the same engine. Both use the same `/api/...` routes, so a screen is written once.

Around this folder (found by walking up from wherever you work):

```
repo/                 The old app, pristine. Read only. Never edit.
real-show/            The owner's real show folder. Read only. Never copy it into git.
tools/pwsh/pwsh       PowerShell 7 for running the old tools.
scratch/              Throwaway space.
```

## Porting an area

`speed` is the worked example. Read these five files first and copy their shape:

1. `packages/sx_api/lib/src/speed.dart`. Wire types with `fromJson` and `toJson`, and the area's calls as an extension on `SxClient`. `toJson` must produce the old tool's JSON, key for key.
2. `packages/sx_engine/lib/src/tools/speed.dart`. The tool. Plain functions that take a `ShowEnv`. A read returns a wire type. A write returns the text report. Refusals throw `ToolError` with the old message, word for word.
3. `packages/sx_engine/lib/src/server/routes/speed.dart`. Routes. Same paths and same request bodies as the old server (`repo/src/df_aim_gui.ps1`), including its input checks.
4. `packages/sx_engine/test/parity/speed_parity_test.dart`. Old versus new on the real show.
5. `ui/lib/screens/speed/speed_screen.dart`. The screen.

Then add one line each to `sx_api.dart`, `sx_engine.dart`, `routes/routes.dart` and replace your tab's `_todo` in `ui/lib/tabs.dart`.

## Parity tests are the definition of done

`parityTest` runs the old PowerShell tool and your Dart function on the same copy of the real show, then compares the answer and every file in the folder byte for byte.

- Cover every action of the tool, each refusal, and the "nothing to change" path.
- Build situations with `setup:`. Pick real ids and names by reading the show in the test, as the speed test does. Don't hardcode values from the owner's show.
- A timestamp in a file name or in JSON is a legitimate difference. Mask it with `ParityOptions`, as narrowly as you can. Don't mask anything else.
- If old and new disagree because the old tool has a bug, keep the old behavior, make the test pass, and report the bug. Don't fix it silently.
- A tool that can't run under PowerShell on Linux (it calls Windows-only commands) can't be parity tested here. Say so in your report, port by reading, and write plain unit tests for the logic.

Run them from `packages/sx_engine`: `dart test`. They skip themselves when PowerShell, the old source or the show is missing.

Known old-app bugs to fix during the port instead of copying. These are the only allowed differences, and each needs a test that shows the new behavior:

- Tools wrote show files first and their own state file last, with no backup. Write through `writeTextSafely`, state last, and if a later write fails put the earlier files back.
- `Test-Path` without `-LiteralPath` broke show folders with `[` or `]` in the path. Dart has no such problem. Nothing to do.
- Deleting a state file let Google Drive import bring a stale copy back. Write an empty state instead of deleting.

## PowerShell traps

The old tools lean on these. Most parity failures come from one of them. Helpers are in `lib/src/ps_compat.dart`.

- `-eq`, `-ne`, `-like`, `-match`, `-replace`, `-contains` and `switch` ignore case on strings. Use `psEq`, or `RegExp(..., caseSensitive: false)`. The .NET methods (`.StartsWith`, `.Contains`, `[regex]::Matches`) are case sensitive.
- `@{}` keys ignore case and have no order. Use `psMap()`. `[ordered]@{}` keeps order.
- `[int]` and `[Math]::Round` round halves to even. Use `psRound` and `psInt`. `[int]''` and `[int]$null` are 0.
- `/` on two integers gives a fraction. `[int](7/2)` is 4, `[int](5/2)` is 2.
- `Sort-Object` ignores case. Dart's `sort` is not stable. Use `psSorted`.
- `"$x"` of null is `''`. A missing hashtable key is null, not an error.
- A pipeline that yields one item is that item, not a list, unless wrapped in `@( )`. `ConvertTo-Json` then writes a bare value where you expected a list. `JsonRead.list` already accepts both.
- `ConvertTo-Json -Depth N` cuts off deeper levels and writes them as strings. Check the depth.
- `[IO.File]::ReadAllText` drops a byte order mark. `WriteAllText` with `UTF8Encoding($false)` writes none. Use `readText`, `readLines` and `writeTextSafely`, and keep each file's mark and line endings as found.
- .NET `\d` and `\w` match more than ASCII. Dart's match ASCII only. Rarely matters.
- Number to text: `"$d"` of a double uses the shortest form that round trips on PowerShell 7 and 15 digits on Windows PowerShell 5.1. If a tool writes fractions into a file, check both.
- Dates: `(Get-Date).ToString()` and `"$(Get-Date)"` follow the machine's culture.

## Rules for the engine

- Every route that writes or acts is a POST. A GET never changes anything.
- A route a phone must never reach (restart the laptop, force-close ShowXpress, pair a phone, install an update) is registered with `phone: false`.
- A save that edits show files is registered with `queue: Queueable(...)`, using the old server's labels and keys (`$queueable` and `Get-QueueKey` in `df_aim_gui.ps1`).
- Tools are synchronous file work and run on the engine's isolate. Anything that sends DMX on a timer runs on its own isolate, like `LiveDmx`.
- No `dynamic`. Parse JSON with the `JsonRead` readers. Model with classes, records and sealed types.
- A doc comment on each public function and class saying what it is for. Name the old function it ports.

## Rules for the UI

- Screens talk to the engine through `SxClient` only. Never import `sx_engine` or `dart:io` under `ui/lib`, except `boot/boot_io.dart`.
- Use the pieces in `ui/lib/widgets/sx_widgets.dart` (`ScreenBody`, `SxCard`, `SxHeader`, `SaveBar`, `GroupLabel`, `ErrorBox`, `MiniButton`, `Seg`, `runSave`, `showReport`, `sxGutter`) and the colors and text styles in `ui/lib/theme.dart`. If you need a new shared widget, put it in your own screen folder and say so in your report.
- Keep the old app's look. Read your screen's CSS in `repo/src/df_aim_gui.ps1` and copy its sizes, radii, spacing and which color goes where. `FilledButton` is the old `.primary`, `OutlinedButton` the plain `button`, `MiniButton` the `.mini`, `Seg` the `.seg`, `Sx.tint(color)` the tinted boxes and pills.
- The app has the old dark theme and the old light theme, and Settings switches between them. So every color comes from `Sx`, and the `Sx` colors are getters. Never write `const` around one, never keep one in a field or a `static final`, never write a literal `Color(...)` or `Colors.x` (transparent is fine). Read them in `build` or `paint` each time. Screenshot your screen in both themes (`&theme=light`).
- No symbol characters or emoji in text: no check marks, arrows, triangles, warning signs or gears. The fonts don't have them, and a phone on a venue network can't download a fallback font, so they show as empty boxes. Use an `Icon` from Material Icons, which ships with the app.
- Nothing that repaints continuously. No `CircularProgressIndicator`, no pulsing, no shimmer. While loading, show a line of text.
- Keep the old screen's wording, trimmed. No em dashes anywhere, in copy or comments.
- A screen that holds unsaved edits calls `AppScope.read(context).setDirty(tabId, true)` and clears it after saving or undoing.
- A screen that shows show files mixes in `ShowWatcher` (`sx_widgets.dart`) and reloads in `onQueueRan` (always) and `onSxClosed` (unless it holds unsaved edits), as the old page's poll did for that tab.
- To open a file in another tab's editor, call `AppScope.read(context).openFile(tabId, file)`. The editor screen calls `AppScope.of(context).takeFile(tabId)` in `didChangeDependencies` and opens what it gets.
- Works from 380 px wide (a phone) to a laptop window. Test both.
- Test screen logic with `flutter test` and `package:http/testing.dart`'s `MockClient`. Keep tests focused on behavior a user would notice.

## Looking at your work

```
# engine against your own copy of the show (never the original)
cp -r "<workspace>/real-show/Awaaz Lightshow" /tmp/<you>/show
cd packages/sx_engine
dart run bin/sx_engine.dart --show /tmp/<you>/show --port <your port> --token dev --web ../../ui/build/web --dmx-log /tmp/<you>/frame.txt

# web build. One at a time on this machine, so take the lock.
cd ui && flock /tmp/sx-flutter-build.lock flutter build web --release --no-web-resources-cdn

# screenshot a tab
chromium-browser --headless --no-sandbox --hide-scrollbars --window-size=1300,900 --virtual-time-budget=15000 \
  --screenshot=/tmp/<you>/shot.png "http://127.0.0.1:<your port>/?k=dev&tab=<tab id>"
```

Add `&theme=light` for the light theme, and `--window-size=390,844` for a phone.

The old app runs here too, for comparing screens and API answers:

```
<workspace>/tools/pwsh/pwsh -NoProfile -File <workspace>/repo/src/df_aim_gui.ps1 -TestRoot /tmp/<you>/oldshow -Port <port> -PhonePort <port> -NoBrowser
```

It prints nothing useful. The page is at `http://localhost:<port>/?t=<token>`, and the token is in the server's own variables (read the top of `df_aim_gui.ps1` to see where it is kept). In test mode it fakes ShowXpress with a marker file `_sx_open` in the show folder and writes DMX frames to `_dmx_frame.txt`.

## Working alongside other agents

Several agents work at once, each in its own git worktree and branch.

- Edit only the files your brief gives you. The four barrel files listed in `.gitattributes` are the exception: add your lines there.
- Need a change in a file you don't own? Don't make it. Describe it in your report.
- Commit to your branch as you go, with `git add <your paths>`. Never `git add -A`. Never push. Never touch `repo/` or `real-show/`.
- Format with `dart format .` (page width is set to 160 in `analysis_options.yaml`). `dart analyze` and `flutter analyze` must be clean.
- The machine has 4 cores and 15 GB. Don't run builds in parallel, and don't start a build when a test run will answer the question.
