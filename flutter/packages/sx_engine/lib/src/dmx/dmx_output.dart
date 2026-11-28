import 'dart:io';
import 'dart:typed_data';

import 'artnet.dart';
import 'enttec_pro.dart';
import 'helper_dmx.dart';

/// DMX channels in one frame: 16 universes of 512.
const dmxFrameSize = 512 * 16;

/// The DMX output could not be opened. [message] is for the user.
class DmxError implements Exception {
  DmxError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Something that puts DMX frames on the wire. Only one program can hold the
/// USB interface, so ShowXpress must be closed while one of these is open.
///
/// Calls must come from one isolate, the one that opened it.
abstract interface class DmxOutput {
  /// The interface's name, shown to the user.
  String get name;

  /// Sends a whole frame of [dmxFrameSize] bytes. Byte 0 is channel 1.
  void send(Uint8List frame);

  /// Lets go of the interface. Completes when it is free for the next
  /// program. Doesn't put the lights out first: callers do that themselves.
  Future<void> close();
}

/// Which output to open. A plain value, so it can be handed to the isolate
/// that does the sending.
sealed class DmxSpec {
  const DmxSpec();
}

/// No hardware. With [logPath], the latest frame is written there as
/// `channel=value` lines for the channels above 0 (universe 1 only), which is
/// what tests read.
class FakeDmxSpec extends DmxSpec {
  const FakeDmxSpec([this.logPath]);

  final String? logPath;
}

/// Chauvet's own driver (`efk_hardware`) from the ShowXpress install in
/// [driverDir], driving the D512S USB interface. The driver runs in a helper
/// program started for each open ([HelperDmx]). On the Mac [driverDir] is ''
/// when ShowXpress wasn't found.
class EfkDmxSpec extends DmxSpec {
  const EfkDmxSpec(this.driverDir);

  final String driverDir;
}

/// An Enttec DMX USB Pro (or a box that speaks its protocol) on serial port
/// [port], '' to find it. Universe 1 only. See `enttec_pro.dart`.
class EnttecProSpec extends DmxSpec {
  const EnttecProSpec([this.port = '']);

  final String port;
}

/// Art-Net to [host] ('' = broadcast): universes 1 to [count] go to
/// port-addresses [first] onward. See `artnet.dart`.
class ArtNetSpec extends DmxSpec {
  const ArtNetSpec({this.host = '', this.first = 0, this.count = 1, this.port = artNetPort});

  final String host;
  final int first, count;

  /// The UDP port. Always 6454 except in tests.
  final int port;
}

/// Several outputs at once, every frame to each (the Chauvet box and Art-Net, say).
class MultiDmxSpec extends DmxSpec {
  const MultiDmxSpec(this.parts);

  final List<DmxSpec> parts;
}

/// The Chauvet driver part of [spec], if it has one: the player watches that
/// interface for being unplugged, as before.
EfkDmxSpec? efkPart(DmxSpec spec) => switch (spec) {
  EfkDmxSpec() => spec,
  MultiDmxSpec(:final parts) => parts.whereType<EfkDmxSpec>().firstOrNull,
  _ => null,
};

/// True for a real output, false for the test one.
bool isRealDmx(DmxSpec spec) => switch (spec) {
  FakeDmxSpec() => false,
  MultiDmxSpec(:final parts) => parts.any(isRealDmx),
  _ => true,
};

/// Opens the output [spec] describes. Throws [DmxError] when it can't.
Future<DmxOutput> openDmx(DmxSpec spec) async => switch (spec) {
  FakeDmxSpec(:final logPath) => FakeDmx(logPath),
  EfkDmxSpec(:final driverDir) when Platform.isWindows || Platform.isMacOS => await HelperDmx.open(helper: dmxHelperPath(), driverDir: driverDir),
  EfkDmxSpec() => throw DmxError("The DMX output didn't start: there is no interface driver for this computer."),
  EnttecProSpec(:final port) => EnttecProDmx.open(port),
  ArtNetSpec(:final host, :final first, :final count, :final port) => await ArtNetDmx.open(host: host, first: first, count: count, port: port),
  MultiDmxSpec(:final parts) => await MultiDmx.open(parts),
};

/// True once [out] has stopped by itself: a helper ended or an Enttec Pro
/// was unplugged. The player then opens it again.
bool dmxEnded(DmxOutput out) => switch (out) {
  HelperDmx(:final alive) => !alive,
  EnttecProDmx(:final alive) => !alive,
  MultiDmx(:final parts) => parts.any(dmxEnded),
  _ => false,
};

/// The name of the Chauvet interface in [out], for finding it among the
/// computer's devices. Null when [out] has none.
String? efkName(DmxOutput out) => switch (out) {
  HelperDmx(:final name) => name,
  MultiDmx(:final parts) => parts.map(efkName).nonNulls.firstOrNull,
  _ => null,
};

/// Every frame to each of [parts].
class MultiDmx implements DmxOutput {
  MultiDmx._(this.parts);

  /// Opens each part. When one fails, the ones already open are closed and
  /// the error says which output it was.
  static Future<MultiDmx> open(List<DmxSpec> specs) async {
    final open = <DmxOutput>[];
    for (final s in specs) {
      try {
        open.add(await openDmx(s));
      } on DmxError {
        for (final o in open) {
          await o.close();
        }
        rethrow;
      }
    }
    return MultiDmx._(open);
  }

  final List<DmxOutput> parts;

  @override
  String get name => parts.map((p) => p.name).join(' + ');

  @override
  void send(Uint8List frame) {
    for (final p in parts) {
      p.send(frame);
    }
  }

  @override
  Future<void> close() async {
    for (final p in parts) {
      await p.close();
    }
  }
}

class FakeDmx implements DmxOutput {
  FakeDmx(this.logPath);

  final String? logPath;
  String? _last;

  @override
  String get name => 'test interface';

  @override
  void send(Uint8List frame) {
    if (logPath == null) return;
    final sb = StringBuffer();
    for (var i = 0; i < 512; i++) {
      if (frame[i] != 0) sb.write('${i + 1}=${frame[i]}\n');
    }
    final text = sb.toString();
    if (text == _last) return;
    _last = text;
    try {
      File(logPath!).writeAsStringSync(text);
    } on FileSystemException {
      // a reader has the file open: the next frame writes it
    }
  }

  @override
  Future<void> close() async {
    if (logPath == null) return;
    try {
      File(logPath!).writeAsStringSync('');
    } on FileSystemException {
      // nothing to tidy
    }
  }
}
