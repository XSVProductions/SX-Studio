import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sx_api/sx_api.dart';

import '../show/show_env.dart';
import '../sx/remote_setup.dart';
import 'bridge.dart';
import 'win_midi.dart';

// Runs the APC40 bridge for as long as the engine does: on its own isolate,
// so its 10 ms loop, the MIDI callbacks and the waits after a sysex never hold
// up the engine. It waits for the APC40 to be plugged in, and keeps going
// with the window closed.
//
// Port of the APC40 block of `df_aim_gui.ps1` (`Step-Apc40`, `Stop-Apc40`,
// `Send-Apc40`, `Get-Apc40Status`, `Test-Apc40Busy`) and of the TCP part of
// `apc40.ps1` (`Open-Sx`, `Send-Sx`, `Read-SxLines`, `Get-RemoteSetup`).

/// Starts, restarts and stops the bridge, and keeps its last status.
class Apc40Runner {
  Apc40Runner({
    required this.enabled,
    required this.showRoot,
    required this.layoutFile,
    required this.sxRunning,
    this.noMidi = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// False on a Mac or Linux, in tests and with a show given for
  /// development: then nothing ever starts (the old rule: not on a Mac, not
  /// with `-TestRoot`, which would take the real APC40).
  final bool enabled;

  /// The show folder. Throws `ToolError` when there is none, and the bridge
  /// is tried again later.
  final String Function() showRoot;
  final File Function() layoutFile;

  /// Is ShowXpress open. Passed on to the bridge, which asks before it connects.
  final bool Function() sxRunning;

  /// Run without an APC40 (the old `-NoMidi`). For tests.
  final bool noMidi;
  final DateTime Function() _clock;

  _Bridge? _b;
  var _next = DateTime.utc(1);
  var _starting = false;
  Apc40Status? _status;

  /// True while the bridge runs. `Test-Apc40`.
  bool get alive => _b?.alive ?? false;

  /// The bridge's last status, `running` false once it has stopped. Null
  /// before its first one. `Get-Apc40Status`.
  Apc40Status? status() {
    final s = _status;
    if (s == null || alive || !s.running) return s;
    return Apc40Status.fromJson({...s.toJson(), 'running': false});
  }

  /// The APC40 is in use, so the engine must not quit when idle. `Test-Apc40Busy`.
  bool get busy => alive && _status?.apc == 'ok';

  /// Sends a command (`reload`, `q`). False when the bridge isn't running. `Send-Apc40`.
  bool send(String command) {
    final b = _b;
    if (b == null || !b.alive) return false;
    b.commands.send(command);
    return true;
  }

  /// Called every second by the engine. Starts the bridge, or starts it
  /// again when it has died, at most every 20 seconds. `Step-Apc40`.
  void step() {
    final b = _b;
    if (b != null && b.alive) {
      final open = sxRunning();
      if (open != b.sxSent) b.commands.send(b.sxSent = open);
      return;
    }
    if (!enabled || _starting || _clock().isBefore(_next)) return;
    _next = _clock().add(const Duration(seconds: 20));
    _status = null;
    _starting = true;
    unawaited(_start().whenComplete(() => _starting = false));
  }

  Future<void> _start() async {
    try {
      final open = sxRunning();
      _b = await _Bridge.spawn((root: showRoot(), layout: layoutFile().path, noMidi: noMidi, sxOpen: open), (s) => _status = s)
        ..sxSent = open;
    } catch (_) {
      // no show yet, or the isolate didn't start: tried again in 20 s
    }
  }

  /// Asks the bridge to stop (lights off, the APC40 let go) and waits up
  /// to 4 seconds. `Stop-Apc40`.
  ///
  /// The old app killed the process when it didn't stop in time. An isolate
  /// is not killed here: winmm could still call into it, which would crash
  /// the whole app. The engine is on its way out anyway.
  Future<void> stop() async {
    final b = _b;
    _b = null;
    if (b == null || !b.alive) return;
    b.commands.send('q');
    await b.exited.timeout(const Duration(seconds: 4), onTimeout: () {});
  }
}

/// What the bridge's isolate needs to start. Plain values, sent to it.
typedef _Args = ({String root, String layout, bool noMidi, bool sxOpen});

/// The engine's end of a running bridge.
class _Bridge {
  _Bridge._();

  /// Strings are commands, a bool says whether ShowXpress is open.
  late final SendPort commands;
  final _exited = Completer<void>();

  /// Completes when the isolate has ended.
  Future<void> get exited => _exited.future;
  bool get alive => !_exited.isCompleted;

  /// What [commands] last said about ShowXpress.
  bool? sxSent;

  static Future<_Bridge> spawn(_Args args, void Function(Apc40Status) onStatus) async {
    final b = _Bridge._();
    final from = ReceivePort(), exit = ReceivePort();
    final first = Completer<SendPort>();
    from.listen((m) {
      if (m is SendPort) first.complete(m);
      if (m is Apc40Status) onStatus(m);
    });
    exit.listen((_) {
      exit.close();
      b._exited.complete();
      if (!first.isCompleted) first.completeError(StateError('the APC40 bridge stopped at once'));
      // the last status comes on the other port, which has no order with this one: give it a moment
      Timer(const Duration(milliseconds: 200), from.close);
    });
    await Isolate.spawn(_main, (args, from.sendPort), onExit: exit.sendPort, debugName: 'apc40');
    b.commands = await first.future;
    return b;
  }
}

/// The bridge's isolate: the old `apc40.ps1 -Action Run`.
Future<void> _main((_Args, SendPort) a) async {
  final (args, owner) = a;
  final commands = ReceivePort();
  final sx = _IsolateSx(args.root)..running = args.sxOpen;
  final bridge = Apc40Bridge(
    midi: args.noMidi || !Platform.isWindows ? null : WinApc40Midi(),
    sx: sx,
    layoutFile: File(args.layout),
    pause: sleep,
    onStatus: owner.send,
  );
  commands.listen((m) {
    if (m is bool) {
      sx.running = m;
    } else if (m is String) {
      bridge.command(m);
    }
  });
  owner.send(commands.sendPort);
  try {
    while (await bridge.step()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  } finally {
    bridge.finish();
    commands.close();
  }
}

/// ShowXpress as seen from the bridge's isolate.
class _IsolateSx implements Apc40Sx {
  _IsolateSx(this.root);

  final String root;

  @override
  var running = false;

  /// Port of `Get-RemoteSetup`: the password from live.ini, the port from
  /// ShowXpress's param.ini (7348 when it isn't there), and the fader types.
  @override
  Apc40Remote setup() {
    final c = RemoteConfig.read(ShowEnv(root));
    return (password: c.password, port: c.port, faderTypes: {for (final f in c.info.faders) f.k: f.type == '0' ? 'dimmer' : 'speed'});
  }

  @override
  Future<Apc40SxLink?> connect(int port) => TcpSxLink.connect(port);
}

/// A connection to ShowXpress's remote over TCP. What comes in is kept
/// until [read] takes it.
class TcpSxLink implements Apc40SxLink {
  TcpSxLink._(this._socket) {
    final sink = utf8.decoder.startChunkedConversion(StringConversionSink.fromStringSink(_in));
    _sub = _socket.listen(sink.add, onDone: () => _gone = true, onError: (Object _) => _gone = true, cancelOnError: true);
    // a write to a connection ShowXpress has dropped fails here, not in [write]
    _socket.done.then(
      (_) {},
      onError: (Object _) {
        _gone = true;
      },
    );
  }

  /// Connects on this computer. Null when nothing answered within 1.5 seconds.
  static Future<TcpSxLink?> connect(int port, {String host = '127.0.0.1'}) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      s.setOption(SocketOption.tcpNoDelay, true);
      return TcpSxLink._(s);
    } on Object {
      return null;
    }
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;
  final _in = StringBuffer();
  var _gone = false, _closed = false;

  @override
  String? read() {
    if (_in.isEmpty) return _gone ? null : '';
    final t = _in.toString();
    _in.clear();
    return t;
  }

  @override
  void write(String text) {
    if (_gone || _closed) throw const SocketException('The connection to ShowXpress is closed.');
    _socket.add(utf8.encode(text));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_sub.cancel());
    _socket.destroy();
  }
}
