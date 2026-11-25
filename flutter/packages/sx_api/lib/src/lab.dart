import 'client.dart';
import 'json.dart';
import 'speed.dart';

// SX Player (tab id `lab`). Shapes come from the old server, `repo/src/df_aim_gui.ps1`:
// the `/api/lab...` routes, the SX PLAYER block (Invoke-Handoff, Step-PlayerWatch,
// Set-PlayEvent), `player.ps1 -List` for the board and `[SxPlayer]::Status()` in
// `player.ps1` for the status file the server passes on.

/// What a live button plays: a scene, a movement, or nothing because its file is gone.
enum LabKind {
  scex,
  gpj,
  missing;

  static LabKind parse(String s) => values.firstWhere((k) => k.name == s, orElse: () => missing);
}

/// One button on one of the show's live pages, as `player.ps1 -List` lists it.
class LabButton {
  const LabButton({
    required this.sec,
    required this.title,
    required this.file,
    required this.path,
    required this.kind,
    required this.steps,
    required this.line,
    required this.col,
    required this.color,
    required this.bpm,
    required this.fader,
    required this.key,
    required this.flash,
    required this.beats,
    required this.pad,
  });

  factory LabButton.fromJson(Json j) => LabButton(
    sec: j.str('sec'),
    title: j.str('title'),
    file: j.str('file'),
    path: j.str('path'),
    kind: LabKind.parse(j.str('kind')),
    steps: j.integer('steps'),
    line: j.integer('line'),
    col: j.integer('col'),
    color: j.integer('color'),
    bpm: j.boolean('bpm'),
    fader: j.integer('fader'),
    key: j.str('key'),
    flash: j.boolean('flash'),
    beats: j.number('beats'),
    pad: j.integer('pad'),
  );

  /// live.ini section, for example `page3_button1`. The button's id in every command.
  final String sec;
  final String title;

  /// The scene or movement file name, as live.ini has it.
  final String file;

  /// Full path of [file] on the laptop, or '' when it is missing.
  final String path;
  final LabKind kind;

  /// Step count of a scene, 0 for movements and missing files.
  final int steps;

  /// Row and column on ShowXpress's live screen.
  final int line;
  final int col;

  /// ShowXpress's button color as 0xRRGGBB, or -1 for none.
  final int color;

  /// The button follows the beat (`speed = auto_bpm`).
  final bool bpm;

  /// 0-based master speed fader.
  final int fader;

  /// Keyboard trigger, one letter or digit, or ''.
  final String key;

  /// BPM flash mode (`bpm_trigger = flash_mode`).
  final bool flash;

  /// Steps per beat on a BPM button. 0 when live.ini has no `beats` key: the
  /// old tool's TryParse leaves 0 behind on failure.
  final double beats;

  /// APC mini pad note, or -1.
  final int pad;

  Json toJson() => {
    'sec': sec,
    'title': title,
    'file': file,
    'path': path,
    'kind': kind.name,
    'steps': steps,
    'line': line,
    'col': col,
    'color': color,
    'bpm': bpm,
    'fader': fader,
    'key': key,
    'flash': flash,
    'beats': beats,
    'pad': pad,
  };
}

/// One of the show's live pages.
class LabPage {
  const LabPage({required this.n, required this.name, required this.swap, required this.buttons});

  factory LabPage.fromJson(Json j) => LabPage(n: j.integer('n'), name: j.str('name'), swap: j.boolean('swap'), buttons: j.list('buttons', LabButton.fromJson));

  /// Page number in live.ini.
  final int n;
  final String name;

  /// One at a time: pressing a button releases the others on the page (MOVEMENTS).
  final bool swap;
  final List<LabButton> buttons;

  Json toJson() => {
    'n': n,
    'name': name,
    'swap': swap,
    'buttons': [for (final b in buttons) b.toJson()],
  };
}

/// The board: every live page and button, the master faders, and the scene
/// and movement files the player's own pages can use. `GET /api/lab`, and the
/// `list` key of a successful start.
class LabBoard {
  const LabBoard({required this.show, required this.pages, required this.faders, required this.files});

  factory LabBoard.fromJson(Json j) =>
      LabBoard(show: j.str('show'), pages: j.list('pages', LabPage.fromJson), faders: j.list('faders', MasterFader.fromJson), files: j.strList('files'));

