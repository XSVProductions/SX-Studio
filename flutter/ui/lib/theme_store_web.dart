import 'dart:js_interop';

import 'theme_store.dart';

// In a browser the choice lives in local storage under the old page's own key
// (the page comes from the same address), so a phone keeps the theme it had.

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

@JS('window.localStorage')
external _Storage get _storage;

Future<String?> read() async {
  try {
    return _storage.getItem(themeStoreKey);
  } on Object {
    return null;
  }
}

Future<void> write(String value) async {
  try {
    _storage.setItem(themeStoreKey, value);
  } on Object {
    // private browsing without storage: the theme is back to dark next time
  }
}
