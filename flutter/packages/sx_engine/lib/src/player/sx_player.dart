import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../dmx/dmx_output.dart';
import '../dmx/efk_dmx.dart';
import '../dmx/helper_dmx.dart';
import '../show/show_env.dart';
import 'midi_winmm.dart';
import 'os2l.dart';
import 'player_commands.dart';
import 'player_core.dart';
import 'player_files.dart';
import 'player_show.dart';
import 'win32.dart' as win;

/// How to start the player. A plain value, so it can go to the isolate.
class PlayerConfig {
  const PlayerConfig({required this.show, required this.dmx, this.midi = false, this.os2lPort = 0, this.announce = false});

  /// The show folder.
  final String show;
  final DmxSpec dmx;

  /// Open the APC mini (ShowXpress's MIDI devices). Windows only: on a Mac
  /// the player is worked from the screen and from phones.
  final bool midi;

  /// Listen for VirtualDJ on this port. 0 = don't.
  final int os2lPort;

  /// Announce the OS2L port through Bonjour.
  final bool announce;
}

/// The SX Player: plays the show's scenes and movements straight to the DMX
/// interface, 40 frames a second, with ShowXpress closed.
///
/// It runs on its own isolate, so a slow file tool on the engine's isolate
/// can never stall the lights. The old player was a child process kept alive
/// by a line from the server every second, and one slow request could starve
/// that keep-alive and black out the rig. This one has no keep-alive: it
/// plays until it is told to stop or the app quits.
///
/// The old player ran on Windows only. This one also runs on a Mac, through
/// the `sxh_dmx` helper live aim uses there.
///
/// Port of `player.ps1` (the running part) and `SxPlayer.Run`.
class SxPlayer {
  SxPlayer._(this.iface, this._commands, this._events, this._exit, this._isolate);

  /// Opens the show and the interface and starts playing. Throws [DmxError]
  /// with the old player's `ERR` message when it can't.
  static Future<SxPlayer> start(PlayerConfig config) async {
    final events = ReceivePort();
    final exit = ReceivePort();
    final it = StreamIterator(events);
    final isolate = await Isolate.spawn(_playerMain, (config, events.sendPort), onExit: exit.sendPort, onError: events.sendPort, errorsAreFatal: true);
    final first = await it.moveNext() ? it.current : null;
    if (first is! _Ready) {
      events.close();
      exit.close();
      throw DmxError(first is String ? first : "The DMX output didn't start: $first");
    }
    final player = SxPlayer._(first.iface, first.commands, events, exit, isolate);
    unawaited(player._listen(it));
    exit.listen((_) => player._ended());
    return player;
  }

  /// The interface's name, as the old player's `OK` line had it.
  final String iface;
  final SendPort _commands;
  final ReceivePort _events, _exit;
  final Isolate _isolate;
  final _done = Completer<void>();
  bool _stopping = false;
  Map<String, Object?>? _status;
  final _statusListeners = <void Function(Map<String, Object?>)>[];

  /// False once the player has stopped, asked to or not.
  bool get running => !_done.isCompleted;

  /// True when it stopped without being asked (a crash).
  bool get stoppedByItself => _done.isCompleted && !_stopping;

  /// Completes when the player has stopped and let go of the interface.
  Future<void> get done => _done.future;

  /// The latest status, key for key the old status file. Null until the
  /// first one arrives and after the player stopped.
  Map<String, Object?>? get status => running ? _status : null;

  /// Called with every new status, on the engine's isolate.
  void onStatus(void Function(Map<String, Object?>) f) => _statusListeners.add(f);

  Future<void> _listen(StreamIterator<Object?> it) async {
    while (await it.moveNext()) {
      final m = it.current;
      if (m is Map<String, Object?>) {
        _status = m;
        for (final f in _statusListeners) {
          f(m);
        }
      }
    }
  }

  /// Applies a command between two frames. Returns false when the player has
  /// stopped, as the old server's `Send-Player` did.
  bool send(PlayerCommand c) {
    if (!running) return false;
    _commands.send(c);
    return true;
  }

  /// Lights out, pads dark, interface released.
  Future<void> stop() async {
    if (!running) return;
    _stopping = true;
    _commands.send(const _Quit());
    await _done.future.timeout(const Duration(seconds: 4), onTimeout: kill);
  }

  /// Ends the player at once, without putting the lights out. For a player
  /// that doesn't answer [stop]. The engine's watchdog sees it as stopped by
  /// itself unless [stop] was called first.
  void kill() {
    _isolate.kill(priority: Isolate.immediate);
    _ended();
  }

  void _ended() {
    _exit.close();
    _events.close();
    if (!_done.isCompleted) _done.complete();
  }
}

class _Ready {
  const _Ready(this.iface, this.commands);
  final String iface;
  final SendPort commands;
}

class _Quit {
  const _Quit();
}