  /// The show folder.
  final String show;
  final List<LabPage> pages;
  final List<MasterFader> faders;

  /// File names in `scenes` and `Editor/Generator/projects`, sorted, no duplicates.
  final List<String> files;

  Json toJson() => {
    'ok': true,
    'show': show,
    'pages': [for (final p in pages) p.toJson()],
    'faders': [for (final f in faders) f.toJson()],
    'files': files,
  };
}

/// One button that is playing, from the player's status.
class LabPlay {
  const LabPlay({required this.slot, required this.step, required this.of, this.mv = false, this.bpm = false});

  factory LabPlay.fromJson(Json j) => LabPlay(slot: j.str('slot'), step: j.integer('step'), of: j.integer('of'), mv: j.boolean('mv'), bpm: j.boolean('bpm'));

  /// The button's section (`page3_button1`, or `x1_b2` on the player's own pages).
  final String slot;

  /// 1-based step now playing, out of [of]. For a movement [of] is its point count.
  final int step;
  final int of;

  /// A movement. The key is left out when false.
  final bool mv;

  /// Plays to the beat. The key is left out when false.
  final bool bpm;

  Json toJson() => {'slot': slot, 'step': step, 'of': of, if (mv) 'mv': true, if (bpm) 'bpm': true};
}

/// A JSON list of numbers. A bare number counts as a one-item list.
List<double> _numbers(Object? v) => switch (v) {
  final List<Object?> l => [
    for (final e in l)
      if (e is num) e.toDouble() else throw FormatException('"fd" should be a list of numbers, got $v'),
  ],
  final num n => [n.toDouble()],
  null => const [],
  _ => throw FormatException('"fd" should be a list of numbers, got $v'),
};

/// The player's own status file, rewritten five times a second and passed on
/// by `/api/lab/status`. Every key is always there.
class LabPlayerStatus {
  const LabPlayerStatus({
    this.bo = false,
    this.on = const [],
    this.err = '',
    this.fd = const [],
    this.midi = '',
    this.led = const {},
    this.bpm = 120,
    this.beat = 0,
    this.src = 'manual',
    this.os2l = '',
    this.os2lPort = 0,
    this.os2lErr = '',
    this.os2lBeats = 0,
    this.iface = 'ok',
    this.reconn = 0,
    this.warn = const [],
  });

  factory LabPlayerStatus.fromJson(Json j) => LabPlayerStatus(
    bo: j.boolean('bo'),
    on: j.list('on', LabPlay.fromJson),
    err: j.str('err'),
    fd: _numbers(j['fd']),
    midi: j.str('midi'),
    led: {
      for (final e in j.obj('led').entries)
        if (e.value case final num v) e.key: v.round(),
    },
    bpm: j.number('bpm'),
    beat: j.number('beat'),
    src: j.str('src'),
    os2l: j.str('os2l'),
    os2lPort: j.integer('os2lPort'),
    os2lErr: j.str('os2lErr'),
    os2lBeats: j.integer('os2lBeats'),
    iface: j.str('iface'),
    reconn: j.integer('reconn'),
    warn: j.strList('warn'),
  );

  /// Blackout is on.
  final bool bo;
  final List<LabPlay> on;

  /// The last file the player could not play, or ''.
  final String err;

  /// The 16 speed faders, 0 to 1. 0.5 is normal speed.
  final List<double> fd;

  /// The APC mini's name, or '' when none is connected.
  final String midi;

  /// Pad lights sent to the APC: note (as text) to velocity.
  final Map<String, int> led;
  final double bpm;

  /// Beats counted since the player started, with a fraction.
  final double beat;

  /// Where the BPM came from: `manual`, `tap` or `VirtualDJ`.
  final String src;

  /// VirtualDJ's address while it is connected over OS2L, or ''.
  final String os2l;

  /// The OS2L port, or 0 when the link is off.
  final int os2lPort;
  final String os2lErr;
  final int os2lBeats;

  /// `ok`, or `lost` while the DMX interface is unplugged.
  final String iface;

  /// How many times the interface came back.
  final int reconn;

  /// Show check problems found at start.
  final List<String> warn;

  bool get lost => iface == 'lost';

