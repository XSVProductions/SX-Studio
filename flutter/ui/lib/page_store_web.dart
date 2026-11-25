import 'dart:js_interop';

import 'page_store.dart';

// In a browser the settings live in local storage under the old page's own
// keys, not shared_preferences' `flutter.` ones.

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
}

@JS('window.localStorage')
external _Storage get _storage;

final class _Local implements PageStore {
  @override
  String? get(String key) {
    try {
      return _storage.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void set(String key, String value) {
    try {
      _storage.setItem(key, value);
    } on Object {
      // private browsing without storage: the setting is back to its default next time
    }
  }
}

/// The browser's store.
Future<PageStore> open() async => _Local();
