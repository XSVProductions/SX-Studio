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
import '../sx/sx_app.dart';
import 'api.dart';
import 'queue.dart';
import 'routes/routes.dart';

/// How to start the engine.
class EngineConfig {
  const EngineConfig({this.port = 47321, required this.token, this.showPath, this.webDir, this.lan = false, this.dmx});

  /// Port to listen on. 0 picks a free one.
  final int port;

  /// The laptop UI's secret. Every API call must carry it (or a paired phone's key).
  final String token;

  /// Use this show folder instead of looking for one. For development and tests.
  final String? showPath;

  /// The built web UI to serve to phones, or null to serve the API only.
  final String? webDir;

  /// Listen on the network, not just this computer, so phones can connect.
  final bool lan;

  /// Where DMX goes. Null picks this computer's real interface.
  final DmxSpec? dmx;
}

/// The laptop side of SX Studio: the tools, the save queue and the HTTP API.
///
/// The UI never touches show files or lights itself. It asks the engine over
/// HTTP, and so does a phone, which is why both see the same thing.
class Engine {
  Engine(this.config, {SxApp? sx}) : sx = sx ?? defaultSxApp(), dmx = DmxHub(config.dmx ?? defaultDmxSpec()) {
    queue = SaveQueue(sxOpen: () => this.sx.running, busy: () => dmx.busy, reopenSx: this.sx.launch);
    registerRoutes(this);
  }

  final EngineConfig config;
  final SxApp sx;
  final api = Api();
  late final SaveQueue queue;

  final _parts = <Type, Object>{};

  /// Shares one area's state with the others (the player, the settings...).
  /// An area calls this from its `register...Routes`.
  void provide<T extends Object>(T part) => _parts[T] = part;

  /// What an area shared with [provide], or null when it isn't there.
  T? find<T extends Object>() => _parts[T] as T?;

  /// Keys of paired phones. A request carrying one is a phone request.
  final phoneKeys = <String>{};

  /// Live output and the player. Only one thing sends DMX at a time.
  final DmxHub dmx;

  HttpServer? _server;
  Timer? _tick;

  /// The show to work on. Throws `ToolError` when there is none.
  ShowEnv show() => ShowEnv(config.showPath ?? findShow(), sxRunning: () => sx.running);

  /// The port the engine is listening on.
  int get port => _server!.port;

  Future<void> start() async {
    var handler = const Pipeline().addHandler(_handle);
    final web = config.webDir;
    if (web != null && Directory(web).existsSync()) {
      final files = createStaticHandler(web, defaultDocument: 'index.html');
      final apiHandler = handler;
      handler = (req) => req.url.path.startsWith('api/') ? apiHandler(req) : files(req);
    }
    _server = await shelf_io.serve(handler, config.lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, config.port);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => queue.step());
  }

  Future<void> stop() async {
    _tick?.cancel();
    await dmx.stopAll();
    await _server?.close(force: true);
  }

  Future<Response> _handle(Request req) async {
    final path = '/${req.url.path}';
    final route = api.find(path);
    if (route == null) return _json({'ok': false, 'error': 'Unknown action.', 'out': ''}, 404);
    final key = req.headers['x-sx-token'] ?? req.url.queryParameters['t'] ?? '';
    final fromPhone = key != config.token;
    if (fromPhone && !phoneKeys.contains(key)) return _json({'ok': false, 'error': 'Not paired with this laptop.', 'out': ''}, 401);
    if (fromPhone && !route.phone) return _json({'ok': false, 'error': 'Only on the laptop.', 'out': ''}, 403);
    if (req.method != route.method) return _json({'ok': false, 'error': 'Wrong method.', 'out': ''}, 405);

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

  Response _json(Object? value, [int status = 200]) =>
      Response(status, body: jsonEncode(value), headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'});
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
