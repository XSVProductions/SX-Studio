import 'dart:io';

import 'package:args/args.dart';
import 'package:sx_engine/sx_engine.dart';

/// Runs the engine on its own, without the desktop window. For development,
/// and for trying the web UI against a show folder:
///
///   dart run sx_engine --show "/path/to/show" --web ../../ui/build/web --token dev --settings /tmp/me/settings
///
/// Phone access follows the Settings screen (saved in the settings folder).
Future<void> main(List<String> argv) async {
  final args =
      (ArgParser()
            ..addOption('show', help: 'Show folder to use instead of looking for one')
            ..addOption('port', defaultsTo: '47321')
            ..addOption('token', defaultsTo: 'dev', help: 'Secret the UI must send')
            ..addOption('web', help: 'Built web UI to serve')
            ..addOption('dmx-log', help: 'No hardware: write the DMX frame to this file')
            ..addOption('phone-port', defaultsTo: '47322', help: 'Network port for phones, used while phone access is on')
            ..addOption('settings', help: 'Settings folder to use instead of the usual one')
            ..addOption('app-version', defaultsTo: sxStudioVersion, help: 'Version to report and compare with GitHub'))
          .parse(argv);
  final engine = Engine(
    EngineConfig(
      port: int.parse(args.option('port')!),
      token: args.option('token')!,
      showPath: args.option('show'),
      webDir: args.option('web'),
      phonePort: int.parse(args.option('phone-port')!),
      settingsDir: args.option('settings') ?? settingsDir,
      appVersion: args.option('app-version')!,
      dmx: FakeDmxSpec(args.option('dmx-log')),
    ),
  );
  await engine.start();
  stdout.writeln('SX Studio engine on http://127.0.0.1:${engine.port}');
  if (engine.phonePort != null) stdout.writeln('Phones connect on port ${engine.phonePort}');
}