Future<void> _playerMain((PlayerConfig, SendPort) args) async {
  final (cfg, owner) = args;
  final fixtures = p.join(cfg.show, 'fixtures.ini');
  if (!File(fixtures).existsSync()) return owner.send("The show's fixture list (fixtures.ini) was not found.");
  final patch = readPlayerPatch(fixtures);
  if (patch.isEmpty) return owner.send("No fixtures found in the show's fixtures.ini.");
  final core = PlayerCore(PlayerFiles(patch));
  try {
    loadPlayerBoard(core, ShowEnv(cfg.show));
  } on Exception catch (e) {
    return owner.send("Could not read the show's live pages: ${errorText(e)}");
  }
  DmxOutput out;
  try {
    // The Mac's driver runs in a helper program, which only opens asynchronously.
    out = await openDmxAsync(cfg.dmx);
  } on DmxError catch (e) {
    return owner.send(e.message);
  }
  final clock = Stopwatch()..start();
  double now() => clock.elapsedMicroseconds / 1000.0;
  core.setBpm(playerStartBpm(cfg.show), 0, 'manual');
  core.checkShow();

  // watch the interface: unplugged -> stop sending, plugged back -> open it again.
  // On a Mac the helper ending is the sign, and opening it again starts a new one.
  final device = cfg.dmx is EfkDmxSpec ? EfkDevice.find(out.name) : null;
  bool present() => switch (cfg.dmx) {
    FakeDmxSpec(:final logPath?) => !File(p.join(p.dirname(logPath), '_iface_unplugged')).existsSync(),
    EfkDmxSpec() => switch (out) {
      HelperDmx(:final alive) => alive,
      _ => device?.present() ?? true,
    },
    _ => true,
  };

  final isWindows = Platform.isWindows && cfg.dmx is EfkDmxSpec;
  // No sleep and the screen stays on while the player runs. Windows is asked
  // again every 30 seconds below. A Mac is held awake by `caffeinate`, which
  // ends with the app if the player never gets to stop it.
  Process? awake;
  if (Platform.isMacOS && cfg.dmx is EfkDmxSpec) {
    try {
      awake = await Process.start('/usr/bin/caffeinate', ['-d', '-i', '-w', '$pid']);
    } on ProcessException {
      // the Mac may sleep: the lights still play
    }
  }
  WinMidi? midi;
  if (cfg.midi && isWindows) {
    try {
      final dev = PlayerDevices.read(cfg.show);
      midi = WinMidi.open(dev.midiIn, dev.midiOut, (m) {
        try {
          core.midi(m, now());
        } on Exception catch (e) {
          core.lastError = errorText(e);
        }
      });
      core.midiName = midi.name;
    } on Object {
      // no MIDI: the board still plays
    }
  }

  Os2lListener? os2l;
  if (cfg.os2lPort > 0) {
    os2l = await Os2lListener.start(
      cfg.os2lPort,
      announce: cfg.announce,
      onMessage: (j) {
        try {
          core.os2lMessage(j, now());
        } on Exception catch (e) {
          core.lastError = errorText(e);
        }
      },
    );
  }

  final commands = ReceivePort();
  var run = true;
  Timer? timer;
  var lost = false, reopening = false;
  var lastStat = -1000.0, lastDev = -1000.0, backAt = -1.0, retryAt = 0.0, lastAwake = -1e9;

  void sendStatus() {
    core
      ..lost = lost
      ..os2lPeer = os2l?.peer ?? ''
      ..os2lErr = os2l?.err ?? ''
      ..os2lPort = os2l?.port ?? 0;
    owner.send(core.status());
  }

  Future<void> reopen() async {
    // the interface came back: open it again
    if (cfg.dmx is FakeDmxSpec) {
      lost = false;
      core.reconnects++;
      return;
    }
    reopening = true;
    try {
      out.close();
    } on Object {
      // already gone
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      out = await openDmxAsync(cfg.dmx);
      lost = false;
      core.reconnects++;
    } on DmxError {
      retryAt = now() + 2000;
    }
    reopening = false;
  }

  Future<void> shutDown() async {
    run = false;
    timer?.cancel();
    commands.close();
    // lights out, then let ShowXpress have the interface again
    core.allOff();
    await os2l?.stop();
    try {
      core.syncLeds(true, midi?.send); // pads back to their "off" colours
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } on Object {
      // pads stay as they are
    }
    midi?.close();
    final dark = Uint8List(dmxFrameSize);
    for (var i = 0; i < 3; i++) {
      if (!lost && !reopening) out.send(dark);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    out.close();
    if (isWindows) win.fineTimers(false);
    awake?.kill();
    Isolate.exit();
  }

  commands.listen((m) {
    if (!run) return;
    if (m is _Quit) {
      unawaited(shutDown());
      return;
    }
    core.apply(m as PlayerCommand, now());
    sendStatus();
  });

  if (isWindows) win.fineTimers(true);
  var next = now();
  void tick() {
    if (!run) return;
    final t = now();
    final o = core.frame(t);
    if (t - lastDev > 500) {
      lastDev = t;
      if (!present()) {
        lost = true;
        backAt = -1;
        // a Mac helper that ended never comes back by itself: start a new one
        if (out is HelperDmx && !reopening && t >= retryAt) unawaited(reopen());
      } else if (lost && !reopening) {
        if (backAt < 0) backAt = t;
        if (t - backAt > 1500 && t >= retryAt) unawaited(reopen());
      }
    }
    if (!lost && !reopening) out.send(o);
    try {
      core.syncLeds(false, midi?.send);
    } on Object {
      // a pad light that didn't go out is not worth stopping for
    }
    if (t - lastStat > 200) {
      lastStat = t;
      sendStatus();
    }
    if (isWindows && t - lastAwake > 30000) {
      lastAwake = t;
      win.keepAwake(); // no sleep, screen stays on, while the player runs
    }
    next += 25; // 40 frames a second, on a steady clock
    var w = next - now();
    if (w < -200) {
      next = now();
      w = 0;
    }
    timer = Timer(Duration(microseconds: (math.max(0.0, w) * 1000).round()), tick);
  }

  owner.send(_Ready(out.name, commands.sendPort));
  tick();
}
