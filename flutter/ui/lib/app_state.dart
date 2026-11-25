import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sx_api/sx_api.dart';

/// What every screen shares: the engine client, the tab on show, and the
/// status the app polls from the engine.
class AppState extends ChangeNotifier {
  AppState(this.client, {this.tab = 'home'}) {
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

  void go(String id) {
    if (id == tab) return;
    tab = id;
    notifyListeners();
  }

  void setDirty(String id, bool dirty) {
    if (dirty ? dirtyTabs.add(id) : dirtyTabs.remove(id)) notifyListeners();
  }

  /// Fetches the status now, for right after an action that changes it.
  Future<void> refresh() => _poll();

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      status = await client.status();
      connected = true;
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
