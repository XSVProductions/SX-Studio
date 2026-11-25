// SX-Studio-Setup.exe: installs the newest SX Studio on a Windows laptop.
//
// Build (from packages/sx_release):
//   dart compile exe bin/setup_stub.dart -o ../../build/setup/SX-Studio-Setup.exe
//
// It finds the newest release on GitHub, checks its release.json against the
// key built in (lib/src/release_key.dart), downloads the installer that file
// names, checks its size and SHA-256 and opens it. Nothing else is run and
// nothing about the computer is sent. It knows no app version, so it is built
// and signed once.
import 'dart:io';

import 'package:sx_release/sx_release.dart';

Future<void> main(List<String> args) async {
  stdout.writeln('SX Studio setup');
  stdout.writeln('');
  final temp = Directory.systemTemp.createTempSync('sx_setup_');
  try {
    final got = await fetchSetup(temp: temp, say: stdout.writeln);
    stdout.writeln('Opening the installer for SX Studio ${got.manifest.version}...');
    final p = await Process.start(got.installer.path, got.asset.setupArgs, mode: ProcessStartMode.inheritStdio);
    final code = await p.exitCode;
    if (code != 0) {
      await _fail('The installer stopped before it was done (code $code).');
      return;
    }
    stdout.writeln('Done. SX Studio is installed.');
    await Future<void>.delayed(const Duration(seconds: 3));
  } on ReleaseError catch (e) {
    await _fail(e.message);
  } on ProcessException catch (e) {
    await _fail('The installer did not open: ${e.message}');
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // the temp folder clears itself
    }
  }
}

Future<void> _fail(String why) async {
  exitCode = 1;
  stdout.writeln('');
  stdout.writeln(why);
  stdout.writeln('');
  stdout.write('Press Enter to close.');
  try {
    stdin.readLineSync();
  } on StdinException {
    // no keyboard: just close
  }
}
