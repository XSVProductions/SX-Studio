import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../dmx/dmx_output.dart';
import '../dmx/efk_dmx.dart';
import '../ps_compat.dart';
import '../server/engine.dart';
import '../show/show_env.dart';
import 'player_commands.dart';
import 'player_links.dart';
import 'player_show.dart';
import 'sx_player.dart';

/// A title ShowXpress's remote control can press.
final titleRx = RegExp(r'^[^"|\r\n]{1,80}$');

/// A button on one of the player's own pages.
final extraButtonRx = RegExp(r'^x\d{1,3}_b\d{1,3}$', caseSensitive: false);
final _liveButtonRx = RegExp(r'^page\d+_button\d+$', caseSensitive: false);
final _fileRx = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.(scex|gpj)$', caseSensitive: false);

const _pendingLabel = 'what the SX Player was playing';

/// One thing the SX Player screen should tell the user about: the interface
/// was unplugged or is back, the player restarted itself, or it handed over
/// to ShowXpress. [n] counts up so the screen shows each one once.
class PlayEvent {
  PlayEvent(this.n, this.kind, this.text, this.at);

  final int n;

  /// lost, back, restart, gone or handoff.
  final String kind;
  final String text;

  /// When, as `(Get-Date).ToString('o')` wrote it.
  final String at;

  Json toJson() => {'n': n, 'kind': kind, 'text': text, 'at': at};
}

/// `DateTime.ToString("o")` for a local time: 7 decimals and the offset.
String roundTripDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final o = t.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final frac = (t.millisecond * 10000 + t.microsecond * 10).toString().padLeft(7, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$frac'
      '$sign${two(o.inHours.abs())}:${two(o.inMinutes.abs() % 60)}';
}

/// A button the player can be asked to play: one from `-List`, or one on
/// the player's own pages.
class LabButton {
  LabButton(this.sec, this.title, this.path, this.kind);

  factory LabButton.fromList(Json b) => LabButton('${b['sec']}', '${b['title']}', '${b['path']}', '${b['kind']}');

  final String sec, title, path;

  /// scex, gpj or missing.
  final String kind;
}

/// The SX Player as the engine runs it: start and stop, the watchdog that
/// restarts it and hands over to ShowXpress, the events the screen shows,
/// and the buttons on the player's own pages.
///
/// Port of the SX PLAYER block of `df_aim_gui.ps1` (`Start-Player`,
/// `Stop-Player`, `Invoke-Handoff`, `Step-PlayerWatch`, `Sync-PlayerExtras`
/// and friends). The keep-alive (`Step-PlayerKeep`) is gone: the player
/// lives on the engine's own process and needs none.
class LabPlayer implements PlayerControl, LabPlayerHooks {
  LabPlayer(this.e, {this.onMac = false}) {
    e.dmx.playerOn = () => running;
    e.dmx.stopPlayer = stop;
  }

  final Engine e;

  /// The old app ran the player on Windows only, for now. Tests set this.
  final bool onMac;

  SxPlayer? _player;
  String _root = '';
  Map<String, Object?>? _snap;
  final _tries = <DateTime>[];
  Timer? _watch;
  PlayEvent? event;
  int _evN = 0;

  /// What ShowXpress was playing just before it closed for the player.
  ({DateTime at, List<String> titles})? _carry;

  /// Button section (any case) to button, from the last `-List`.
  var labMap = psMap<LabButton>();

  /// The buttons on the player's own pages, and what was last sent for each.
  var _labX = psMap<LabButton>();
  var _labXSent = <String, ExtraButton>{};

  /// True when the engine runs on fake DMX, which is the old app's test mode.
  bool get test => e.dmx.spec is FakeDmxSpec;

  @override
  bool get running => _player?.running ?? false;

  @override
  PlayerStatus? get status {
    final s = _player?.status;
    return s == null ? null : PlayerStatus(s);
  }

  Map<String, Object?>? get statusJson => _player?.status;

  @override
  bool titleOn(String title) => send(TitleOnCommand(title));

  @override
  bool titleOff(String title) => send(TitleOffCommand(title));

  @override
  bool setBpm(double bpm) => send(BpmCommand(bpm));

  @override
  bool sync() => send(const SyncCommand());

