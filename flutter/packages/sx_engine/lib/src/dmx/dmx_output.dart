import 'dart:io';
import 'dart:typed_data';

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

/// Opens the output [spec] describes. Throws [DmxError] when it can't.
Future<DmxOutput> openDmx(DmxSpec spec) async => switch (spec) {
  FakeDmxSpec(:final logPath) => FakeDmx(logPath),
  EfkDmxSpec(:final driverDir) when Platform.isWindows || Platform.isMacOS => await HelperDmx.open(helper: dmxHelperPath(), driverDir: driverDir),
  EfkDmxSpec() => throw DmxError("The DMX output didn't start: there is no interface driver for this computer."),
};

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
