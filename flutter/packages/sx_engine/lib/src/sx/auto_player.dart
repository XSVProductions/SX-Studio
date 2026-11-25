import 'dart:async';
import 'dart:io' show pid;
import 'dart:math';

import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/show_env.dart';
import '../tools/auto_show.dart';
import 'remote_setup.dart';
import 'sx_remote.dart';

// AUTO SHOW: plays the looks from auto_show.json one after another, each for
// its number of bars at the BPM, by pressing their buttons in ShowXpress (or
// on the SX Player when it plays). Runs inside the engine on a timer. The
// timing is a function of [AutoShow.clock], so tests step it by hand.
//
// Port of `sx_remote.ps1 -Action Auto` and the AUTO SHOW block of `df_aim_gui.ps1`.

/// What the SX Player tells the Auto Show while it plays.
class PlayerBeat {
  const PlayerBeat({required this.bpm, required this.src, required this.onSlots});

  /// The player's beat clock.
  final double bpm;

  /// Where the tempo comes from: `tap`, `VirtualDJ` or ''.
  final String src;

  /// live.ini sections (`page3_button1`) of the buttons that are on.
  final Set<String> onSlots;
}

/// What the Auto Show needs from the SX Player. The player's area provides
/// it with `e.provide<AutoPlayerLink>(...)`.
///
/// Port of the old named-pipe protocol (`ton`, `toff`, `sync`, `bpm`) and the
/// player's status file. The send methods throw when the player isn't answering.
abstract interface class AutoPlayerLink {
  /// The player is playing (old `Test-Player`).
  bool get playing;

  /// The player's tempo and what is on, or null when it stopped.
  PlayerBeat? beat();

  /// Turns on the show's first button with this title (`ton <title>`).
  void titleOn(String title);

  /// Turns it off (`toff <title>`).
  void titleOff(String title);

  /// Bar 1 now (`sync`).
  void sync();

  /// `bpm <n>`.
  void setBpm(double bpm);
}

/// What other areas may do with the Auto Show (`e.find<AutoShowControl>()`).
abstract interface class AutoShowControl {
  bool get running;

  /// The looks play on the SX Player, not ShowXpress.
  bool get onPlayer;

  /// Starts again with the look that plays now, on ShowXpress or the player
  /// (whichever plays now). The Lab calls this when the player starts or
  /// stops, as the old Lab did with `Start-Auto`.
  Future<void> restart();
}

/// `[math]::Round(x, 1)`.
double _round1(double x) => psRound(x * 10) / 10;

/// The player as a [ButtonSession]: buttons by title, on and off over its link.
class _PlayerSession implements ButtonSession {
  _PlayerSession(this._link, this.list);

  final AutoPlayerLink _link;

  @override
  final List<ButtonOnAir> list;

  @override
  Future<void> send(List<String> cmds) async {
    for (final c in cmds) {
      final t = c.substring(c.indexOf('|') + 1), on = c.startsWith('BUTTON_PRESS');
      on ? _link.titleOn(t) : _link.titleOff(t);
      for (final b in list) {
        if (psEq(b.title, t)) b.pressed = on;
      }
    }
  }

  @override
  Future<void> close() async {}
}

/// The Auto Show. One per engine.
class AutoShow implements AutoShowControl {
  AutoShow({required this.show, required this.sxOpen, AutoPlayerLink? Function()? player, double Function()? clock, Random? random, this.timer = true})
    : player = player ?? (() => null),
      clock = clock ?? _stopwatch(),
      random = random ?? Random();