  @override
  bool tap() => send(const TapCommand());

  /// `Send-Player`.
  bool send(PlayerCommand c) => _player?.send(c) ?? false;

  void _setEvent(String kind, String text) => event = PlayEvent(++_evN, kind, text, roundTripDate(DateTime.now()));

  /// Port of `Start-Player`. Answers `{ok, iface, out, error}`.
  Future<Json> start(String root) async {
    await stop();
    if (onMac) return {'ok': false, 'error': 'The SX Player only runs on Windows for now - the Mac part comes in a later stage.', 'out': ''};
    final spec = e.dmx.spec;
    final fake = spec is FakeDmxSpec;
    final dev = fake ? const PlayerDevices() : PlayerDevices.read(root);
    // the test copy listens on 47350 and doesn't announce itself, so it never meets the real VirtualDJ
    final config = PlayerConfig(show: root, dmx: spec, midi: !fake, os2lPort: fake ? 47350 : dev.os2lPort, announce: !fake);
    String why = '';
    for (var attempt = 0; attempt < 3; attempt++) {
      // right after ShowXpress closes the interface can take a moment to be free
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        final pl = await SxPlayer.start(config);
        _player = pl;
        _root = root;
        _snap = null;
        _seen = null;
        pl.onStatus((s) => _snap = s);
        _watch ??= Timer.periodic(const Duration(seconds: 1), (_) => unawaited(watch()));
        _labXSent = {};
        syncExtras();
        return {'ok': true, 'iface': pl.iface, 'out': '', 'error': ''};
      } on DmxError catch (err) {
        why = err.message;
        if (why != dmxNotFound) break;
      }
    }
    return {'ok': false, 'error': why, 'out': ''};
  }

  /// Port of `Stop-Player`.
  Future<void> stop() async {
    final pl = _player;
    _player = null;
    _watch?.cancel();
    _watch = null;
    if (pl != null) await pl.stop();
  }

  /// Stops the player and lets ShowXpress carry on with what was playing.
  /// The Auto Show goes back to ShowXpress by itself. Port of `Invoke-Handoff`.
  Future<Json> handoff({required bool launch, required String why}) async {
    final titles = <String>[];
    final st = _player?.status;
    if (st != null) {
      for (final o in (st['on'] as List?) ?? const []) {
        final slot = '${(o as Map)['slot']}';
        var b = labMap[slot];
        if (b == null) {
          // a copy on one of the player's own pages: ShowXpress plays the show's button with the same title, if there is one
          final x = _labX[slot];
          if (x != null && labMap.values.any((m) => psEq(m.title, x.title))) b = x;
        }
        if (b != null && titleRx.hasMatch(b.title) && !titles.any((t) => psEq(t, b!.title))) titles.add(b.title);
      }
    }
    final auto = e.find<PlayerAutoShowLink>();
    final wasAuto = (auto?.running ?? false) && auto!.onPlayer;
    await stop();
    if (wasAuto) {
      await auto.restart();
    } else if (titles.isNotEmpty) {
      e.find<PlayerShowXpressLink>()?.setPendingPress(titles, _pendingLabel);
    }
    final sx = launch ? await e.sx.launch() : const ToolResult(ok: true);
    _setEvent('handoff', why);
    return {'ok': sx.ok, 'error': sx.error, 'out': sx.out, 'titles': titles, 'auto': wasAuto, 'test': test};
  }

  bool _watching = false;

  /// Once a second while the player is meant to run. Port of `Step-PlayerWatch`.
  Future<void> watch() async {
    if (_watching) return;
    _watching = true;
    try {
      await _watchOnce();
    } finally {
      _watching = false;
    }
  }

  Future<void> _watchOnce() async {
    if (running) {
      // ShowXpress opened while the player plays: both would fight over the interface - hand over to it
      if (e.sx.running) {
        await handoff(launch: false, why: 'ShowXpress was opened, so the SX Player stopped and handed over to it.');
        return;
      }
      final s = _player?.status;
      if (s != null) {
        final o = _seen;
        if (s['iface'] == 'lost' && (o == null || o['iface'] != 'lost')) {
          _setEvent('lost', 'The DMX interface was unplugged. Plug it back in - the player carries on by itself.');
        }
        if (o != null && psInt(s['reconn']) > psInt(o['reconn'])) _setEvent('back', 'The DMX interface is back - the lights are playing again.');
        _seen = s;
      }
      return;
    }
    if (_player == null) return; // stopped on purpose
    // the player stopped by itself: start it again and put back what was playing
    _player = null;
    final snap = _snap;
    final now = DateTime.now();
    _tries.removeWhere((t) => now.difference(t).inSeconds >= 60);
    if (_tries.length >= 3 || e.sx.running || e.dmx.liveOn || _root.isEmpty) {
      _watch?.cancel();
      _watch = null;
      _setEvent('gone', 'The SX Player stopped and could not be started again. Start it again, or hand over to ShowXpress.');
      return;
    }
    _tries.add(now);
    final r = await start(_root);
    if (r['ok'] != true) {
      _setEvent('gone', 'The SX Player stopped and could not be started again: ${r['error']}');
      return;
    }
    if (snap != null) {
      final fd = (snap['fd'] as List?) ?? const [];
      for (var f = 0; f < 16 && f < fd.length; f++) {
        send(FaderCommand(f, _round((fd[f] as num).toDouble(), 4)));
      }
      final bpm = snap['bpm'];
      if (snap['src'] != 'VirtualDJ' && bpm is num && bpm != 0) send(BpmCommand(_round(bpm.toDouble(), 2)));
      final auto = e.find<PlayerAutoShowLink>();
      if (!((auto?.running ?? false) && auto!.onPlayer)) {
        for (final o in (snap['on'] as List?) ?? const []) {
          final slot = '${(o as Map)['slot']}';
          if (_liveButtonRx.hasMatch(slot) || (extraButtonRx.hasMatch(slot) && _labX.containsKey(slot))) send(SetOnCommand(slot));
        }
      }
      if (snap['bo'] == true) send(const BlackoutCommand(true));
    }
    _setEvent('restart', 'The SX Player stopped by itself and was started again - the lights were dark for a few seconds.');
  }

  /// The status the watchdog saw last (`$script:playSnap` as the watchdog uses it).
  Map<String, Object?>? _seen;

  /// Before ShowXpress closes for the player: remember what it is playing,
  /// so the player carries on with it. Answers the titles.
  Future<List<String>> snap() async {
    _carry = null;
    final auto = e.find<PlayerAutoShowLink>();
    final remote = e.find<PlayerShowXpressLink>();
    if (e.sx.running && !(auto?.running ?? false) && remote != null) {
      final pressed = await remote.pressed();
      if (pressed != null) {
        final titles = <String>[];
        for (final b in pressed) {
          if (RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(b.page) || !titleRx.hasMatch(b.title)) continue;
          if (!titles.contains(b.title)) titles.add(b.title);
        }
        _carry = (at: DateTime.now(), titles: titles);
      }
    }
    return _carry?.titles ?? const [];
  }

  /// Port of `/api/lab/start`.
  Future<Json> startFromScreen({required bool stopNova}) async {
    if (e.sx.running) {
      return {
        'ok': false,
        'sxopen': true,
        'error': 'ShowXpress is open - it has to be closed while the SX Player plays (only one program can use the DMX interface).',
        'out': '',
      };
    }
    if (e.dmx.liveOn) return {'ok': false, 'error': 'Aim live or the colour preview is using the DMX interface. Finish that first.', 'out': ''};
    final Json j;
    try {
      j = playerList(e.show());
    } on ToolError catch (err) {
      return {'ok': false, 'error': err.message.isNotEmpty ? err.message : 'Could not read the show.', 'out': ''};
    }
    labMap = psMap<LabButton>();
    for (final pg in j['pages']! as List) {
      for (final b in (pg as Map)['buttons'] as List) {
        final lb = LabButton.fromList((b as Map).cast<String, Object?>());
        labMap[lb.sec] = lb;
      }
    }
    final windows = !onMac && Platform.isWindows;
    if (stopNova && windows) {
      await _killNova();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final s = await start('${j['show']}');
    if (s['ok'] != true && windows && '${s['error']}'.toLowerCase().contains('was not found') && await _novaRunning()) {
      s['nova'] = true;
      s['error'] =
          'The NovaStar LED-screen software (NovaLCT) is holding the DMX interface. Its USB scanner can be paused while the player runs - NovaLCT starts it again by itself.';
    }
    s['test'] = test;
    final ok = s['ok'] == true;
    // an Auto Show waiting for ShowXpress carries on on the player (same look)
    final auto = e.find<PlayerAutoShowLink>();
    if (ok && (auto?.running ?? false) && !auto!.onPlayer) {
      await auto.restart();
      s['auto'] = true;
    }
    // carry on with what ShowXpress was playing (snapshot from /api/lab/snap, taken just before it closed)
    final carried = <String>[];
    final carry = _carry;
    if (ok && s['auto'] != true && carry != null && DateTime.now().difference(carry.at).inSeconds < 300) {
      for (final t in carry.titles) {
        if (send(TitleOnCommand(t))) carried.add(t);
      }
    }
    s['carried'] = carried;
    if (ok) {
      s['list'] = j; // the window redraws its buttons from this: edits saved in ShowXpress show up on every start
      _carry = null;
      e.find<PlayerShowXpressLink>()?.clearPendingPress(_pendingLabel);
    }
    return s;
  }

  /// A button from the screen: a live.ini one, or one on the player's own pages.
  LabButton? labButton(String sec) => labMap[sec] ?? (extraButtonRx.hasMatch(sec) ? _labX[sec] : null);

  /// Is [b] something the player can be asked to play?
  bool isPlayable(LabButton? b) => b != null && (_liveButtonRx.hasMatch(b.sec) || extraButtonRx.hasMatch(b.sec));

  /// Port of `Sync-PlayerExtras`: the buttons on the player's own pages go to
  /// the player, only the ones that changed, so a playing button isn't
  /// restarted when the layout is saved.
  @override
  void syncExtras() {
    if (!running) return;
    final want = <String, ExtraButton>{};
    final map = psMap<LabButton>();
    for (final c in e.find<PlayerLayoutSource>()?.customPages ?? const <PlayerPageSpec>[]) {
      final g = 1000 + (int.tryParse(c.id.substring(1)) ?? 0);
      for (final b in c.buttons) {
        final path = _playerFilePath(_root, b.file);
        want[b.id] = ExtraButton(
          sec: b.id,
          group: g,
          swap: c.swap,
          fader: b.fader,
          bpm: b.bpm,
          flash: b.flash,
          beats: _round(b.beats, 4),
          path: path,
          title: b.title,
        );
        map[b.id] = LabButton(b.id, b.title, path, path.isEmpty ? 'missing' : (path.toLowerCase().endsWith('.gpj') ? 'gpj' : 'scex'));
      }
    }
    for (final k in _labXSent.keys.toList()) {
      if (!want.containsKey(k)) {
        send(RemoveButtonCommand(k));
        _labXSent.remove(k);
      }
    }
    for (final MapEntry(:key, :value) in want.entries) {
      if (_labXSent[key] != value && send(AddButtonCommand(value))) _labXSent[key] = value;
    }
    _labX = map;
  }
}

/// `Get-PlayerFilePath`: a file of the show a button on the player's own
/// pages can play, as a full path, or '' when it isn't there.
String _playerFilePath(String root, String file) {
  if (root.isEmpty || !_fileRx.hasMatch(file)) return '';
  final c = file.toLowerCase().endsWith('.gpj') ? ['$root/Editor/Generator/projects/$file', '$root/scenes/$file'] : ['$root/scenes/$file'];
  for (final f in c) {
    if (File(f).existsSync()) return p.normalize(File(f).absolute.path);
  }
  return '';
}

/// What `ToString('0.####')` and back does to a number.
double _round(double v, int digits) => double.parse(v.toStringAsFixed(digits));

Future<bool> _novaRunning() async {
  try {
    final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq MarsServerProvider.exe', '/NH']);
    return '${r.stdout}'.toLowerCase().contains('marsserverprovider');
  } on ProcessException {
    return false;
  }
}

/// Pauses NovaLCT's USB scanner, which holds the interface. NovaLCT starts it
/// again by itself.
Future<void> _killNova() async {
  try {
    await Process.run('taskkill', ['/F', '/IM', 'MarsServerProvider.exe']);
  } on ProcessException {
    // not there
  }
}
