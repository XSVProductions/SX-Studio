import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'tabs.dart';
import 'theme_store.dart';
import 'widgets/result_card.dart';

/// The theme this device chose last time, read from the old page's
/// `sxh_theme` (`auto` is the device's own). Dark until someone picks another.
Future<ThemeMode> loadThemeMode() async => switch (await readThemeChoice()) {
  'light' => ThemeMode.light,
  'auto' => ThemeMode.system,
  _ => ThemeMode.dark,
};

/// What every screen shares: the engine client, the tab on show, and the
/// status the app polls from the engine.
class AppState extends ChangeNotifier {
  AppState(this.client, {String tab = 'home', this.themeMode = ThemeMode.dark}) : tab = knownTab(tab) ? tab : 'home' {
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  final SxClient client;
  late final Timer _timer;
  var _polling = false;

  /// Latest status from the engine, or null before the first answer.
  SxStatus? status;

  /// False while the engine isn't answering. The poll keeps trying, so this
  /// goes back to true by itself when the engine returns.
  bool connected = true;

  /// Id of the tab on show.
  String tab;

  /// Tabs with edits that are not saved yet. A screen adds itself while it is
  /// dirty. Screens stay alive when the user switches tabs, so the edits are
  /// still there on the way back. The tab bar marks these tabs.
  final dirtyTabs = <String>{};

  bool get sxOpen => status?.open ?? false;

  /// Goes up each time the queue finished its saves. The show files changed,
  /// so every screen's copy is stale (the old page's `reloadAll`). Screens
  /// follow it with [ShowWatcher].
  int queueRuns = 0;

  /// Goes up each time ShowXpress goes from open to closed (it may have
  /// saved the show on the way out), and when a screen changes files that
  /// other tabs show too. See [showEdited].
  int sxCloses = 0;

  /// A screen just changed show files other tabs also show (a Health Check
  /// fix moves pads and faders). Screens without unsaved edits read again,
  /// the old page's `hlAfter`.
  void showEdited() {
    sxCloses++;
    notifyListeners();
  }

  /// Goes up each time a settings file was imported.
  int imports = 0;

  /// A settings import just replaced the APC40 pages and the Auto Show along
  /// with show files. Those two tabs read again whatever they hold (the old
  /// page's `Q4=null;AU=null`), the rest as after [showEdited].
  void settingsImported() {
    imports++;
    showEdited();
  }

  /// Dark, light, or the same as this device (`ThemeMode.system`). Each
  /// device keeps its own choice, as the old app kept it in the browser.
  ThemeMode themeMode;

  void setThemeMode(ThemeMode mode) {
    if (mode == themeMode) return;
    themeMode = mode;
    notifyListeners();
    unawaited(
      writeThemeChoice(switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'auto',
        ThemeMode.dark => 'dark',
      }),
    );
  }

  /// Shows tab [id]. Hides the last save's result, as the old `setTab` did.
  void go(String id) {
    if (!knownTab(id)) id = 'home';
    if (id == tab && result == null) return;
    tab = id;
    result = null;
    notifyListeners();
  }

  /// The last save's result card, the old page's `#result`, and the tab it
  /// belongs to. [resultSeq] goes up with each new one.
  SaveResult? result;
  String resultTab = '';
  int resultSeq = 0;

  /// Shows [r] under the tab on show (the old `showResult`).
  void showResult(SaveResult r) {
    result = r;
    resultTab = tab;
    resultSeq++;
    notifyListeners();
  }

  /// Hides the result card (Aim Movers switching between Floor and Room).
  void hideResult() {
    if (result == null) return;
    result = null;
    notifyListeners();
  }

  /// The show on disk was replaced (an immediate Google Drive import). Every
  /// screen reads everything again, unsaved edits are dropped, as the old
  /// page's `reloadAll`.
  void reloadAll() {
    queueRuns++;
    notifyListeners();
  }

  /// Scene files made here (One-click Looks), in order. Screens that keep a
  /// list of the show's files add them or read the list again: the old
  /// `SL=null;MLS=null;LB.files.push(...)` after a look was made.
  final madeScenes = <String>[];

  void sceneMade(String file) {
    madeScenes.add(file);
    notifyListeners();
  }

  final _fileRequests = <String, String>{};

  /// Shows [id] and asks its screen to open [file], as the SX Player's
  /// "Edit scene" does. The screen picks it up with [takeFile].
  void openFile(String id, String file) {
    _fileRequests[id] = file;
    tab = id;
    result = null;
    notifyListeners();
  }

  /// The file another screen asked tab [id] to open, once. A screen that
  /// opens files calls this from `didChangeDependencies` after
  /// `AppScope.of(context)`, so it also sees a request made while it is alive.
  String? takeFile(String id) => _fileRequests.remove(id);

  void setDirty(String id, bool dirty) {
    if (dirty ? dirtyTabs.add(id) : dirtyTabs.remove(id)) notifyListeners();
  }

  /// The old page's busy veil text, empty when nothing runs.
  String busy = '';

  void setBusy(String text) {
    if (text == busy) return;
    busy = text;
    notifyListeners();
  }

  /// When the user last asked ShowXpress to close, while it still runs
  /// (the old `sxCloseT`). Cleared once it is closed.
  DateTime? sxCloseAsked;

  /// Fetches the status now, for right after an action that changes it.
  Future<void> refresh() => _poll();

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final was = status, now = await client.status();
      status = now;
      connected = true;
      if (!now.open) sxCloseAsked = null;
      if (was != null) {
        if (was.open && !now.open) sxCloses++;
        final at = now.queue.done?['at'];
        if (at != null && at != was.queue.done?['at']) {
          // the old reloadAll ends in setTab, which hides the result card
          queueRuns++;
          result = null;
        }
      }
    } on ApiException {
      connected = false;
    } finally {
      _polling = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

/// Hands [AppState] to the widgets below. `AppScope.of(context)` rebuilds the
/// caller when the state changes. Use `AppScope.read` in callbacks.
///
/// The shell puts a second one around each tab, with [live] false while the
/// tab is hidden. The widgets of a hidden tab are left alone when the state
/// changes and rebuild once when the tab is shown again (and once when it is
/// hidden). So a click or a status poll costs the tab on show, not every tab
/// opened so far. A widget that must follow the state while its tab is
/// hidden listens to the [AppState] itself.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required this.state, bool live = true, required super.child}) : super(notifier: live ? state : null);

  final AppState state;

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.state;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.state;

  /// [of] where there may be no app (a widget shown on its own in a test).
  static AppState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()?.state;
}

/// Tells a screen which tab it is. The shell puts one around each tab, so
/// the result card shows only under the tab that saved.
class TabScope extends InheritedWidget {
  const TabScope({super.key, required this.id, required super.child});

  final String id;

  /// The tab [context] is in, or null outside the shell.
  static String? of(BuildContext context) => context.getInheritedWidgetOfExactType<TabScope>()?.id;

  @override
  bool updateShouldNotify(TabScope oldWidget) => id != oldWidget.id;
}
