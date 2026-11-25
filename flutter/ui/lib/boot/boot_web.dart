import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sx_api/sx_api.dart';

import '../app_state.dart';
import '../screens/pair/pair_screen.dart';
import '../theme.dart';

// A phone or tablet: the page came from the laptop's engine, so the API is at
// the same address. The phone's key lives in the browser's local storage
// (the same name the old app used, so a phone paired with it is still known)
// and goes to the laptop in a header, never in the address.

const _storeName = 'sxh_phone_key';

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('window.localStorage')
external _Storage get _storage;

@JS('window.history.replaceState')
external void _replaceState(JSAny? data, String title, String url);

@JS('window.location.reload')
external void _reload();

String _stored() {
  try {
    return _storage.getItem(_storeName) ?? '';
  } on Object {
    return '';
  }
}

void _store(String key) {
  try {
    key.isEmpty ? _storage.removeItem(_storeName) : _storage.setItem(_storeName, key);
  } on Object {
    // private browsing without storage: the phone pairs again next time
  }
}

/// Sends every call on, and when the laptop says this phone isn't paired
/// any more (unpaired on the laptop), forgets the key and starts over at the
/// pairing screen.
class _ForgetOn401 extends http.BaseClient {
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = await _inner.send(request);
    if (r.statusCode == 401 && request.headers['X-SX-Token']?.isNotEmpty == true) {
      _store('');
      _reload();
    }
    return r;
  }
}

Future<SxClient> boot() async {
  final here = Uri.base;
  // A key in the address (an old Home Screen icon, or a link for testing)
  // moves to local storage and leaves the address.
  final fromUrl = here.queryParameters['k'] ?? '';
  if (fromUrl.isNotEmpty) {
    _store(fromUrl);
    final rest = Map.of(here.queryParameters)..remove('k');
    _replaceState(null, '', here.replace(queryParameters: rest.isEmpty ? null : rest).toString());
  }
  final client = SxClient(
    Uri(scheme: here.scheme, host: here.host, port: here.port),
    token: _stored(),
    client: _ForgetOn401(),
  );
  if (client.token.isNotEmpty && await _keyWorks(SxClient(client.base, token: client.token))) return client;

  // The pairing screen comes before the app, so it picks this device's
  // theme itself, the same way main does.
  final mode = ThemeMode.values.asNameMap()[here.queryParameters['theme']] ?? await loadThemeMode();
  Sx.use(
    light: switch (mode) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light,
    },
  );
  final paired = Completer<String>();
  runApp(
    MaterialApp(
      title: 'SX Studio',
      debugShowCheckedModeBanner: false,
      theme: sxTheme(),
      home: PairScreen(
        client: SxClient(client.base, token: ''),
        onPaired: paired.complete,
      ),
    ),
  );
  client.token = await paired.future;
  _store(client.token);
  return client;
}

/// False only when the laptop says the key is unknown. Asked with a plain
/// client, so a stale key shows the pairing screen without a reload. A laptop that can't be
/// reached right now is the app's "trying again" strip, not a pairing problem.
Future<bool> _keyWorks(SxClient client) async {
  try {
    await client.settings();
    return true;
  } on ApiException catch (e) {
    return e.status != 401;
  }
}

/// Nothing to stop: the engine is the laptop, and it keeps running.
Future<void> shutdown() async {}
