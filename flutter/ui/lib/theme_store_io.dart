import 'package:shared_preferences/shared_preferences.dart';

import 'theme_store.dart';

// The laptop app has no browser storage. It keeps the choice in its own
// preferences under the old key.

Future<String?> read() async => (await SharedPreferences.getInstance()).getString(themeStoreKey);

Future<void> write(String value) async => (await SharedPreferences.getInstance()).setString(themeStoreKey, value);
