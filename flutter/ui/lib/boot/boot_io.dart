import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';

SendPort? _engine;

/// Starts the engine on its own isolate, so a slow file tool never holds up
/// the window, and connects to it over the loopback address.
///
/// `SX_SHOW` points the engine at a show folder (development). `SX_PORT`
/// picks the port, otherwise any free one is used. `SX_WEB` is the web build
/// phones load, otherwise the `web` folder the installer puts next to the app.
Future<SxClient> boot() async {
  final rnd = Random.secure();
  final token = [for (var i = 0; i < 24; i++) rnd.nextInt(16).toRadixString(16)].join();
  final ready = ReceivePort();
  await Isolate.spawn(_engineMain, (
    ready.sendPort,
    EngineConfig(
      port: int.tryParse(Platform.environment['SX_PORT'] ?? '') ?? 0,
      token: token,
      showPath: Platform.environment['SX_SHOW'],
      webDir: Platform.environment['SX_WEB'] ?? _bundledWeb(),
      settingsDir: settingsDir,
      appExe: Platform.resolvedExecutable,
    ),
  ));
  final (port, engine) = await ready.first as (int, SendPort);
  _engine = engine;
  return SxClient(Uri.parse('http://127.0.0.1:$port'), token: token);
}

/// The web build shipped with the app: `web` next to the program on Windows
/// and Linux, `Contents/Resources/web` in the Mac app.
String? _bundledWeb() {
  final exe = File(Platform.resolvedExecutable).parent.path;
  for (final dir in ['$exe/web', '$exe/../Resources/web']) {
    if (File('$dir/index.html').existsSync()) return dir;
  }
  return null;
}

/// Asks the engine to stop and waits for it, but never long: the window is
/// closing.
Future<void> shutdown() async {
  final engine = _engine;
  if (engine == null) return;
  _engine = null;
  final done = ReceivePort();
  engine.send(done.sendPort);
  await done.first.timeout(const Duration(seconds: 3), onTimeout: () => null);
  done.close();
}

Future<void> _engineMain((SendPort, EngineConfig) args) async {
  final engine = Engine(args.$2);
  await engine.start();
  final stop = ReceivePort();
  args.$1.send((engine.port, stop.sendPort));
  final done = await stop.first as SendPort;
  await engine.stop();
  done.send(null);
}
