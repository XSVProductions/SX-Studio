import 'package:shared_preferences/shared_preferences.dart';

import 'page_store.dart';

// The laptop app has no browser storage. It keeps the settings in its own
// preferences under the old keys.

final class _Prefs implements PageStore {
  _Prefs(this._p);

  final SharedPreferences _p;

  @override
  String? get(String key) => _p.getString(key);

  @override
  void set(String key, String value) => _p.setString(key, value);
}

/// The laptop's store.
Future<PageStore> open() async => _Prefs(await SharedPreferences.getInstance());
