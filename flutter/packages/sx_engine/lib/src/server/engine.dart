import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:sx_api/sx_api.dart';

import '../dmx/dmx_hub.dart';
import '../dmx/dmx_output.dart';
import '../show/find_show.dart';
import '../show/show_env.dart';
import '../dmx/default_dmx.dart';
import '../sx/default_sx_app.dart';
import '../sx/live_hold.dart';
import '../sx/sx_app.dart';
import 'api.dart';
import 'phone.dart';
import 'queue.dart';
import 'routes/routes.dart';

/// The version this build of SX Studio reports, and compares with GitHub's
/// newest release.
const sxStudioVersion = '2.0.0';

/// How to start the engine.
class EngineConfig {
  const EngineConfig({
    this.port = 47321,
    required this.token,
    this.showPath,
    this.webDir,
    this.dmx,
    this.phonePort = 47322,
    this.settingsDir,
    this.appVersion = sxStudioVersion,
  });

  /// Port for the laptop's own UI, on the loopback address. 0 picks a free one.
  final int port;

  /// The laptop UI's secret. Every call on the loopback port must carry it.
  /// It is never accepted on the network port.
  final String token;

  /// Use this show folder instead of looking for one. For development and tests.
  final String? showPath;

  /// The built web UI, served on both ports. Null serves the API only.
  final String? webDir;

  /// Where DMX goes. Null picks this computer's real interface.
  final DmxSpec? dmx;

  /// Network port phones and tablets connect to while phone access is on
  /// (the old relay's port). 0 picks a free one.
  final int phonePort;

  /// SX Studio's settings folder. The app passes the usual one
  /// (`settingsDir` in `find_show.dart`). Null gives the engine a throwaway
  /// folder it deletes when it stops, so a test that forgets this can never
  /// read or change the real settings.
  final String? settingsDir;

  /// SX Studio's version, for the update check.
  final String appVersion;
}

/// The laptop side of SX Studio: the tools, the save queue and the HTTP API.
///
/// The UI never touches show files or lights itself. It asks the engine over
/// HTTP, and so does a phone, which is why both see the same thing.
class Engine {
  Engine(this.config, {SxApp? sx}) : sx = sx ?? defaultSxApp(), dmx = DmxHub(config.dmx ?? defaultDmxSpec()) {
    queue = SaveQueue(sxOpen: () => this.sx.running, busy: () => dmx.busy || liveHold.on, reopenSx: this.sx.launch);
    registerRoutes(this);
  }

  final EngineConfig config;
  final SxApp sx;
  final api = Api();
  late final SaveQueue queue;

  /// Set while someone aims live or the SX Player starts, so the queue does
  /// not reopen ShowXpress under them. The old server's `$liveHold`.
  final liveHold = LiveHold();

  final _parts = <Type, Object>{};
  final _onStop = <FutureOr<void> Function()>[];

  /// Runs [fn] when the engine stops. For an area's timers and sessions.
  void onStop(FutureOr<void> Function() fn) => _onStop.add(fn);

  /// Shares one area's state with the others (the player, the settings...).
  /// An area calls this from its `register...Routes`.
  void provide<T extends Object>(T part) => _parts[T] = part;

  /// What an area shared with [provide], or null when it isn't there.
  T? find<T extends Object>() => _parts[T] as T?;

  /// Phone access: on or off, the pairing code and the paired phones.
  late final phones = PhoneAccess(settingsFolder);

  /// SX Studio's settings folder.
  late final String settingsFolder = config.settingsDir ?? (_ownSettings = Directory.systemTemp.createTempSync('sx_settings_')).path;

  /// The throwaway settings folder, when the config named none.
  Directory? _ownSettings;

  /// Live output and the player. Only one thing sends DMX at a time.
  final DmxHub dmx;

  HttpServer? _server;
  HttpServer? _phoneServer;
  Timer? _tick;