  Json toJson() => {
    'ok': true,
    'bo': bo,
    'on': [for (final p in on) p.toJson()],
    'err': err,
    'fd': fd,
    'midi': midi,
    'led': led,
    'bpm': bpm,
    'beat': beat,
    'src': src,
    'os2l': os2l,
    'os2lPort': os2lPort,
    'os2lErr': os2lErr,
    'os2lBeats': os2lBeats,
    'iface': iface,
    'reconn': reconn,
    'warn': warn,
  };
}

/// What happened to the player by itself (Set-PlayEvent).
enum LabEventKind {
  /// Stopped and handed over to ShowXpress, by the user or because ShowXpress was opened.
  handoff,

  /// The DMX interface was unplugged.
  lost,

  /// The DMX interface is back.
  back,

  /// The player stopped and could not be started again.
  gone,

  /// The player stopped by itself and was started again.
  restart,
}

/// The latest player event. The screen shows it once, when [n] changes.
class LabEvent {
  const LabEvent({required this.n, required this.kind, required this.text, required this.at});

  factory LabEvent.fromJson(Json j) => LabEvent(
    n: j.integer('n'),
    kind: LabEventKind.values.asNameMap()[j.str('kind')] ?? (throw FormatException('Unknown player event "${j.str('kind')}"')),
    text: j.str('text'),
    at: j.str('at'),
  );

  /// Counts up from 1 for every event since the server started.
  final int n;
  final LabEventKind kind;
  final String text;

  /// When, as `(Get-Date).ToString('o')`.
  final String at;

  Json toJson() => {'n': n, 'kind': kind.name, 'text': text, 'at': at};
}

/// `GET /api/lab/status`, polled while the screen is open.
class LabStatus {
  const LabStatus({required this.running, this.status, this.event});

  factory LabStatus.fromJson(Json j) => LabStatus(
    running: j.boolean('running'),
    status: switch (j.objOrNull('status')) {
      final s? => LabPlayerStatus.fromJson(s),
      null => null,
    },
    event: switch (j.objOrNull('event')) {
      final e? => LabEvent.fromJson(e),
      null => null,
    },
  );

  final bool running;

  /// Null while the player is stopped, and for a moment after it starts
  /// (before it has written its first status file).
  final LabPlayerStatus? status;

  /// Null until the first event since the server started.
  final LabEvent? event;

  Json toJson() => {'ok': true, 'running': running, 'status': status?.toJson(), 'event': event?.toJson()};
}

/// The answer to `/api/lab/start`.
///
/// On success: `ok`, `iface`, `out`, `error`, `test`, `carried`, `list` and,
/// when an Auto Show moved over, `auto`. On failure: `ok`, `error`, `out`, and
/// depending on the reason `sxopen` (ShowXpress is open, refused before
/// anything ran), `nova` (NovaLCT holds the interface), `test` and `carried`.
class LabStart {
  const LabStart({
    required this.ok,
    this.error = '',
    this.out = '',
    this.iface = '',
    this.sxopen = false,
    this.nova = false,
    this.test = false,
    this.auto = false,
    this.carried = const [],
    this.list,
  });

  factory LabStart.fromJson(Json j) => LabStart(
    ok: j.boolean('ok'),
    error: j.str('error'),
    out: j.str('out'),
    iface: j.str('iface'),
    sxopen: j.boolean('sxopen'),
    nova: j.boolean('nova'),
    test: j.boolean('test'),
    auto: j.boolean('auto'),
    carried: j.strList('carried'),
    list: switch (j.objOrNull('list')) {
      final l? when l.boolean('ok') => LabBoard.fromJson(l),
      _ => null,
    },
  );

  final bool ok;
  final String error;
  final String out;

  /// The interface's name, from the player's first line (`OK <name>`).
  final String iface;
  final bool sxopen;
  final bool nova;

  /// The server runs on a test copy: no real interface, frames go to `_dmx_frame.txt`.
  final bool test;

  /// An Auto Show that was waiting for ShowXpress moved over to the player.
  final bool auto;

  /// Titles the player carried on with from ShowXpress (see [LabApi.labSnap]).
  final List<String> carried;

  /// The board as read on this start, so edits saved in ShowXpress show up.
  final LabBoard? list;

  Json toJson() => {
    'ok': ok,
    'error': error,
    'out': out,
    if (iface.isNotEmpty) 'iface': iface,
    if (sxopen) 'sxopen': true,
    if (nova) 'nova': true,
    'test': test,
    if (auto) 'auto': true,
    'carried': carried,
    if (list != null) 'list': list!.toJson(),
  };
}

