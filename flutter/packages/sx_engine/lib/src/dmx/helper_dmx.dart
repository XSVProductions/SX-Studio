import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'dmx_output.dart';
import 'efk_dmx.dart';

/// DMX on the Mac, through the `sxh_dmx` helper the old app ships
/// (the old app's `mac/dmx/main.swift`). Chauvet's Mac driver has to be loaded on a
/// program's main thread, which neither PowerShell nor a Dart isolate can
/// promise, hence a separate small program.
///
/// ShowXpress comes as an Intel download and an Apple Silicon one, each with
/// a driver for that chip only. The helper holds both kinds of code and
/// [open] runs the kind the installed driver is. The old helper was Intel
/// only, so it could not load the Apple Silicon driver.
///
/// The helper speaks `dmx_out.ps1`'s stdin protocol: it keeps its own frame
/// and sends it 40 times a second. [send] passes only the channels that
/// changed, as `b:ch:v`, and a `k` keep-alive when nothing did for a second.
///
/// Checked on an Apple Silicon Mac with both ShowXpress downloads and no
/// interface plugged in: the driver loads and the old "not found" message
/// comes back. Not checked with an interface.
class HelperDmx implements DmxOutput {
  HelperDmx._(this.name, this._proc);

  /// Starts [helper] for the ShowXpress folder [driverDir]. Throws [DmxError]
  /// with the old app's messages (`Start-Live` and `Open-DmxChild`).
  static Future<HelperDmx> open({required String helper, required String driverDir}) async {
    if (driverDir.isEmpty) throw DmxError('ShowXpress was not found in Applications, so its interface driver was not found either.');
    if (!File(helper).existsSync()) throw DmxError('The live aim part of SX Studio is missing - install SX Studio again.');
    final args = [helper, '--dir', driverDir];
    final proc = intelOnly(File(p.join(driverDir, 'efk_hardware.dylib')))
        ? await Process.start('/usr/bin/arch', ['-x86_64', ...args])
        : await Process.start(args.first, args.sublist(1));
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

/// True when the Mac program or library [f] holds Intel code and no Apple
/// Silicon code. False when it can't be read or isn't one.
bool intelOnly(File f) {
  const intel = 0x01000007, arm = 0x0100000C;
  final Uint8List head;
  try {
    final r = f.openSync();
    try {
      head = r.readSync(1024);
    } finally {
      r.closeSync();
    }
  } on FileSystemException {
    return false;
  }
  if (head.length < 8) return false;
  final d = ByteData.sublistView(head);
  final cpus = <int>[];
  switch (d.getUint32(0)) {
    // a file for several chips: a count, then 20 bytes for each
    case 0xCAFEBABE:
      final n = d.getUint32(4);
      for (var at = 8; cpus.length < n && at + 4 <= head.length; at += 20) {
        cpus.add(d.getUint32(at));
      }
    // a file for one 64-bit chip
    case 0xCFFAEDFE:
      cpus.add(d.getUint32(4, Endian.little));
  }
  return cpus.contains(intel) && !cpus.contains(arm);
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
