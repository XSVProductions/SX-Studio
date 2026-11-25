import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../tabs.dart';

/// The settings the whole app shares: the tab layout (order, hidden tabs,
/// names) and whether this is a phone. The tab bar and Home read it, the
/// Settings screen changes it.
///
/// One per [AppState], made on first use by [SettingsModel.of].
class SettingsModel extends ChangeNotifier {
  SettingsModel(this.client);

  final SxClient client;

  static final _byApp = Expando<SettingsModel>();

  /// The model for [app], loading the settings the first time.
  static SettingsModel of(AppState app) => _byApp[app] ??= (SettingsModel(app.client)..load());

  /// The settings, or the defaults until the first answer.
  SxSettings settings = const SxSettings();

  /// SX Studio's version, '' until loaded.
  String ver = '';

  /// This copy of the app runs on a phone or tablet. The laptop-only parts
  /// of Settings are hidden then.
  bool phone = false;

  bool loaded = false;
  String error = '';

  /// What GitHub said about a newer version, or null before the answer.
  /// Asked once when the app opens, on the laptop, unless the user turned
  /// that off. Home's version line and the header's Update button read it.
  UpdateInfo? update;
  var _askedUpdate = false;

  Future<void> load() async {
    try {
      final info = await client.settings();
      settings = info.settings;
      ver = info.ver;
      phone = info.phone;
      loaded = true;
      error = '';
      if (!phone && settings.autoUpd && !_askedUpdate) {
        _askedUpdate = true;
        unawaited(_checkUpdate());
      }
    } on ApiException catch (e) {
      error = e.message;
    }
    notifyListeners();
  }

  Future<void> _checkUpdate() async {
    try {
      update = await client.update();
      notifyListeners();
    } on ApiException {
      return;
    }
  }

  /// Saves [change]. Answers '' or the reason it wasn't saved.
  Future<String> save(SettingsChange change) async {
    try {
      settings = await client.settingsSet(change);
      notifyListeners();
      return '';
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// The tab's name: the user's own, or its usual one.
  String nameOf(TabDef t) => settings.tabNames[t.id] ?? t.name;

  bool hidden(TabDef t) => settings.tabHidden.contains(t.id);

  /// Every tab in the user's order, grouped the way the menus are: by
  /// [TabGroup], keeping the saved order inside each group. Hidden tabs are
  /// included; leave them out with [hidden].
  List<TabDef> ordered() {
    final rank = {for (final (i, id) in settings.tabOrder.indexed) id: i};
    final list = [...tabs];
    int r(TabDef t) => rank[t.id] ?? (settings.tabOrder.length + tabs.indexOf(t));
    list.sort((a, b) => a.group.index != b.group.index ? a.group.index - b.group.index : r(a) - r(b));
    return list;
  }

  /// The tabs to show in the tab bar and on Home, in order.
  List<TabDef> visible() => [
    for (final t in ordered())
      if (!hidden(t)) t,
  ];
}
