import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sx_api/sx_api.dart';

import '../app_state.dart';
import '../screens/pair/pair_screen.dart';
import '../theme.dart';

// A phone or tablet: the page came from the laptop's engine, so the API is at
// the same address. As in the old page, the key is kept in three places so a
// paired phone stays paired: local storage, a ten-year cookie the laptop
// sets, and the page address (`/?k=...`), so a Home Screen icon, which has
// its own storage on iOS, carries it too. The laptop puts the key in the page
// itself when the phone showed the current one in its cookie or address.

const _storeName = 'sxh_phone_key';

/// What the laptop puts in `index.html` (`<meta name="sx-phone-key">`) when
/// it has no key for this page. The engine's `phoneKeyMark`.
const _keyMark = '__PHONEKEY__';

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

extension type _Meta._(JSObject _) implements JSObject {
  external String get content;
}

@JS('window.localStorage')
external _Storage get _storage;

@JS('document.querySelector')
external _Meta? _querySelector(String selectors);

@JS('window.location.href')
external String get _href;

@JS('window.history.replaceState')
external void _replaceState(JSAny? data, String title, String url);

@JS('window.location.reload')
external void _reload();

@JS('window.addEventListener')
external void _addEventListener(String type, JSFunction listener);

@JS('navigator.sendBeacon')
external bool _sendBeacon(String url, String data);

String _stored() {
  try {
    return _storage.getItem(_storeName) ?? '';
  } on Object {
    return '';
  }
}

/// The key the laptop put in the page, or ''. The old `__PHONEKEY__`.
String _pageKey() {
  try {
    final k = _querySelector('meta[name="sx-phone-key"]')?.content ?? '';
    return k == _keyMark ? '' : k;
  } on Object {
    return '';
  }
}

/// Sets or drops `k` in the page address, leaving the rest as it is.
void _setAddressKey(String key) {
  try {
    final u = Uri.parse(_href);
    final q = Map.of(u.queryParameters);
    if ((q['k'] ?? '') == key) return;
    key.isEmpty ? q.remove('k') : q['k'] = key;
    final search = q.isEmpty ? '' : '?${Uri(queryParameters: q).query}';
    _replaceState(null, '', '${u.path}$search${u.hasFragment ? '#${u.fragment}' : ''}');
  } on Object {
    // an address that can't be changed: the key is still in storage
  }
}

/// `phKeep`: the key into local storage and the page address.
void _keep(String key) {
  try {
    _storage.setItem(_storeName, key);
  } on Object {
    // private browsing without storage
  }
  _setAddressKey(key);
}

/// The forgetting half of `phUnpaired`: out of storage and the address.
void _forget() {
  try {
    _storage.removeItem(_storeName);
  } on Object {
    // nothing kept
  }
  _setAddressKey('');
}

/// A refusal that means the phone's key is no good any more. "Phone access
/// is turned off" keeps the key: the phone works again when it is on.
bool _keyRefused(int status, String error) => (status == 401 || status == 403) && !error.contains('turned off') && error != 'Only on the computer.';

/// Sends every call on. Notes when this page has live output running, for
/// the stop on leaving. When the laptop says this phone isn't paired any
/// more (unpaired on the laptop, or phone access turned off), starts over
/// at the pairing screen, as the old page's `phUnpaired` did.
class _PhoneClient extends http.BaseClient {
  final _inner = http.Client();

  /// Live aim or an editor's preview is sending DMX from this page. The old
  /// page's `LV||CP||SEP||MVP||LKP`.
  var live = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    switch (request.url.path) {
      case '/api/live/start':
        live = true;
      case '/api/live/stop' || '/api/live/save':
        live = false;
    }
    final r = await _inner.send(request);
    if ((r.statusCode != 401 && r.statusCode != 403) || request.headers['X-SX-Token']?.isNotEmpty != true) return r;
    final bytes = await r.stream.toBytes();
    var error = '';
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is Map) error = '${j['error'] ?? ''}';
    } on FormatException {
      error = '';
    }
    if (_keyRefused(r.statusCode, error)) _forget();
    if (_keyRefused(r.statusCode, error) || error.contains('turned off')) _reload();
    return http.StreamedResponse(Stream.value(bytes), r.statusCode, headers: r.headers, request: request, reasonPhrase: r.reasonPhrase);
  }
}

Future<SxClient> boot() async {
  final here = Uri.base;
  // T=ck||uk||ls: the laptop only fills the page's key with the current
  // one, so it wins over an old one
  final fromPage = _pageKey(), fromAddress = here.queryParameters['k'] ?? '';
  final key = fromPage.isNotEmpty ? fromPage : (fromAddress.isNotEmpty ? fromAddress : _stored());
  if (key.isNotEmpty) _keep(key);

  final calls = _PhoneClient();
  final client = SxClient(
    Uri(scheme: here.scheme, host: here.host, port: here.port),
    token: key,
    client: calls,
  );
  // Leaving the page while live output runs stops it at once, not after
  // the 30 second timeout. The old page sent this on beforeunload, and on
  // pagehide for a phone (iOS often gives only that).
  void stopLive() {
    if (calls.live) _sendBeacon('/api/live/stop?t=${Uri.encodeQueryComponent(client.token)}', '{}');
  }

  _addEventListener('beforeunload', stopLive.toJS);
  _addEventListener('pagehide', stopLive.toJS);

  var off = false;
  if (key.isNotEmpty) {
    final (:works, :turnedOff) = await _keyWorks(SxClient(client.base, token: key));
    if (works) return client;
    off = turnedOff;
  }

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
        off: off,
      ),
    ),
  );
  client.token = await paired.future;
  _keep(client.token);
  return client;
}

/// [works] is false when the laptop refuses the key, and [turnedOff] says
/// it refused because phone access is turned off. Asked with a plain client, so a
/// refused key shows the pairing screen without a reload. A key that is no
/// good any more is forgotten; with phone access turned off it is kept. A
/// laptop that can't be reached right now is the app's "trying again"
/// strip, not a pairing problem.
Future<({bool works, bool turnedOff})> _keyWorks(SxClient client) async {
  try {
    await client.settings();
    return (works: true, turnedOff: false);
  } on ApiException catch (e) {
    final status = e.status ?? 0;
    if (_keyRefused(status, e.message)) _forget();
    return (works: status != 401 && status != 403, turnedOff: e.message.contains('turned off'));
  }
}

/// Nothing to stop: the engine is the laptop, and it keeps running.
Future<void> shutdown() async {}
