import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../ps_compat.dart';
import 'dmx_output.dart';

/// Direct DMX output for live aim and the editors' previews: the caller sets
/// channel values, and a sender on its own isolate puts the frame out 40
/// times a second. Its own isolate, so a slow file tool on the engine's
/// isolate can't make the lights stutter.
///
/// Commands, one line each, tokens separated by spaces. One line is applied
/// as a whole, between two frames:
///   z          everything to 0
///   b:ch:v     raw byte. ch = channel 1..8192, v = 0..255
///   p:c:f:v    16-bit value v (0..65535) on coarse channel c and fine
///              channel f. Glides there.
///   s:c:f:v    the same, but jumps there at once
///   k          keep-alive, nothing else
///
/// Safety: with no line for 30 seconds (the screen that was aiming is gone)
/// everything goes to 0 and the interface is released.
///
/// Port of `dmx_out.ps1`.
class LiveDmx {
  LiveDmx._(this.iface, this._commands, this._done);

  /// Opens the output and starts sending. Throws [DmxError] when the
  /// interface can't be opened.
  static Future<LiveDmx> start(DmxSpec spec) async {
    final fromSender = ReceivePort();
    await Isolate.spawn(_sender, (spec, fromSender.sendPort));
    final events = StreamIterator(fromSender);
    await events.moveNext();
    final first = events.current;
    if (first is String) {
      fromSender.close();
      throw DmxError(first);
    }
    final (name, commands) = first as (String, SendPort);
    final done = Completer<void>();
    // the only later event is "stopped"
    unawaited(
      events.moveNext().then((_) {
        fromSender.close();
        done.complete();
      }),
    );
    return LiveDmx._(name, commands, done);
  }

  /// The interface's name.
  final String iface;
  final SendPort _commands;
  final Completer<void> _done;

  /// False once the output has stopped, whether asked to or by the 30 second rule.
  bool get running => !_done.isCompleted;

  /// Applies one command line. Ignored after the output has stopped.
  void send(String line) {
    if (running) _commands.send(line);
  }

  /// Lights out, then releases the interface.
  Future<void> stop() {
    send('q');
    return _done.future;
  }
}

class _Glide {
  _Glide(this.coarse, this.fine, this.current) : target = current;

  int coarse;
  int fine;
  double current;
  double target;
}

Future<void> _sender((DmxSpec, SendPort) args) async {
  final (spec, toOwner) = args;
  final DmxOutput out;
  try {
    out = await openDmx(spec);
  } on DmxError catch (e) {
    toOwner.send(e.message);
    return;
  }
  final frame = Uint8List(dmxFrameSize);
  final glides = <int, _Glide>{};
  var lastCommand = DateTime.now();
  final commands = ReceivePort();
  late final Timer timer;

  Future<void> stop() async {
    timer.cancel();
    commands.close();
    final dark = Uint8List(dmxFrameSize);
    for (var i = 0; i < 3; i++) {
      out.send(dark);
    }
    await out.close();
    toOwner.send(null);
  }

  int num(String s, int max) {
    final v = int.tryParse(s);
    if (v == null || v < 0 || v > max) throw FormatException(s);
    return v;
  }

  commands.listen((line) {
    lastCommand = DateTime.now();
    for (final t in (line as String).split(' ').where((t) => t.isNotEmpty)) {
      try {
        if (t == 'z') {
          frame.fillRange(0, dmxFrameSize, 0);
          glides.clear();
        } else if (t == 'q') {
          unawaited(stop());
          return;
        } else if (t != 'k') {
          final a = t.split(':');
          if (a[0] == 'b' && a.length == 3) {
            frame[num(a[1], dmxFrameSize) - 1] = num(a[2], 255);
          } else if ((a[0] == 'p' || a[0] == 's') && a.length == 4) {
            final c = num(a[1], dmxFrameSize) - 1, f = num(a[2], dmxFrameSize) - 1, v = num(a[3], 65535);
            if (c < 0 || f < 0) continue;
            final g = glides.putIfAbsent(c, () => _Glide(c, f, v.toDouble()));
            g.fine = f;
            g.target = v.toDouble();
            if (a[0] == 's') g.current = g.target;
          }
        }
      } on FormatException {
        // a bad token is skipped, the rest of the line still applies
      } on RangeError {
        // channel 0
      }
    }
  });

  timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
    for (final g in glides.values) {
      final d = g.target - g.current;
      g.current = d.abs() < 3 ? g.target : g.current + d * 0.45;
      final v = psRound(g.current);
      frame[g.coarse] = v >> 8;
      frame[g.fine] = v & 255;
    }
    out.send(frame);
    if (DateTime.now().difference(lastCommand) > const Duration(seconds: 30)) unawaited(stop());
  });

  toOwner.send((out.name, commands.sendPort));
}