  static double Function() _stopwatch() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds / 1000;
  }

  final ShowEnv Function() show;
  final bool Function() sxOpen;
  final AutoPlayerLink? Function() player;

  /// Milliseconds, only ever going up.
  final double Function() clock;
  final Random random;

  /// Runs [tick] on a timer while playing. Tests turn it off and tick by hand.
  final bool timer;

  Timer? _timer;
  Future<void>? _ticking;

  // ---- the state the old child process kept
  var _running = false;
  AutoStatus? _last;
  late ShowEnv _env;
  late AutoConfig _cfg;
  late RemoteConfig _setup;
  var _usePl = false;
  var _curId = '', _nextId = '';
  var _lookStart = 0.0, _lastTry = -99999.0, _lastOpen = -99999.0, _lastPl = -99999.0;
  var _need = true, _first = true, _held = false, _applied = false;
  var _sxOn = false;
  var _error = '', _src = '', _startedAt = '';
  var _missing = <String>[];
  var _changes = 0;

  /// Goes up whenever the look must be pressed again, so a press that was
  /// already under way doesn't mark the newer request done.
  var _gen = 0;
  final _mine = <String>[], _hist = <String>[], _bag = <String>[];
  var _swapOf = psMap<int>();

  @override
  bool get running => _running;

  @override
  bool get onPlayer => _running && _usePl;

  AutoLook? _look(String id) => id.isEmpty ? null : _cfg.looks.where((l) => psEq(l.id, id)).firstOrNull;

  List<AutoLook> get _active => [
    for (final l in _cfg.looks)
      if (l.on && l.titles.isNotEmpty) l,
  ];

  double _ms(AutoLook l) => l.bars * 4 * 60000 / _cfg.bpm;

  /// Port of `Get-NextId`.
  String _nextAfter(String from) {
    final a = _active;
    if (a.isEmpty) return '';
    if (_cfg.order == 'shuffle' && a.length > 2) {
      _bag.removeWhere((b) => !a.any((l) => psEq(l.id, b)));
      // a new round: every look once, in a random order (not the one playing now, it was just played)
      if (!_bag.any((b) => !psEq(b, from))) {
        _bag
          ..clear()
          ..addAll([
            for (final l in a)
              if (!psEq(l.id, from)) l.id,
          ]);
      }
      final cand = [
        for (final b in _bag)
          if (!psEq(b, from)) b,
      ];
      return cand[random.nextInt(cand.length)];
    }
    final i = a.lastIndexWhere((l) => psEq(l.id, from));
    if (i < 0) {
      // look switched off or removed: carry on from where it was in the full list
      final all = _cfg.looks, j = all.lastIndexWhere((l) => psEq(l.id, from));
      if (j >= 0) {
        for (var k = 1; k <= all.length; k++) {
          final c = all[(j + k) % all.length];
          if (c.on && c.titles.isNotEmpty) return c.id;
        }
      }
      return a[0].id;
    }
    return a[(i + 1) % a.length].id;
  }

  /// Port of `Set-Cur`.
  void _setCur(String id, {bool remember = true}) {
    if (remember && _curId.isNotEmpty && !psEq(_curId, id)) {
      _hist.add(_curId);
      if (_hist.length > 50) _hist.removeAt(0);
    }
    _curId = id;
    _bag.remove(id);
    _lookStart = clock();
    _wantAgain();
    _nextId = _nextAfter(id);
  }

  void _wantAgain() {
    _gen++;
    _need = true;
    _lastTry = -99999;
  }

  /// The status the screen shows. Null when the Auto Show never ran.
  /// Port of `Write-Status` and `Get-AutoStatus`.
  AutoStatus? status() {
    if (!_running) return _last;
    final now = clock();
    final l = _look(_curId), n = _look(_nextId);
    var bars = 0, bar = 0, beat = 0, msLeft = 0;
    if (l != null) {
      final el = now - _lookStart, beatMs = 60000 / _cfg.bpm;
      bars = l.bars;
      bar = min(l.bars, (el / (beatMs * 4)).floor() + 1);
      beat = ((el / beatMs).floor() % 4) + 1;
      msLeft = _held ? -1 : psRound(max(0, _ms(l) - el));
    }
    return AutoStatus(
      running: true,
      pid: pid,
      lookId: _curId,
      name: l?.name ?? '',
      next: n?.name ?? '',
      nextId: _nextId,
      bars: bars,
      bar: bar,
      beat: beat,
      msLeft: msLeft,
      bpm: _cfg.bpm,
      held: _held,
      applied: _applied,
      error: _error,
      missing: _missing,
      at: DateTime.now().toUtc().toIso8601String(),
      changes: _changes,
      startedAt: _startedAt,
      target: _usePl ? 'player' : 'showxpress',
      src: _src,
    );
  }

  /// Ends with [error] and keeps the last status for the screen.
  AutoStatus _end(String error) {
    _error = error;
    final s = status();
    _running = false;
    _timer?.cancel();
    _timer = null;
    return _last = AutoStatus.fromJson({...?s?.toJson(), 'running': false, 'error': error});
  }

  /// Starts, with the look [look] first when it is one. Stops a running show
  /// first. Port of `Start-Auto` and the start of `-Action Auto`.
  Future<AutoAnswer> start([String look = '']) async {
    await stop();
    _last = null;
    final link = player();
    _usePl = link?.playing ?? false;
    try {
      _env = show();
      _cfg = readAutoConfig(_env, random: random);
      _setup = RemoteConfig.read(_env);
    } on ToolError catch (e) {
      return AutoAnswer(ok: false, error: e.message);
    }
    _curId = _nextId = _error = _src = '';
    _need = _first = true;
    _held = _applied = _sxOn = false;
    _lastTry = _lastOpen = _lastPl = -99999;
    _missing = [];
    _changes = 0;
    _mine.clear();
    _hist.clear();
    _bag.clear();
    _startedAt = DateTime.now().toIso8601String().substring(0, 19);
    _running = true;
    final swapPg = <int>{};
    final pageRx = RegExp(r'^page(\d+)$', caseSensitive: false);
    for (final (name, keys) in _setup.info.sections) {
      final m = pageRx.firstMatch(name);
      if (m != null && psEq(keys['swap'] ?? '', 'yes')) swapPg.add(int.parse(m[1]!));
    }
    _swapOf = psMap<int>();
    for (final b in _setup.info.buttons) {
      if (b.title.isNotEmpty && !_swapOf.containsKey(b.title)) _swapOf[b.title] = swapPg.contains(b.page) ? b.page : 0;
    }

    if (!_usePl && !_setup.ready) return _refused('The ShowXpress remote is off - turn it on first.');
    if (_usePl) {
      final b = link?.beat();
      if (b != null && b.bpm >= 40) _cfg.bpm = _round1(b.bpm); // the player's tempo wins
    }
    final a0 = _active;
    if (a0.isEmpty) return _refused('No look to play - add a look with at least one button and switch it on.');
    _setCur(_look(look) != null && RegExp(r'^[0-9a-f]{8}$', caseSensitive: false).hasMatch(look) ? look : a0[0].id, remember: false);
    if (timer) _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => tick());
    await tick();
    final s = status();
    if (s == null || !s.running) return AutoAnswer(ok: false, error: s?.error ?? "The Auto Show didn't start.", status: s);
    return AutoAnswer(ok: true, status: s);
  }

  AutoAnswer _refused(String error) {
    final s = _end(error);
    return AutoAnswer(ok: false, error: error, status: s);
  }

  /// Stops. With "turn the look off" set, releases what it turned on.
  /// Port of `Stop-Auto` and the old player's `Stop-Player`.
  Future<AutoStatus?> stop() async {
    if (!_running) return _last;
    _timer?.cancel();
    _timer = null;
    await _ticking;
    if (_cfg.stop == 'off' && _mine.isNotEmpty) {
      ButtonSession? cn;
      try {
        cn = (await _connect()).session;
        if (cn != null) {
          final by = byTitle(cn.list);
          await cn.send([
            for (final t in _mine)
              if (by[t]?.pressed ?? false) 'BUTTON_RELEASE|$t',
          ]);
        }
      } catch (_) {
        // stopping goes on regardless
      } finally {
        await cn?.close();
      }
    }
    return _end(_error);
  }

  @override
  Future<void> restart() async {
    if (!_running) return;
    await start(_curId);
  }

  /// A command from the screen. False when the Auto Show isn't playing.
  /// Port of the old player's stdin commands.
  bool command(AutoCmd cmd, [String arg = '']) {
    if (!_running) return false;
    final now = clock();
    switch (cmd) {
      case AutoCmd.next:
        _setCur(_nextId.isNotEmpty ? _nextId : _curId);
      case AutoCmd.prev:
        if (_hist.isNotEmpty) {
          final p = _hist.removeLast();
          if (_look(p) != null) _setCur(p, remember: false);
        }
      case AutoCmd.go:
        if (_look(arg) != null) _setCur(arg);
      case AutoCmd.hold:
        _held = true;
      case AutoCmd.resume:
        _held = false;
        _lookStart = now;
      case AutoCmd.sync:
        _lookStart = now;
        if (_usePl) _try(() => player()?.sync());
      case AutoCmd.bpm:
        final b = double.tryParse(arg);
        if (b != null && b >= 40 && b <= 220) {
          final el = (now - _lookStart) * _cfg.bpm / b;
          _cfg.bpm = _round1(b);
          _lookStart = now - el;
          if (_usePl) _try(() => player()?.setBpm(b));
        }
    }
    unawaited(tick());
    return true;
  }

  void _try(void Function() f) {
    try {
      f();
    } catch (_) {}
  }

  /// The settings were saved: read them again. Port of the `reload` command.
  void reload() {
    if (!_running) return;
    final now = clock(), old = _cfg.bpm;
    try {
      _cfg = readAutoConfig(_env, random: random);
      _setup = RemoteConfig.read(_env);
    } on ToolError catch (e) {
      _end('Auto Show stopped: ${e.message}');
      return;
    }
    if (_usePl) _cfg.bpm = old; // on the player its beat clock keeps the tempo
    if (_look(_curId) == null) {
      final a = _active;
      if (a.isNotEmpty) _setCur(a[0].id);
    } else {
      _wantAgain();
      _nextId = _nextAfter(_curId);
      if (_cfg.bpm != old) _lookStart = now - (now - _lookStart) * old / _cfg.bpm;
    }
  }

  /// One pass of the old player's loop. Runs every 40 ms while playing.
  Future<void> tick() {
    if (!_running) return Future.value();
    return _ticking ??= _tick().whenComplete(() => _ticking = null);
  }

  Future<void> _tick() async {
    try {
      final now = clock();
      // ---- time for the next look?
      final l = _look(_curId);
      if (l != null && !_held && now - _lookStart >= _ms(l)) {
        final over = (now - _lookStart) - _ms(l);
        _setCur(_nextId.isNotEmpty ? _nextId : _curId);
        if (over < 2000) _lookStart = now - over; // keep counting on the beat (no drift)
      }
      // ---- ShowXpress opened again (a fresh start has nothing pressed): play the current look again
      if (now - _lastOpen > 2000) {
        _lastOpen = now;
        final on = _usePl ? (player()?.playing ?? false) : sxOpen();
        if (on != _sxOn) {
          if (on) {
            _wantAgain();
            _mine.clear();
          } else {
            _applied = false;
            _error = _usePl
                ? 'The SX Player stopped - waiting for it (the looks keep counting).'
                : 'ShowXpress is closed - waiting for it (the looks keep counting).';
          }
          _sxOn = on;
        }
      }
      // ---- on the player: follow its tempo (tap, VirtualDJ, the Lab)
      if (_usePl && now - _lastPl >= 500) {
        _lastPl = now;
        final ps = player()?.beat();
        if (ps != null && ps.bpm >= 40) {
          _src = ps.src;
          final b = _round1(ps.bpm);
          if ((b - _cfg.bpm).abs() >= 0.1) {
            _lookStart = now - (now - _lookStart) * _cfg.bpm / b;
            _cfg.bpm = b;
          }
        }
      }
      if (_need && _sxOn && now - _lastTry > 3000) {
        _lastTry = now;
        await _invokeLook();
      }
    } catch (e) {
      _end('Auto Show stopped: $e');
    }
  }

  Future<Connection> _connect() async {
    if (!_usePl) return connectShowXpress(_setup, open: sxOpen());
    final link = player(), st = link?.beat();
    if (link == null || st == null) return (session: null, error: 'The SX Player stopped - start it again on the Lab tab.');
    final on = {for (final s in st.onSlots) s.toLowerCase()};
    final seen = <String>{};
    return (
      session: _PlayerSession(link, [
        for (final b in _setup.info.buttons)
          if (b.title.isNotEmpty && seen.add(b.title.toLowerCase())) ButtonOnAir(b.title, b.pageName, on.contains(b.sec.toLowerCase())),
      ]),
      error: '',
    );
  }

  /// The buttons of [l] that can play together: a "swap" page plays one
  /// button at a time, so only its last one counts. Port of `Get-Eff`.
  List<String> _effective(AutoLook l) {
    final last = <int, String>{};
    for (final x in l.titles) {
      final pg = _swapOf[x] ?? 0;
      if (pg != 0) last[pg] = x;
    }
    return [
      for (final t in l.titles)
        if ((_swapOf[t] ?? 0) == 0 || psEq(last[_swapOf[t]] ?? '', t)) t,
    ];
  }

  /// Releases what the last look turned on (unless the new look uses it
  /// too), then presses the new look's buttons. Port of `Invoke-Look`.
  Future<void> _invokeLook() async {
    final l = _look(_curId), gen = _gen;
    if (l == null) {
      _need = false;
      return;
    }
    ButtonSession? cn;
    try {
      final x = await _connect();
      cn = x.session;
      if (cn == null) {
        _error = x.error;
        _applied = false;
        return;
      }
      final by = byTitle(cn.list);
      final eff = _effective(l);
      var rel = [
        for (final t in _mine)
          if (!psIn(t, eff)) t,
      ];
      if (_first && _cfg.clean) {
        rel = [
          for (final b in cn.list)
            if (b.pressed && !psIn(b.title, eff) && !isSetupPage(b.page)) b.title,
          ...rel,
        ];
      }
      final cmds = [
        for (final t in {...rel})
          if (by[t]?.pressed ?? false) 'BUTTON_RELEASE|$t',
        for (final t in eff)
          if (by[t] case final b? when !b.pressed) 'BUTTON_PRESS|$t',
      ];
      await cn.send(cmds);
      _mine
        ..clear()
        ..addAll(eff.where(by.containsKey));
      _missing = [
        for (final t in l.titles)
          if (!by.containsKey(t)) t,
      ];
      _error = '';
      _applied = true;
      _changes++;
      if (gen == _gen) _need = false;
      _first = false;
    } on ToolError catch (e) {
      _error = e.message;
      _applied = false;
    } catch (e) {
      _error = '$e';
      _applied = false;
    } finally {
      await cn?.close();
    }
  }
}
