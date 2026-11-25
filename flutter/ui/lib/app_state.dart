import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';

const _themeKey = 'theme';

/// The theme this device chose last time. Dark until someone picks another.
Future<ThemeMode> loadThemeMode() async => ThemeMode.values.asNameMap()[(await SharedPreferences.getInstance()).getString(_themeKey)] ?? ThemeMode.dark;

/// What every screen shares: the engine client, the tab on show, and the
/// status the app polls from the engine.
class AppState extends ChangeNotifier {
  AppState(this.client, {this.tab = 'home', this.themeMode = ThemeMode.dark}) {
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

  /// Dark, light, or the same as this device (`ThemeMode.system`). Each
  /// device keeps its own choice, as the old app kept it in the browser.
  ThemeMode themeMode;

  void setThemeMode(ThemeMode mode) {
    if (mode == themeMode) return;
    themeMode = mode;
    notifyListeners();
    unawaited(SharedPreferences.getInstance().then((p) => p.setString(_themeKey, mode.name)));
  }

  void go(String id) {
    if (id == tab) return;
    tab = id;
    notifyListeners();
  }

  final _fileRequests = <String, String>{};

  /// Shows [id] and asks its screen to open [file], as the SX Player's
  /// "Edit scene" does. The screen picks it up with [takeFile].
  void openFile(String id, String file) {
    _fileRequests[id] = file;
    tab = id;
    notifyListeners();
  }

  /// The file another screen asked tab [id] to open, once. A screen that
  /// opens files calls this from `didChangeDependencies` after
  /// `AppScope.of(context)`, so it also sees a request made while it is alive.
  String? takeFile(String id) => _fileRequests.remove(id);

  void setDirty(String id, bool dirty) {
    if (dirty ? dirtyTabs.add(id) : dirtyTabs.remove(id)) notifyListeners();
  }

  /// Fetches the status now, for right after an action that changes it.
  Future<void> refresh() => _poll();

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final was = status, now = await client.status();
      status = now;
      connected = true;
      if (was != null) {
        if (was.open && !now.open) sxCloses++;
        final at = now.queue.done?['at'];
        if (at != null && at != was.queue.done?['at']) queueRuns++;
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
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
