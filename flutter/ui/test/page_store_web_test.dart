@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/page_store.dart';

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('window.localStorage')
external _Storage get _storage;

void main() {
  test('A phone reads and keeps its settings under the old page keys', () async {
    _storage.setItem('sxh_lvspd', '2.5');
    final s = await openPageStore();
    expect(s.get('sxh_lvspd'), '2.5');
    s.set('sxh_mvlite', 'Scene 1.scex');
    expect(_storage.getItem('sxh_mvlite'), 'Scene 1.scex');
    expect(_storage.getItem('flutter.sxh_mvlite'), isNull);
    _storage.removeItem('sxh_lvspd');
    _storage.removeItem('sxh_mvlite');
  });
}
