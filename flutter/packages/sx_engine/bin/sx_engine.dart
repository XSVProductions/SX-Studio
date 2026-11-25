import 'dart:io';

import 'package:args/args.dart';
import 'package:sx_engine/sx_engine.dart';

/// Runs the engine on its own, without the desktop window. For development,
/// and for trying the web UI against a show folder:
///
///   dart run sx_engine --show "/path/to/show" --web ../../ui/build/web --token dev
Future<void> main(List<String> argv) async {
  final args =
      (ArgParser()
            ..addOption('show', help: 'Show folder to use instead of looking for one')
            ..addOption('port', defaultsTo: '47321')
            ..addOption('token', defaultsTo: 'dev', help: 'Secret the UI must send')
            ..addOption('web', help: 'Built web UI to serve')
            ..addOption('dmx-log', help: 'No hardware: write the DMX frame to this file')
            ..addFlag('lan', help: 'Listen on the network so phones can connect'))
          .parse(argv);
  final engine = Engine(
    EngineConfig(
      port: int.parse(args.option('port')!),
      token: args.option('token')!,
      showPath: args.option('show'),
      webDir: args.option('web'),
      lan: args.flag('lan'),
      dmx: FakeDmxSpec(args.option('dmx-log')),
    ),
  );
  await engine.start();
  stdout.writeln('SX Studio engine on http://127.0.0.1:${engine.port}');
}
