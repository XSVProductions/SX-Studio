import 'client.dart';
import 'json.dart';
import 'remote.dart';

/// A few buttons that play together, for a number of bars.
class AutoLook {
  AutoLook({required this.id, required this.name, required this.bars, required this.on, required this.titles});

  factory AutoLook.fromJson(Json j) =>
      AutoLook(id: j.str('id'), name: j.str('name'), bars: j.integer('bars'), on: j.boolean('on'), titles: j.strList('titles'));

  /// 8 lowercase hex digits.
  String id;
  String name;
  int bars;

  /// "In the show". A look that is off is skipped.
  bool on;
  List<String> titles;

  AutoLook copy() => AutoLook(id: id, name: name, bars: bars, on: on, titles: [...titles]);

  Json toJson() => {'id': id, 'name': name, 'bars': bars, 'on': on, 'titles': titles};
}

/// The Auto Show settings, kept in `<show>/auto_show.json`.
class AutoConfig {
  AutoConfig({this.bpm = 124, this.order = 'order', this.stop = 'keep', this.clean = false, List<AutoLook>? looks}) : looks = looks ?? [];

  factory AutoConfig.fromJson(Json j) =>
      AutoConfig(bpm: j.number('bpm'), order: j.str('order'), stop: j.str('stop'), clean: j.boolean('clean'), looks: j.list('looks', AutoLook.fromJson));

  double bpm;

  /// `order` or `shuffle`.
  String order;

  /// What Stop does with the last look: `keep` it playing or turn it `off`.
  String stop;

  /// At start, turn off everything else that is playing.
  bool clean;
  List<AutoLook> looks;

  AutoConfig copy() => AutoConfig(bpm: bpm, order: order, stop: stop, clean: clean, looks: [for (final l in looks) l.copy()]);

  Json toJson() => {
    'bpm': bpm,
    'order': order,
    'stop': stop,
    'clean': clean,
    'looks': [for (final l in looks) l.toJson()],
  };
}

/// A live button the Auto Show can use.
class AutoButton {
  const AutoButton({required this.title, required this.page, required this.dup, required this.reach, required this.swap});

  factory AutoButton.fromJson(Json j) =>
      AutoButton(title: j.str('title'), page: j.str('page'), dup: j.boolean('dup'), reach: j.boolean('reach'), swap: j.boolean('swap'));

  final String title;

  /// Page name.
  final String page;

  /// An earlier button has the same title. ShowXpress only reaches the first.
  final bool dup;

  /// The page can be reached by the remote.
  final bool reach;

  /// The page plays one button at a time.
  final bool swap;

  Json toJson() => {'title': title, 'page': page, 'dup': dup, 'reach': reach, 'swap': swap};
}

/// Where the Auto Show is. Port of the state `sx_remote.ps1 -Action Auto` writes.
class AutoStatus {
  const AutoStatus({
    required this.running,
    this.pid = 0,
    this.lookId = '',
    this.name = '',
    this.next = '',
    this.nextId = '',
    this.bars = 0,
    this.bar = 0,
    this.beat = 0,
    this.msLeft = 0,
    this.bpm = 124,
    this.held = false,
    this.applied = false,
    this.error = '',
    this.missing = const [],
    this.at = '',
    this.changes = 0,
    this.startedAt = '',
    this.target = 'showxpress',
    this.src = '',
  });

  factory AutoStatus.fromJson(Json j) => AutoStatus(
    running: j.boolean('running'),
    pid: j.integer('pid'),
    lookId: j.str('lookId'),
    name: j.str('name'),
    next: j.str('next'),
    nextId: j.str('nextId'),
    bars: j.integer('bars'),
    bar: j.integer('bar'),
    beat: j.integer('beat'),
    msLeft: j.integer('msLeft'),
    bpm: j.number('bpm'),
    held: j.boolean('held'),
    applied: j.boolean('applied'),
    error: j.str('error'),
    missing: j.strList('missing'),
    at: j.str('at'),
    changes: j.integer('changes'),
    startedAt: j.str('startedAt'),
    target: j.str('target'),
    src: j.str('src'),
  );

  final bool running;
  final int pid;

  /// The look playing, and its name.
  final String lookId;
  final String name;

  /// Name and id of the look that comes next.
  final String next;
  final String nextId;

  /// Bars in this look, and the bar and beat (1 to 4) it is on.
  final int bars;
  final int bar;
  final int beat;

  /// Until the next look, or -1 while held.
  final int msLeft;
  final double bpm;
  final bool held;