/// The answer to `/api/lab/handoff`. When the player wasn't running the
/// server leaves out `out` and `auto`.
class LabHandoff {
  const LabHandoff({required this.ok, this.error = '', this.out = '', this.titles = const [], this.auto = false, this.test = false});

  factory LabHandoff.fromJson(Json j) =>
      LabHandoff(ok: j.boolean('ok'), error: j.str('error'), out: j.str('out'), titles: j.strList('titles'), auto: j.boolean('auto'), test: j.boolean('test'));

  /// ShowXpress started. False means the player stopped but ShowXpress didn't open.
  final bool ok;
  final String error;
  final String out;

  /// What ShowXpress presses once it is ready.
  final List<String> titles;

  /// The Auto Show moved over to ShowXpress.
  final bool auto;
  final bool test;

  Json toJson() => {'ok': ok, 'error': error, 'out': out, 'titles': titles, 'auto': auto, 'test': test};
}

/// The answer to `/api/lab/cmd`.
class LabCmdResult {
  const LabCmdResult({required this.ok, this.error = '', this.gone = false});

  factory LabCmdResult.fromJson(Json j) => LabCmdResult(ok: j.boolean('ok'), error: j.str('error'), gone: j.boolean('gone'));

  final bool ok;
  final String error;

  /// The player is not running any more.
  final bool gone;

  Json toJson() => {'ok': ok, if (gone) 'gone': true, if (!ok) 'error': error};
}

/// A command for the running player: the body of `/api/lab/cmd`.
class LabCmd {
  const LabCmd._(this._body);

  /// Toggle a button, as a tap on it.
  LabCmd.press(String sec) : this._({'cmd': 'press', 'sec': sec});

  /// Turn a button on, or off, without toggling.
  LabCmd.on(String sec) : this._({'cmd': 'on', 'sec': sec});
  LabCmd.off(String sec) : this._({'cmd': 'off', 'sec': sec});

  /// Speed fader [k] (0 to 15) to [v] (0 to 1).
  LabCmd.fader(int k, double v) : this._({'cmd': 'fader', 'k': k, 'v': v});

  /// The BPM, 40 to 250.
  LabCmd.bpm(double v) : this._({'cmd': 'bpm', 'v': v});

  /// A keyboard trigger, one letter or digit.
  LabCmd.key(String key) : this._({'cmd': 'key', 'key': key});

  static const tap = LabCmd._({'cmd': 'tap'});

  /// Now is beat 1.
  static const sync = LabCmd._({'cmd': 'sync'});

  /// Release every button.
  static const allOff = LabCmd._({'cmd': 'alloff'});

  /// Blackout on or off.
  LabCmd.blackout(bool on) : this._({'cmd': 'bo', 'on': on});

  final Json _body;

  Json toJson() => _body;
}

/// A button on one of the player's own pages (settings `playerLayout.custom`).
/// It plays a show file with its own settings and has no pad or key.
class PlayerButton {
  const PlayerButton({
    required this.id,
    required this.title,
    required this.file,
    this.fader = 0,
    this.bpm = false,
    this.flash = false,
    this.beats = 1,
    this.color = -1,
  });

  factory PlayerButton.fromJson(Json j) => PlayerButton(
    id: j.str('id'),
    title: j.str('title'),
    file: j.str('file'),
    fader: j.integer('fader'),
    bpm: j.boolean('bpm'),
    flash: j.boolean('flash'),
    beats: j.number('beats'),
    color: j.integer('color'),
  );

  /// `x<page>_b<n>`, the button's section in player commands.
  final String id;
  final String title;
  final String file;
  final int fader;
  final bool bpm;
  final bool flash;
  final double beats;
  final int color;

  Json toJson() => {'id': id, 'title': title, 'file': file, 'fader': fader, 'bpm': bpm, 'flash': flash, 'beats': beats, 'color': color};
}

/// One of the player's own pages. Only in SX Studio's settings, never in the show.
class PlayerPage {
  const PlayerPage({required this.id, required this.name, this.swap = false, this.buttons = const []});

  factory PlayerPage.fromJson(Json j) =>
      PlayerPage(id: j.str('id'), name: j.str('name'), swap: j.boolean('swap'), buttons: j.list('buttons', PlayerButton.fromJson));

  /// `x<n>`.
  final String id;
  final String name;

