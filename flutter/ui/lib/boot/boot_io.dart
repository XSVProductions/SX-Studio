import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';

/// Starts the engine on its own isolate, so a slow file tool never holds up
/// the window, and connects to it over the loopback address.
///
/// `SX_SHOW` points the engine at a show folder (development). `SX_PORT`
/// picks the port, otherwise any free one is used.
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
      settingsDir: settingsDir,
    ),
  ));
  final port = await ready.first as int;
  return SxClient(Uri.parse('http://127.0.0.1:$port'), token: token);
}

Future<void> _engineMain((SendPort, EngineConfig) args) async {
  final engine = Engine(args.$2);
  await engine.start();
  args.$1.send(engine.port);
}