  /// Why the network listener couldn't start, or ''.
  String phoneError = '';

  /// The show to work on. Throws `ToolError` when there is none.
  ShowEnv show() => ShowEnv(config.showPath ?? findShow(), sxRunning: () => sx.running);

  /// The loopback port the laptop's UI uses.
  int get port => _server!.port;

  /// The network port phones use, or null while phone access is off.
  int? get phonePort => _phoneServer?.port;

  Future<void> start() async {
    _server = await shelf_io.serve(_withWeb((req) => _handle(req, fromPhone: false), fromPhone: false), InternetAddress.loopbackIPv4, config.port);
    if (phones.on) await setPhoneListener(true);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => queue.step());
  }

  /// Starts or stops the network listener for phones. A failure to start is
  /// kept in [phoneError] for the Phone & iPad card.
  Future<void> setPhoneListener(bool on) async {
    if (!on) {
      await _phoneServer?.close(force: true);
      _phoneServer = null;
      return;
    }
    if (_phoneServer != null) return;
    final web = _withWeb((req) => _handle(req, fromPhone: true), fromPhone: true);
    // every call from a phone is "the last phone", as the old relay noted it
    FutureOr<Response> handler(Request req) {
      phones.saw(_ip(req));
      return web(req);
    }

    try {
      // IPv6 and IPv4 together where the computer has both
      _phoneServer = await shelf_io.serve(handler, InternetAddress.anyIPv6, config.phonePort);
      phoneError = '';
    } on SocketException {
      try {
        _phoneServer = await shelf_io.serve(handler, InternetAddress.anyIPv4, config.phonePort);
        phoneError = '';
      } on SocketException catch (e) {
        phoneError = "Port ${config.phonePort} can't be used (${e.osError?.message ?? e.message})";
      }
    }
  }

  Future<void> stop() async {
    _tick?.cancel();
    for (final fn in _onStop) {
      await fn();
    }
    await dmx.stopAll();
    await _phoneServer?.close(force: true);
    await _server?.close(force: true);
    if (_ownSettings case final own? when own.existsSync()) own.deleteSync(recursive: true);
  }

  /// Serves the built web UI next to the API, when there is one. The UI's
  /// files need no key: a phone has to load them to show the pairing screen.
  /// A phone's page carries its key back when it showed the current one.
  Handler _withWeb(Handler api, {required bool fromPhone}) {
    final web = config.webDir;
    if (web == null || !Directory(web).existsSync()) return api;
    final files = createStaticHandler(web, defaultDocument: 'index.html');
    return (req) {
      final path = req.url.path;
      if (path.startsWith('api/') || path == _brandPath) return api(req);
      if (fromPhone && (path == '' || path == 'index.html') && req.method == 'GET') {
        return phones.on ? phonePage(web, phones, req) : _text(403, 'Phone access is turned off in SX Studio.');
      }
      return files(req);
    };
  }

  static const _pairPath = '/api/phone/pair';
  static const _brandPath = 'brand.png';

  /// `/brand.png`: the user's own banner image for Home, when they put one in
  /// the settings folder. Needs no key, as before. 404 when there is none,
  /// and the UI shows its built-in one.
  Response _brand() {
    final folders = [settingsFolder, if (config.settingsDir != null) '$homeDir/AwaazTools'];
    for (final folder in folders) {
      final f = File('$folder/$_brandPath');
      if (f.existsSync()) return Response.ok(f.readAsBytesSync(), headers: {'content-type': 'image/png', 'cache-control': 'no-store'});
    }
    return Response.notFound('no brand image');
  }

  Future<Response> _handle(Request req, {required bool fromPhone}) async {
    final path = '/${req.url.path}';
    final route = api.find(path);
    if (fromPhone) {
      // The phones' key only. The laptop's token means nothing on this port.
      final no = phones.refuse(req, path: path, laptopOnly: route != null && !route.phone);
      if (no != null) return _json({'ok': false, 'error': no, 'out': ''}, 403);
    }
    if (req.url.path == _brandPath) return _brand();
    if (path == _pairPath) return _pair(req, fromPhone: fromPhone);
    if (route == null) return _json({'ok': false, 'error': 'Unknown action.', 'out': ''}, 404);
    final key = req.headers['x-sx-token'] ?? '';
    if (!fromPhone && !sameSecret(key.isEmpty ? req.url.queryParameters['t'] ?? '' : key, config.token)) {
      return _json({'ok': false, 'error': 'Not paired with this laptop.', 'out': ''}, 401);
    }
    if (req.method != route.method) return _json({'ok': false, 'error': 'Wrong method.', 'out': ''}, 405);
    if (fromPhone && (req.contentLength ?? 0) > 4000000) return _json({'ok': false, 'error': 'Too big.', 'out': ''}, 413);

    var body = const <String, Object?>{};
    if (req.method == 'POST') {
      final text = await req.readAsString();
      if (text.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is! Map) throw const FormatException();
          body = decoded.cast<String, Object?>();
        } on FormatException {
          return _json({'ok': false, 'error': 'The request is not valid JSON.', 'out': ''}, 400);
        }
      }
    }
    if (route.queue != null && sx.running) return _json(queue.add(route, body));
    return _json(await runRoute(route, ApiRequest(body: body, query: req.url.queryParameters, fromPhone: fromPhone)));
  }

  /// `/api/phone/pair`: the one call a phone may make without a key.
  Future<Response> _pair(Request req, {required bool fromPhone}) async {
    if (req.method != 'POST') return _json({'ok': false, 'error': 'Wrong method.', 'out': ''}, 405);
    if (!fromPhone) return _json({'ok': false, 'error': 'Pairing is for phones.'});
    if ((req.contentLength ?? 0) > 10000) return _json({'ok': false, 'error': 'Too big.', 'out': ''}, 413);
    var code = '';
    try {
      final j = jsonDecode(await req.readAsString());
      if (j is Map) code = '${j['pin'] ?? ''}';
    } on FormatException {
      code = '';
    }
    try {
      final key = phones.pair(code);
      return _json({'ok': true, 'key': key}, 200, phones.cookieHeader);
    } on PairRefused catch (e) {
      // a wrong code answers slowly, so guessing takes longer
      if (e.wrongCode) await Future<void>.delayed(const Duration(milliseconds: 600));
      return _json({'ok': false, 'error': e.message});
    }
  }

  String _ip(Request req) {
    final info = req.context['shelf.io.connection_info'];
    if (info is! HttpConnectionInfo) return '';
    final a = info.remoteAddress;
    // an IPv4 phone on the IPv6 listener shows as ::ffff:a.b.c.d
    return a.address.startsWith('::ffff:') ? a.address.substring(7) : a.address;
  }

  Response _json(Object? value, [int status = 200, Map<String, String> more = const {}]) =>
      Response(status, body: jsonEncode(value), headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...more});

  Response _text(int status, String text) => Response(status, body: text, headers: {'content-type': 'text/plain', 'cache-control': 'no-store'});
}

/// Runs a route's handler and turns whatever happens into a JSON object.
Future<Json> runRoute(ApiRoute route, ApiRequest req) async {
  try {
    final r = await route.handler(req);
    if (r is String) return ToolResult(ok: true, out: r).toJson();
    // Through JSON text, so wire types become plain maps.
    final plain = jsonDecode(jsonEncode(r ?? const {'ok': true}));
    return plain is Map ? plain.cast<String, Object?>() : {'ok': true, 'value': plain};
  } on ToolError catch (e) {
    return ToolResult.failed(e.message).toJson();
  } catch (e, st) {
    stderr.writeln('${route.path} failed: $e\n$st');
    return ToolResult(ok: false, error: 'Something went wrong - see Full details.', out: '$e\n$st').toJson();
  }
}
