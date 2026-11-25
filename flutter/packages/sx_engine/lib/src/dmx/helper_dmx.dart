import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'dmx_output.dart';
import 'efk_dmx.dart';

/// DMX on the Mac, through the `sxh_dmx` helper the old app ships
/// (`repo/mac/dmx/main.swift`). Chauvet's Mac driver is Intel only and has to
/// be loaded on a program's main thread, which neither PowerShell nor a Dart
/// isolate can promise, hence a separate small program.
///
/// The helper speaks `dmx_out.ps1`'s stdin protocol: it keeps its own frame
/// and sends it 40 times a second. [send] passes only the channels that
/// changed, as `b:ch:v`, and a `k` keep-alive when nothing did for a second.
///
/// Not run on a Mac: written from the old source on Linux.
class HelperDmx implements DmxOutput {
  HelperDmx._(this.name, this._proc);

  /// Starts [helper] for the ShowXpress folder [driverDir]. Throws [DmxError]
  /// with the old app's messages (`Start-Live` and `Open-DmxChild`).
  static Future<HelperDmx> open({required String helper, required String driverDir}) async {
    if (driverDir.isEmpty) throw DmxError('ShowXpress was not found in Applications, so its interface driver was not found either.');
    if (!File(helper).existsSync()) throw DmxError('The live aim part of SX Studio is missing - install SX Studio again.');
    final proc = await Process.start(helper, ['--dir', driverDir]);
    final err = proc.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(proc.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final String line;
    try {
      line = await lines.moveNext().timeout(const Duration(seconds: 20)) ? lines.current : '';
    } on TimeoutException {
      proc.kill();
      throw DmxError('The DMX interface did not answer.');
    }
    if (line.startsWith('OK ')) {
      unawaited(_drain(lines));
      return HelperDmx._(line.substring(3), proc);
    }
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => proc.kill() ? -1 : -1);
    if (line == 'ERR none') throw DmxError(dmxNotFound);
    if (line.startsWith('ERR ')) throw DmxError(line.substring(4));
    final first = const LineSplitter().convert(await err).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    throw DmxError("The DMX output didn't start: $first");
  }

  @override
  final String name;
  final Process _proc;
  final _sent = Uint8List(dmxFrameSize);
  var _lastLine = DateTime.now();
  bool _closed = false;

  @override
  void send(Uint8List frame) {
    if (_closed) return;
    final b = StringBuffer();
    for (var i = 0; i < dmxFrameSize; i++) {
      if (frame[i] == _sent[i]) continue;
      _sent[i] = frame[i];
      if (b.isNotEmpty) b.write(' ');
      b.write('b:${i + 1}:${frame[i]}');
    }
    final now = DateTime.now();
    if (b.isEmpty && now.difference(_lastLine) < const Duration(seconds: 1)) return;
    _write(b.isEmpty ? 'k' : b.toString());
    _lastLine = now;
  }

  void _write(String line) {
    try {
      _proc.stdin.writeln(line);
    } on Object {
      // the helper is gone: it puts the lights out by itself
    }
  }

  /// Asks the helper to put the lights out and let go of the interface.
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _write('q');
    unawaited(_proc.stdin.close().catchError((Object _) {}));
    unawaited(_proc.exitCode.timeout(const Duration(seconds: 4), onTimeout: () => _proc.kill() ? -1 : -1));
  }
}

Future<void> _drain(StreamIterator<String> lines) async {
  while (await lines.moveNext()) {}
}

/// Where the helper sits: next to the app's own program, inside the app
/// (`SX Studio.app/Contents/MacOS/sxh_dmx`), as in the old app.
String macHelperPath() => p.join(p.dirname(Platform.resolvedExecutable), 'sxh_dmx');

/// The folder of ShowXpress (`TheLightingController.app`) on the Mac, which
/// is where its driver `efk_hardware.dylib` is. Null when it isn't installed.
///
/// Port of `Find-SxMacApp`: Applications, or a ShowXpress folder in it (the
/// download's layout), then Spotlight. One with the driver next to it wins.
String? findSxMacFolder() {
  final name = RegExp('ShowXpress|LightingController', caseSensitive: false);
  final apps = <String>[];
  List<Directory> dirs(String path) {
    try {
      return Directory(path).listSync(followLinks: false).whereType<Directory>().toList();
    } on FileSystemException {
      return const [];
    }
  }

  for (final r in ['/Applications', p.join(Platform.environment['HOME'] ?? '', 'Applications')]) {
    for (final d in dirs(r)) {
      final n = p.basename(d.path);
      if (!name.hasMatch(n)) continue;
      if (n.toLowerCase().endsWith('.app')) {
        apps.add(d.path);
      } else {
        apps.addAll(dirs(d.path).map((a) => a.path).where((a) => a.toLowerCase().endsWith('.app') && name.hasMatch(p.basename(a))));
      }
    }
  }
  if (apps.isEmpty) {
    try {
      final r = Process.runSync('mdfind', ["kMDItemFSName == 'TheLightingController.app'"]);
      apps.addAll(const LineSplitter().convert('${r.stdout}').where((l) => l.isNotEmpty && !l.startsWith('/Volumes/') && Directory(l).existsSync()));
    } on ProcessException {
      // no Spotlight
    }
  }
  if (apps.isEmpty) return null;
  bool hasDriver(String app) => File(p.join(p.dirname(app), 'efk_hardware.dylib')).existsSync();
  final best = apps.firstWhere(hasDriver, orElse: () => apps.first);
  return p.dirname(best);
}