  /// One at a time, like a MOVEMENTS page.
  final bool swap;
  final List<PlayerButton> buttons;

  PlayerPage copyWith({String? name, bool? swap, List<PlayerButton>? buttons}) =>
      PlayerPage(id: id, name: name ?? this.name, swap: swap ?? this.swap, buttons: buttons ?? this.buttons);

  Json toJson() => {
    'id': id,
    'name': name,
    'swap': swap,
    'buttons': [for (final b in buttons) b.toJson()],
  };
}

/// How the SX Player screen arranges the board (settings `playerLayout`,
/// Get-PlayerLayout). Page ids are the show's page numbers as text, or a
/// player page's `x<n>`.
class PlayerLayout {
  const PlayerLayout({this.pages = const [], this.order = const {}, this.hidden = const [], this.collapsed = const [], this.custom = const []});

  factory PlayerLayout.fromJson(Json j) => PlayerLayout(
    pages: j.strList('pages'),
    order: {for (final e in j.obj('order').entries) e.key: j.obj('order').strList(e.key)},
    hidden: j.strList('hidden'),
    collapsed: j.strList('collapsed'),
    custom: j.list('custom', PlayerPage.fromJson),
  );

  /// Page order. Pages not in it follow, show pages by number, then player pages.
  final List<String> pages;

  /// Button order per show page, by section. Buttons not in it go last.
  final Map<String, List<String>> order;
  final List<String> hidden;
  final List<String> collapsed;
  final List<PlayerPage> custom;

  PlayerLayout copyWith({List<String>? pages, Map<String, List<String>>? order, List<String>? hidden, List<String>? collapsed, List<PlayerPage>? custom}) =>
      PlayerLayout(
        pages: pages ?? this.pages,
        order: order ?? this.order,
        hidden: hidden ?? this.hidden,
        collapsed: collapsed ?? this.collapsed,
        custom: custom ?? this.custom,
      );

  Json toJson() => {
    'pages': pages,
    'order': order,
    'hidden': hidden,
    'collapsed': collapsed,
    'custom': [for (final c in custom) c.toJson()],
  };
}

extension LabApi on SxClient {
  /// The board. A show that can't be read throws with the reason.
  Future<LabBoard> lab() => get('/api/lab', LabBoard.fromJson);

  Future<LabStatus> labStatus() => get('/api/lab/status', LabStatus.fromJson);

  /// Before ShowXpress closes for the player: remembers what it plays, so the
  /// player carries on with it. Returns those titles.
  Future<List<String>> labSnap() => post('/api/lab/snap', const {}, (j) => j.strList('titles'));

  /// Starts the player. [stopNova] first pauses NovaLCT's USB scanner.
  Future<LabStart> labStart({bool stopNova = false}) async => LabStart.fromJson((await run('/api/lab/start', {if (stopNova) 'stopNova': true})).toJson());

  Future<LabCmdResult> labCmd(LabCmd c) async => LabCmdResult.fromJson((await run('/api/lab/cmd', c.toJson())).toJson());

  /// Stops the player and opens ShowXpress, which carries on with what played.
  Future<LabHandoff> labHandoff() async => LabHandoff.fromJson((await run('/api/lab/handoff')).toJson());

  /// Stops the player. The lights go out.
  Future<ToolResult> labStop() => run('/api/lab/stop');

  /// The layout from `GET /api/settings`.
  Future<PlayerLayout> playerLayout() => get('/api/settings', (j) => PlayerLayout.fromJson(j.obj('settings').obj('playerLayout')));

  /// Saves the layout. Returns it as the server cleaned it up, or null when
  /// the server said no. Throws when the engine can't be reached.
  Future<PlayerLayout?> savePlayerLayout(PlayerLayout l) async {
    final r = await run('/api/settings/set', {'playerLayout': l.toJson()});
    return r.ok ? PlayerLayout.fromJson(r.extra.obj('settings').obj('playerLayout')) : null;
  }
}

/// The player's "close ShowXpress first" step, the same request the old
/// page's sxCloseLive sends. It belongs to the status area and is here until
/// that area offers it.
extension LabSxApi on SxClient {
  /// Closes ShowXpress for a program that needs the interface: the queue must
  /// not open it again meanwhile (`/api/sx/close` with `live`).
  Future<ToolResult> sxCloseForDmx() => run('/api/sx/close', {'live': true});
}