  /// The look's buttons were pressed.
  final bool applied;
  final String error;

  /// The look's titles that aren't in the show.
  final List<String> missing;

  /// When this status was taken (ISO 8601).
  final String at;

  /// How many times a look was pressed.
  final int changes;
  final String startedAt;

  /// `showxpress`, or `player` when the looks play on the SX Player.
  final String target;

  /// On the player: where the tempo comes from (`tap`, `VirtualDJ`).
  final String src;

  Json toJson() => {
    'running': running,
    'pid': pid,
    'lookId': lookId,
    'name': name,
    'next': next,
    'nextId': nextId,
    'bars': bars,
    'bar': bar,
    'beat': beat,
    'msLeft': msLeft,
    'bpm': bpm,
    'held': held,
    'applied': applied,
    'error': error,
    'missing': missing,
    'at': at,
    'changes': changes,
    'startedAt': startedAt,
    'target': target,
    'src': src,
  };
}

/// What the Auto Show screen loads. Port of `sx_remote.ps1 -Action AutoGet`
/// plus the two keys `/api/auto` adds (`player`, `status`).
class AutoInfo {
  const AutoInfo({
    required this.show,
    required this.config,
    required this.buttons,
    required this.ready,
    required this.open,
    required this.setup,
    this.player = false,
    this.status,
  });

  factory AutoInfo.fromJson(Json j) => AutoInfo(
    show: j.str('show'),
    config: AutoConfig.fromJson(j.obj('config')),
    buttons: j.list('buttons', AutoButton.fromJson),
    ready: j.boolean('ready'),
    open: j.boolean('open'),
    setup: RemoteSetup.fromJson(j.obj('setup')),
    player: j.boolean('player'),
    status: switch (j.objOrNull('status')) {
      final s? => AutoStatus.fromJson(s),
      null => null,
    },
  );

  /// The show folder's name.
  final String show;
  final AutoConfig config;
  final List<AutoButton> buttons;

  /// The ShowXpress remote is on.
  final bool ready;
  final bool open;
  final RemoteSetup setup;

  /// The SX Player is playing, so the looks would play there.
  final bool player;
  final AutoStatus? status;

  Json toJson() => {
    'ok': true,
    'show': show,
    'config': config.toJson(),
    'buttons': [for (final b in buttons) b.toJson()],
    'ready': ready,
    'open': open,
    'setup': setup.toJson(),
    'player': player,
    'status': status?.toJson(),
  };
}

/// What an Auto Show start, stop or command answers.
class AutoAnswer {
  const AutoAnswer({required this.ok, this.error = '', this.status});

  factory AutoAnswer.fromJson(Json j) => AutoAnswer(
    ok: j.boolean('ok'),
    error: j.str('error'),
    status: switch (j.objOrNull('status')) {
      final s? => AutoStatus.fromJson(s),
      null => null,
    },
  );

  final bool ok;
  final String error;
  final AutoStatus? status;

  Json toJson() => {'ok': ok, 'error': error, 'status': status?.toJson()};
}

/// Commands for a playing Auto Show (`/api/auto/cmd`).
enum AutoCmd { next, prev, hold, resume, sync, bpm, go }

extension AutoApi on SxClient {
  Future<AutoInfo> auto() => get('/api/auto', AutoInfo.fromJson);

  /// The Auto Show's status, or null when it never ran.
  Future<AutoStatus?> autoStatus() => get('/api/auto/status', (j) => AutoAnswer.fromJson(j).status);

  /// Saves the settings. On success `extra['config']` holds them as saved.
  Future<ToolResult> autoSave(AutoConfig config) => run('/api/auto/save', {'config': config.toJson()});

  /// Starts the Auto Show, with the look [look] first when given.
  Future<AutoAnswer> autoStart([String look = '']) => _auto(() => run('/api/auto/start', {'look': look}));

  Future<AutoAnswer> autoStop() => _auto(() => run('/api/auto/stop'));

  /// [v] is the BPM for [AutoCmd.bpm] and the look id for [AutoCmd.go].
  Future<AutoAnswer> autoCmd(AutoCmd cmd, [String v = '']) => _auto(() => run('/api/auto/cmd', {'cmd': cmd.name, 'v': v}));

  Future<AutoAnswer> _auto(Future<ToolResult> Function() call) async {
    try {
      final r = await call();
      return AutoAnswer.fromJson(r.toJson());
    } on ApiException catch (e) {
      return AutoAnswer(ok: false, error: e.message);
    }
  }
}
