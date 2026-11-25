import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../sx_control.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'lab_board.dart';
import 'lab_dialogs.dart';
import 'lab_live.dart';

/// Debug only: a board and status the screen draws instead of asking the
/// engine, for looking at the screen before the player routes exist. See
/// `lab_fixture_main.dart`. The tab never passes one.
class LabFixture {
  const LabFixture({required this.board, this.layout = const PlayerLayout(), this.status = const LabStatus(running: false)});

  final LabBoard board;
  final PlayerLayout layout;
  final LabStatus status;
}

/// SX Player: plays the show without ShowXpress. A live board of the show's
/// pages and the player's own, speed faders, tempo, blackout, start, stop
/// and hand-over to ShowXpress. Ports the old page's Lab section.
class LabScreen extends StatefulWidget {
  const LabScreen(BuildContext _, {super.key, this.fixture});

  final LabFixture? fixture;

  @override
  State<LabScreen> createState() => _LabScreenState();
}

/// A tap the screen already shows before the engine confirms it.
///
/// It goes when a status agrees. When the engine disagrees, the second
/// status polled after the command was answered wins: the player rewrites
/// its status file five times a second, so the first one can be older than
/// the command.
class _Pending {
  _Pending(this.on);

  final bool on;

  /// The last poll started when the command was answered, or null before.
  int? ackPoll;

  /// Statuses seen from polls started after that.
  var seen = 0;

  /// Whether this status settles it: agrees, or is the second one after the answer.
  bool settledBy(bool actual, int poll) {
    if (actual == on) return true;
    if (ackPoll case final a? when poll > a) seen++;
    return seen >= 2;
  }
}

class _LabScreenState extends State<LabScreen> {
  late final AppState _app = AppScope.read(context);
  SxClient get _client => _app.client;

  LabBoard? _board;
  var _boardError = '';
  var _loaded = false;
  var _lay = const PlayerLayout();

  var _running = false;
  LabPlayerStatus? _st;

  /// Bumped on start, stop and hand-over, so a poll sent before doesn't undo them (LBgen).
  var _gen = 0;

  /// The last event shown, null until the first poll has seen one (LBev).
  int? _ev;
  var _evSeen = false;

  /// The message under the controls (LBerr).
  Note? _err;
  var _lastPlayErr = '';
  var _reopen = false;

  /// A phone or tablet runs this screen (the old PH, from `/api/settings`).
  /// ShowXpress is the laptop's, so the phone doesn't offer to reopen it.
  var _phone = false;
  var _test = false;
  var _arranging = false;
  var _gigHelp = false;
  String? _busy;

  Timer? _poll;
  var _visible = false;

  /// Counts polls, so a tap can tell which statuses came after its answer.
  var _pollSeq = 0;

  final _live = LabLive();
  final _bpmInput = TextEditingController();
  final _bpmFocus = FocusNode();
  final _pending = <String, _Pending>{};
  _Pending? _boPending;
  final _fdTouched = <int, DateTime>{};
  final _fdWant = <int, int>{};
  final _fdTimer = <int, Timer>{};

  /// A drag in Arrange: the page and its tiles in their order so far.
  ({String page, List<LabTile> tiles, List<String> start})? _drag;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    final f = widget.fixture;
    if (f != null) {
      _board = f.board;
      _lay = f.layout;
      _running = f.status.running;
      _st = f.status.status;
      _loaded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _draw());
      return;
    }
    _made = _app.madeScenes.length;
    _app.addListener(_onApp);
    _onApp();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final t in _fdTimer.values) {
      t.cancel();
    }
    HardwareKeyboard.instance.removeHandler(_onKey);
    _app.removeListener(_onApp);
    _live.dispose();
    _bpmInput.dispose();
    _bpmFocus.dispose();
    super.dispose();
  }

  /// Polls only while the tab is on show. Showing it again loads the board
  /// the first time and polls straight away after that.
  void _onApp() {
    _takeMade();
    final v = _app.tab == 'lab';
    if (v == _visible) return;
    _visible = v;
    if (!v) {
      _poll?.cancel();
      _poll = null;
    } else if (_board == null && !_loaded) {
      _load();
    } else {
      _pollNow();
    }
  }

  /// How many looks the Looks tab had made when the board last took them.
  var _made = 0;

  /// A look made on the Looks tab is a scene file the player's own pages can
  /// use now (old `LB.files.push`).
  void _takeMade() {
    final made = _app.madeScenes;
    if (made.length == _made) return;
    final add = made.sublist(_made);
    _made = made.length;
    final b = _board;
    if (b == null) return;
    setState(() => _board = LabBoard(show: b.show, pages: b.pages, faders: b.faders, files: [...b.files, ...add]));
  }

  static Note _plain(String t) => (text: t, tone: Tone.dim);
  static Note _amber(String t) => (text: t, tone: Tone.amber);

  // ---- loading and polling

  /// Reads the board, the layout and the status (loadLab).
  Future<void> _load() async {
    setState(() => _loaded = false);
    try {
      _board = await _client.lab();
      _boardError = '';
    } on ApiException catch (e) {
      _board = null;
      _boardError = e.message;
    }
    try {
      final info = await _client.settings();
      _lay = info.settings.playerLayout;
      _phone = info.phone;
    } on ApiException {
      // Keep the layout we have.
    }
    try {
      final s = await _client.labStatus();
      _running = s.running;
      _st = s.status;
    } on ApiException {
      // The poll tries again.
    } on FormatException {
      // Same.
    }
    if (!mounted) return;
    setState(() => _loaded = true);
    _draw();
    _pollNow();
  }

  void _schedule(Duration d) {
    _poll?.cancel();
    _poll = (_visible && widget.fixture == null) ? Timer(d, _pollNow) : null;
  }

  /// One status poll (labPoll). Every 400 ms while the player runs, as the
  /// old page did, and every 2 s while it doesn't.
  Future<void> _pollNow() async {
    _poll?.cancel();
    _poll = null;
    if (!_visible || widget.fixture != null) return;
    final g = _gen;
    final was = _running;
    final seq = ++_pollSeq;
    LabStatus? r;
    try {
      r = await _client.labStatus();
    } on ApiException {
      r = null;
    } on FormatException {
      r = null;
    }
    if (!mounted) return;
    if (r != null && g == _gen) {
      _running = r.running;
      _st = r.status;
      final before = _ev;
      _event(r.event);
      if (was != _running) {
        if (was && _ev == before) _err = _amber('The player stopped. SX Studio lost it.');
        setState(() {});
      }
      _draw(poll: seq);
    }
    if (_poll == null) _schedule(Duration(milliseconds: _running ? 400 : 2000));
  }

  /// Shows a new player event once (lbEvent). The first one seen only sets the mark.
  void _event(LabEvent? e) {
    if (e == null) return;
    if (!_evSeen) {
      _evSeen = true;
      _ev = e.n;
      return;
    }
    if (e.n == _ev) return;
    _ev = e.n;
    final n = (
      text: e.text,
      tone: switch (e.kind) {
        LabEventKind.back => Tone.green,
        LabEventKind.lost || LabEventKind.gone => Tone.red,
        _ => Tone.amber,
      },
    );
    _toast(n);
    if (e.kind == LabEventKind.handoff || e.kind == LabEventKind.gone || e.kind == LabEventKind.restart) _err = n;
  }

  /// Puts the latest status on screen (drawLab). Only the notifiers whose
  /// value changed rebuild anything.
  ///
  /// [poll] is the poll whose status this is, or null for a redraw.
  void _draw({int? poll}) {
    final b = _board;
    if (b == null || !mounted) return;
    final st = _running ? _st : null;
    final on = {for (final p in st?.on ?? const <LabPlay>[]) p.slot: p};
    final now = DateTime.now();
    if (poll != null && st != null) {
      _pending.removeWhere((sec, p) => p.settledBy(on.containsKey(sec), poll));
      if (_boPending?.settledBy(st.bo, poll) ?? false) _boPending = null;
    }
    for (final page in placedPages(b, _lay, arranging: true)) {
      var playing = 0;
      for (final t in page.tiles) {
        final p = _pending[t.sec];
        final x = on[t.sec];
        final isOn = p?.on ?? x != null;
        if (isOn) playing++;
        _live.tile(t).value = (on: isOn, text: isOn ? (x == null ? 'on' : playText(x)) : t.label);
      }
      _live.pageOn(page.page.id).value = page.collapsed ? playing : 0;
    }

    _live.bo.value = _boPending?.on ?? st?.bo ?? false;

    if (st != null) {
      for (final (k, v) in st.fd.indexed) {
        final t = _fdTouched[k];
        if (t != null && now.difference(t).inMilliseconds < 1500) continue;
        final n = (v * 127).round();
        if (_live.fader(k).value.$1 != n) _live.fader(k).value = (n, faderText(v));
      }
      _live.midi.value = st.midi.isNotEmpty
          ? (text: '${st.midi} connected. Pads, pad lights and faders work.', dot: Tone.green, hollow: false)
          : _test
          ? (text: 'Test copy: no MIDI (the APC is left alone).', dot: null, hollow: false)
          : (text: 'No APC mini found. Plug it in, then stop and start the player.', dot: Tone.amber, hollow: false);
      _drawTempo(st, now);
    }

    final playErr = st != null && st.err.isNotEmpty ? "Couldn't play ${st.err}" : '';
    if (playErr.isNotEmpty && playErr != _lastPlayErr) _toast((text: playErr, tone: Tone.red));
    _lastPlayErr = playErr;
    _live.lost.value = st?.lost ?? false;
    _live.warn.value = (st?.warn ?? const []).join('\n');
    _live.msg.value = playErr.isNotEmpty ? (text: playErr, tone: Tone.red) : _err;
  }

  /// The tempo card's part of [_draw] (lbBpmDraw).
  void _drawTempo(LabPlayerStatus st, DateTime now) {
    final c = _live.clock.value;
    final keep = c.bpm == st.bpm && (beatAt(c, now) - st.beat).abs() < .6;
    if (!keep) _live.clock.value = (bpm: st.bpm, beat: st.beat, at: now);
    final bpm = _oneDecimal(st.bpm);
    _live.tempo.value = (
      bpm,
      switch (st.src) {
        'VirtualDJ' => 'from VirtualDJ',
        'tap' => 'tapped',
        _ => 'set by hand',
      },
    );
    if (!_bpmFocus.hasFocus && _bpmInput.text != bpm) _bpmInput.text = bpm;
    _live.os2l.value = st.os2l.isNotEmpty
        ? (text: 'VirtualDJ is connected (${st.os2l}). The beat follows the music.', dot: Tone.green, hollow: false)
        : st.os2lPort != 0
        ? (_test
              ? (text: 'Test copy: VirtualDJ link on test port ${st.os2lPort} (not announced).', dot: null, hollow: false)
              : (
                  text:
                      'Waiting for VirtualDJ (OS2L, port ${st.os2lPort}). With OS2L on in VirtualDJ it finds SX Studio by itself, on this computer or another one on the same Wi-Fi.',
                  dot: Tone.dim,
                  hollow: true,
                ))
        : (
            text: "VirtualDJ link off${st.os2lErr.isNotEmpty ? ': ${st.os2lErr}.' : " (OS2L is turned off in ShowXpress's settings)."}",
            dot: Tone.amber,
            hollow: false,
          );
  }

  /// 120 for 120.0, 123.5 for 123.46: JavaScript's `String(Math.round(x*10)/10)`.
  static String _oneDecimal(double x) {
    final r = (x * 10).round() / 10;
    return r == r.truncateToDouble() ? '${r.toInt()}' : '$r';
  }

  /// The old page's `.lbtoast`, for four seconds.
  void _toast(Note n) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          backgroundColor: Sx.card,
          width: math.min(520, MediaQuery.sizeOf(context).width - 24),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Sx.line2),
          ),
          content: Text(n.text, style: TextStyle(color: n.tone == Tone.dim ? Sx.text : n.tone.color, fontSize: 13.5)),
        ),
      );
  }

  void _setBusy(String? text) {
    if (mounted) setState(() => _busy = text);
  }

  // ---- commands

  /// Sends one command (lbCmd). A [quiet] command that works changes nothing
  /// on screen; any other answer redraws and polls soon.
  Future<LabCmdResult> _cmd(LabCmd c, {bool quiet = false, void Function(LabCmdResult r)? settle}) async {
    LabCmdResult r;
    try {
      r = await _client.labCmd(c);
    } on ApiException {
      r = const LabCmdResult(ok: false, error: 'Lost connection to SX Studio.');
    }
    if (!mounted) return r;
    settle?.call(r);
    if (quiet && r.ok) return r;
    if (!r.ok) {
      _err = _amber(r.error);
      _toast(_err!);
      if (r.gone) {
        _gen++;
        _running = false;
        _st = null;
        setState(() {});
        _draw();
        return r;
      }
    }
    _draw();
    _schedule(const Duration(milliseconds: 120));
    return r;
  }

  /// Shows [secs] as on or off straight away, then sends [c]. See [_Pending].
  Future<void> _optimistic(Map<String, bool> secs, LabCmd c) async {
    final mine = {for (final e in secs.entries) e.key: _Pending(e.value)};
    _pending.addAll(mine);
    _draw();
    await _cmd(
      c,
      settle: (r) {
        for (final MapEntry(key: s, value: p) in mine.entries) {
          if (!identical(_pending[s], p)) continue;
          if (r.ok) {
            p.ackPoll = _pollSeq;
          } else {
            _pending.remove(s);
          }
        }
      },
    );
  }

  /// A tap on a tile (the old page's click handler).
  void _press(LabTile t) {
    if (_arranging) return;
    _err = null;
    if (t.missing) {
      _err = _amber('${t.title}: its file is missing.');
      _toast(_err!);
      _draw();
      return;
    }
    if (!_running) {
      _go(first: t.sec);
      return;
    }
    final on = _live.tile(t).value.on;
    final page = allPages(_board!, _lay).where((p) => p.tiles.any((x) => x.sec == t.sec)).firstOrNull;
    _optimistic({
      if (!on && page != null && page.swap)
        for (final x in page.tiles)
          if (x.sec != t.sec) x.sec: false,
      t.sec: !on,
    }, LabCmd.press(t.sec));
  }

  void _releaseAll() => _optimistic({
    for (final p in allPages(_board!, _lay))
      for (final t in p.tiles)
        if (_live.tile(t).value.on) t.sec: false,
  }, LabCmd.allOff);

  void _blackout() {
    final p = _boPending = _Pending(!_live.bo.value);
    _live.bo.value = p.on;
    _cmd(
      LabCmd.blackout(p.on),
      settle: (r) {
        if (!identical(_boPending, p)) return;
        if (r.ok) {
          p.ackPoll = _pollSeq;
        } else {
          _boPending = null;
        }
      },
    );
  }

  /// A fader moved. Sends at most one value per fader every 60 ms, the latest.
  void _moveFader(int k, int pos) {
    _fdTouched[k] = DateTime.now();
    _fdWant[k] = pos;
    _live.fader(k).value = (pos, faderText(pos / 127));
    _fdTimer[k] ??= Timer(const Duration(milliseconds: 60), () {
      _fdTimer.remove(k);
      if (mounted) _cmd(LabCmd.fader(k, _fdWant[k]! / 127), quiet: true);
    });
  }

  void _setBpm(double v) {
    v = ((v * 10).round() / 10).clamp(40, 250).toDouble();
    _bpmInput.text = _oneDecimal(v);
    _cmd(LabCmd.bpm(v), quiet: true);
  }

  void _tap() {
    final c = _live.clock.value;
    final now = DateTime.now();
    _live.clock.value = (bpm: c.bpm, beat: beatAt(c, now).roundToDouble(), at: now);
    _cmd(LabCmd.tap, quiet: true);
  }

  /// A key on the laptop's keyboard plays the button with that trigger
  /// while the player runs, unless a text field has the keyboard.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_visible || !_running || _busy != null) return false;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isAltPressed || kb.isMetaPressed) return false;
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final k = (e.character ?? '').toLowerCase();
    if (!RegExp(r'^[a-z0-9]$').hasMatch(k)) return false;
    if (!(_board?.pages.any((p) => p.buttons.any((b) => b.key.toLowerCase() == k)) ?? false)) return false;
    _cmd(LabCmd.key(k));
    return true;
  }

  // ---- start, stop, hand over

  /// Closes ShowXpress first when it is open (the old page's sxCloseLive).
  Future<({bool go, bool reo})> _closeSx(List<String> carry) async {
    const no = (go: false, reo: false);
    if (!_app.sxOpen) return (go: true, reo: false);
    final ok = await askUser(
      context,
      'Close ShowXpress to start the player?',
      'Only one program can use the DMX interface, so ShowXpress closes while the SX Player runs. Save your show first if you changed anything. If ShowXpress asks, answer it there.'
          '${carry.isEmpty ? '' : '\n\nThe player carries on with what ShowXpress is playing now: ${carry.join(', ')}.'}'
          '\n\nIt can open again when you stop, or straight away with Hand over to ShowXpress.',
      'Close and start',
    );
    if (!ok || !mounted) return no;
    ToolResult r;
    try {
      r = await _client.sxClose(live: true);
    } on ApiException {
      r = const ToolResult.failed('Lost connection.');
    }
    if (!mounted) return no;
    if (!r.ok) {
      await showFailure(context, r.error, out: r.out);
      return no;
    }
    _setBusy('Waiting for ShowXpress to close… (save it if it asks)');
    final t0 = DateTime.now();
    var open = true;
    while (DateTime.now().difference(t0).inSeconds < 120) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        open = (await _client.status()).open;
      } on ApiException {
        // Ask again next second.
      }
      if (!open || !mounted) break;
    }
    if (!mounted) return no;
    if (open) {
      _setBusy(null);
      try {
        await _client.liveStop();
      } on ApiException {
        // Nothing more to do.
      }
      if (mounted) await showFailure(context, 'ShowXpress is still open. Close it (save if it asks), then press Start the player again.');
      return no;
    }
    _setBusy('ShowXpress closed. Waiting for it to let go of the interface…');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    return (go: true, reo: true);
  }

  Future<LabStart> _start({bool stopNova = false}) async {
    try {
      return await _client.labStart(stopNova: stopNova);
    } on ApiException {
      return const LabStart(ok: false, error: 'Lost connection.');
    }
  }

  /// Starts the player, and plays [first] when a tile started it (lbGo).
  Future<void> _go({String? first}) async {
    if (_running || _busy != null) return;
    // The old page checked its own LV, CP, SEP, MVP and LKP. Here those are
    // other screens, and all of them hold the engine's live output.
    await _app.refresh();
    if (!mounted) return;
    if (_app.status?.live ?? false) {
      _toast(_amber('Aim live, the colour preview or an editor or Looks preview is using the DMX interface. Finish that first.'));
      return;
    }
    var carry = const <String>[];
    if (_app.sxOpen) {
      try {
        carry = await _client.labSnap();
      } on ApiException {
        // Start without carrying anything on.
      }
    }
    if (!mounted) return;
    final c = await _closeSx(carry);
    if (!c.go || !mounted) return;
    _setBusy('Connecting to the DMX interface…');
    var r = await _start();
    _setBusy(null);
    if (!mounted) return;
    if (!r.ok &&
        r.nova &&
        await askUser(
          context,
          'NovaStar is using the DMX interface',
          'The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while the player runs? NovaLCT starts it again by itself. Your LED screens are not touched.',
          'Pause it and continue',
        )) {
      _setBusy('Pausing NovaStar and connecting…');
      r = await _start(stopNova: true);
      _setBusy(null);
    }
    if (!mounted) return;
    if (!r.ok) {
      final more = c.reo ? ' ShowXpress is closed now. Press Launch ShowXpress at the top to open it again.' : '';
      await showFailure(context, '${r.error}$more', out: r.out);
      return;
    }
    _gen++;
    _reopen = c.reo;
    _test = r.test;
    _running = true;
    _st = null;
    _boPending = null;
    _pending.clear();
    var msg = r.test
        ? 'Test copy: no real interface. The output goes to _dmx_frame.txt.'
        : 'Playing on ${r.iface.isEmpty ? 'the DMX interface' : r.iface}. Tap a button to start or stop it.';
    if (r.list != null) {
      _board = r.list;
    } else if (_board == null || _board!.pages.every((p) => p.buttons.isEmpty)) {
      await _load();
    }
    if (r.carried.isNotEmpty) msg += ' Carried on from ShowXpress: ${r.carried.join(', ')}.';
    _err = _plain(msg);
    if (!mounted) return;
    setState(() {});
    _draw();
    unawaited(_app.refresh());
    final b = _board;
    final t = first == null || b == null ? null : allPages(b, _lay).expand((p) => p.tiles).where((x) => x.sec == first).firstOrNull;
    if (t != null && !r.carried.contains(t.title)) await _optimistic({t.sec: true}, LabCmd.press(t.sec));
    _pollNow();
  }

  bool get _autoRunning => _app.status?.auto?.running ?? false;

  /// Stops the player (lbStop). Asks first while something plays.
  Future<void> _stop() async {
    final reo = !_phone && _reopen;
    final st = _st;
    final autoHere = _autoRunning && _app.status?.auto?.target == 'player';
    if ((st != null && st.on.isNotEmpty) || autoHere) {
      final ok = await askUser(
        context,
        'Stop the player?',
        'The lights go out.${reo ? ' ShowXpress opens again.' : ''}\n\nTo keep the show going, use Hand over to ShowXpress instead.',
        'Stop the player',
      );
      if (!ok) return;
    }
    _gen++;
    _setBusy('Stopping the player…');
    try {
      await _client.labStop();
    } on ApiException {
      // The poll shows what happened.
    }
    if (!mounted) return;
    _busy = null;
    _running = false;
    _st = null;
    _boPending = null;
    _pending.clear();
    _err = _plain('Stopped. The lights are out.');
    setState(() {});
    _draw();
    _pollNow();
    if (reo) await launchSx(context);
  }

  /// Stops the player and opens ShowXpress, which carries on (lbHandoff).
  Future<void> _handoff() async {
    final ok = await askUser(
      context,
      'Hand over to ShowXpress?',
      'The player stops and ShowXpress opens straight away. It carries on with what is playing now${_autoRunning ? ' (the Auto Show moves over to it)' : ''}.'
          '\n\nThe lights are dark for a few seconds while ShowXpress starts.',
      'Hand over',
    );
    if (!ok) return;
    _gen++;
    _evSeen = false;
    _setBusy('Handing over to ShowXpress…');
    LabHandoff r;
    try {
      r = await _client.labHandoff();
    } on ApiException {
      r = const LabHandoff(ok: false, error: 'Lost connection.');
    }
    if (!mounted) return;
    _busy = null;
    _running = false;
    _st = null;
    _boPending = null;
    _pending.clear();
    _err = r.ok
        ? _plain(
            '${r.test ? '(test copy) ' : ''}Handed over: ShowXpress is starting'
            '${r.auto
                ? ' and the Auto Show carries on in it.'
                : r.titles.isNotEmpty
                ? ". It will play ${r.titles.join(', ')} once it's ready."
                : '.'}',
          )
        : (text: "The player stopped, but ShowXpress didn't open: ${r.error} Press Launch ShowXpress at the top.", tone: Tone.red);
    setState(() {});
    _draw();
    _pollNow();
    unawaited(_app.refresh());
  }

  // ---- arrange

  /// Saves the layout. The screen shows it straight away (lbSaveLayout).
  Future<void> _saveLayout(PlayerLayout lay) async {
    setState(() => _lay = lay);
    _draw();
    if (widget.fixture != null) return;
    try {
      final r = await _client.settingsSet(SettingsChange(playerLayout: lay));
      if (!mounted) return;
      setState(() => _lay = r.playerLayout);
      _draw();
    } on ApiException catch (e) {
      _toast(_amber("The layout wasn't saved. ${e.message}"));
    }
  }

  /// The pages on screen in Arrange, with [page]'s tiles replaced by [tiles].
  List<(String, List<String>)> _onScreen({String? page, List<LabTile>? tiles}) => [
    for (final p in placedPages(_board!, _lay, arranging: true)) (p.page.id, [for (final t in (p.page.id == page ? tiles! : p.tiles)) t.sec]),
  ];

  void _movePage(String id, int by) {
    final shown = _onScreen();
    final i = shown.indexWhere((x) => x.$1 == id);
    final j = i + by;
    if (i < 0 || j < 0 || j >= shown.length) return;
    final x = shown[i];
    shown[i] = shown[j];
    shown[j] = x;
    _saveLayout(layoutFromScreen(_lay, shown));
  }

  Future<void> _resetLayout() async {
    final ok = await askUser(
      context,
      "Back to ShowXpress's order?",
      'The pages and buttons go back to the order they have in ShowXpress, and hidden pages show again. Your own pages stay, at the end.',
      'Reset',
    );
    if (ok) await _saveLayout(_lay.copyWith(pages: [], order: {}, hidden: [], collapsed: []));
  }

  Future<void> _newPage() async {
    if (_lay.custom.length >= 40) {
      _toast(_amber("That's the most pages the player can have (40)."));
      return;
    }
    final f = await askPageForm(context, title: 'New page', yes: 'Make the page');
    if (f == null) return;
    final id = nextPageId(_lay);
    final name = cleanName(f.$1);
    await _saveLayout(
      _lay.copyWith(
        custom: [
          ..._lay.custom,
          PlayerPage(id: id, name: name.isEmpty ? 'NEW PAGE' : name, swap: f.$2),
        ],
        pages: [
          ...placedPages(_board!, _lay, arranging: _arranging).map((p) => p.page.id),
          id,
        ],
      ),
    );
    await _addButtons(id);
  }

  Future<void> _addButtons(String id) async {
    final page = _lay.custom.where((c) => c.id == id).firstOrNull;
    if (page == null || !mounted) return;
    final pick = await askAddButtons(context, page.name, addItems(_board!));
    if (pick.isEmpty) return;
    final (lay, full) = addToPage(_lay, id, pick);
    await _saveLayout(lay);
    if (full) _toast(_amber("A page holds 64 buttons. The rest weren't added."));
  }

  Future<void> _editPage(PlayerPage c) async {
    final f = await askPageForm(context, title: 'Page settings', yes: 'Save', name: c.name, swap: c.swap);
    if (f == null) return;
    final name = cleanName(f.$1);
    await _saveLayout(
      _lay.copyWith(
        custom: [for (final x in _lay.custom) x.id == c.id ? x.copyWith(name: name.isEmpty ? c.name : name, swap: f.$2) : x],
      ),
    );
  }

  Future<void> _deletePage(PlayerPage c) async {
    final n = c.buttons.length;
    final ok = await askUser(
      context,
      'Delete ${c.name}?',
      'The page and its $n button${n == 1 ? '' : 's'} go from the SX Player. The scenes themselves stay in the show.',
      'Delete the page',
    );
    if (!ok) return;
    bool keep(String x) => x != c.id;
    await _saveLayout(
      _lay.copyWith(
        custom: _lay.custom.where((x) => x.id != c.id).toList(),
        pages: _lay.pages.where(keep).toList(),
        hidden: _lay.hidden.where(keep).toList(),
        collapsed: _lay.collapsed.where(keep).toList(),
      ),
    );
  }

  void _deleteButton(String page, String sec) =>
      _saveLayout(_lay.copyWith(custom: [for (final c in _lay.custom) c.id == page ? c.copyWith(buttons: c.buttons.where((b) => b.id != sec).toList()) : c]));

  /// While dragging [sec]'s tile over [over], moves it before or after
  /// [over], by which half of it the pointer is on.
  void _dragOver(String page, String over, Offset pointer, RenderBox box) {
    final d = _drag;
    if (d == null || d.page != page) return;
    final tiles = [...d.tiles];
    final from = tiles.indexWhere((t) => t.sec == _dragSec);
    if (from < 0 || over == _dragSec) return;
    final moving = tiles.removeAt(from);
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final at = tiles.indexWhere((t) => t.sec == over);
    tiles.insert(pointer.dx > rect.center.dx ? at + 1 : at, moving);
    if ([for (final t in tiles) t.sec].join('|') == [for (final t in d.tiles) t.sec].join('|')) return;
    setState(() => _drag = (page: d.page, tiles: tiles, start: d.start));
  }

  String? _dragSec;

  void _dragDone() {
    final d = _drag;
    setState(() => _drag = null);
    _dragSec = null;
    if (d == null) return;
    if ([for (final t in d.tiles) t.sec].join('|') == d.start.join('|')) return;
    _saveLayout(layoutFromScreen(_lay, _onScreen(page: d.page, tiles: d.tiles)));
  }

  // ---- building

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      ScreenBody(
        children: [
          _top(),
          if (_running && _board != null) ...[
            SxCard(
              child: BpmCard(live: _live, input: _bpmInput, focus: _bpmFocus, onTap: _tap, onSet: _setBpm, onSync: () => _cmd(LabCmd.sync, quiet: true)),
            ),
            SxCard(
              child: FadersCard(live: _live, faders: _board!.faders, onMove: _moveFader),
            ),
          ],
          if (_arranging) _arrangeBar(),
          _boardCard(),
        ],
      ),
      // The old page's busy veil, without its spinner.
      if (_busy != null)
        Positioned.fill(
          child: ColoredBox(
            color: Sx.bg.withValues(alpha: .7),
            child: Center(
              child: SxCard(
                child: Text(_busy!, style: TextStyle(fontSize: 15, color: Sx.text)),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _top() => SxCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SxHeader(
          'SX Player',
          sub:
              "Plays your show's scenes and movements straight to the DMX interface, with ShowXpress closed. Nothing in the show is changed. "
              'Tap a button to start it, tap again to stop. On a MOVEMENTS page one replaces the other. '
              "A movement only moves what it's set to (usually pan/tilt), so tap a colour scene as well. "
              'While it plays, the APC mini pads and speed faders, the keyboard keys, BPM (tap, type or VirtualDJ) and the Auto Show all work.',
          actions: [
            Tooltip(
              message: "Order, hide and add pages and buttons (only here, ShowXpress's live screen stays as it is)",
              child: MiniButton(
                _arranging ? 'Arranging' : 'Arrange',
                icon: _arranging ? Icons.check : Icons.swap_vert,
                on: _arranging,
                onPressed: _board == null ? null : () => setState(() => _arranging = !_arranging),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _gigHelp = !_gigHelp),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_gigHelp ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Sx.dim),
              Text('At a gig', style: TextStyle(fontSize: 13, color: Sx.dim)),
            ],
          ),
        ),
        if (_gigHelp)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Hand over to ShowXpress stops the player and opens ShowXpress straight away, and ShowXpress carries on with what was playing '
              '(starting the player does the same the other way round). If the DMX interface gets unplugged the player waits and carries on '
              "when it's plugged back in. If the player itself stops, SX Studio starts it again. If someone opens ShowXpress, the player hands over to it. "
              "The laptop doesn't sleep while the player runs. Scenes, chases and movements were checked against ShowXpress's own DMX output; "
              "which button wins when two use the same light isn't measured yet.",
              style: Sx.sub,
            ),
          ),
        const SizedBox(height: 14),
        _controls(),
        _messages(),
      ],
    ),
  );

  Widget _controls() {
    final busy = _busy != null;
    if (!_running) {
      return Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _board == null || busy ? null : () => _go(),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Start the player'),
              ),
              Text(
                'or just tap a scene below. The player starts and plays it. ShowXpress closes while the player runs (only one program can use the DMX interface).',
                style: TextStyle(fontSize: 13, color: Sx.dim),
              ),
            ],
          ),
          MiniButton('Reload the show', onPressed: busy ? null : _load),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: Sx.tint(Sx.green, radius: 99),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Dot(Tone.green),
                  Text(
                    'Playing',
                    style: TextStyle(color: Sx.green, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            MiniButton('Release all', onPressed: _releaseAll),
            ValueListenableBuilder(
              valueListenable: _live.bo,
              builder: (context, bo, _) => MiniButton(bo ? 'Blackout is ON' : 'Blackout', icon: bo ? Icons.circle : null, on: bo, onPressed: _blackout),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!_phone)
              InkWell(
                onTap: () => setState(() => _reopen = !_reopen),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: Checkbox(value: _reopen, onChanged: (v) => setState(() => _reopen = v ?? false)),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('Open ShowXpress again when I stop', style: TextStyle(color: Sx.dim, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            Tooltip(
              message: 'Stops the player and opens ShowXpress straight away. It carries on with what was playing',
              child: MiniButton('Hand over to ShowXpress', icon: Icons.swap_horiz, onPressed: _handoff),
            ),
            FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop, size: 18), label: const Text('Stop the player')),
          ],
        ),
      ],
    );
  }

  Widget _messages() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ValueListenableBuilder(
        valueListenable: _live.lost,
        builder: (context, lost, _) => !lost
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.warning_amber_rounded, size: 16, color: Sx.red),
                        ),
                      ),
                      const TextSpan(
                        text:
                            "The DMX interface is unplugged. The lights aren't getting the show. Plug its USB cable back in: the player carries on by itself.",
                      ),
                    ],
                  ),
                  style: TextStyle(color: Sx.red, fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
      ),
      ValueListenableBuilder(
        valueListenable: _live.msg,
        builder: (context, m, _) => m == null || m.text.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(m.text, style: TextStyle(color: m.tone.color, fontSize: 13)),
              ),
      ),
      ValueListenableBuilder(valueListenable: _live.warn, builder: (context, w, _) => w.isEmpty ? const SizedBox.shrink() : _WarnList(w.split('\n'))),
    ],
  );

  /// The old page's `.arrbar`.
  Widget _arrangeBar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: Sx.tint(Sx.accent, radius: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Arrange  ',
                style: TextStyle(fontWeight: FontWeight.w700, color: Sx.text),
              ),
              const TextSpan(
                text:
                    'Drag a button to move it inside its page. The arrows move a whole page, and Hide takes a page out of the player. '
                    "New page makes a page that's only in the SX Player, with copies of any of the show's buttons. "
                    'Every change shows and is saved straight away, for this computer, the phone and the iPad. ShowXpress and its live screen stay exactly as they are.',
              ),
            ],
          ),
          style: TextStyle(fontSize: 13, color: Sx.text2, height: 1.4),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MiniButton('New page', icon: Icons.add, onPressed: _newPage),
            MiniButton("Reset to ShowXpress's order", onPressed: _resetLayout),
            MiniButton('Done', icon: Icons.check, on: true, onPressed: () => setState(() => _arranging = false)),
          ],
        ),
      ],
    ),
  );

  Widget _boardCard() {
    final b = _board;
    if (b == null) {
      return SxCard(
        child: Text(
          !_loaded ? 'Loading…' : (_boardError.isEmpty ? 'Could not read the show.' : _boardError),
          style: TextStyle(fontSize: 13, color: _loaded ? Sx.red : Sx.dim),
        ),
      );
    }
    final placed = placedPages(b, _lay, arranging: _arranging);
    final ids = {for (final p in allPages(b, _lay)) p.id};
    final nh = _lay.hidden.where(ids.contains).length;
    return SxCard(
      child: LayoutBuilder(
        builder: (context, box) {
          // `.lbb{flex:1 1 150px;min-width:140px;max-width:230px}` with 8 px gaps.
          final cols = math.max(box.maxWidth >= 2 * 140 + 8 ? 2 : 1, ((box.maxWidth + 8) / (150 + 8)).floor());
          final w = math.min(230.0, (box.maxWidth - 8 * (cols - 1)) / cols);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (placed.isEmpty) Text('No live buttons in the show.', style: Sx.sub),
              for (final (i, p) in placed.indexed) _page(p, w, first: i == 0),
              if (!_arranging && nh > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    nh == 1 ? '1 page is hidden. Press Arrange to show it again.' : '$nh pages are hidden. Press Arrange to show them again.',
                    style: Sx.sub,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _page(PlacedPage p, double w, {required bool first}) {
    final id = p.page.id;
    final custom = _lay.custom.where((c) => c.id == id).firstOrNull;
    final tiles = _drag?.page == id ? _drag!.tiles : p.tiles;
    final head = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InkWell(
          onTap: () => _saveLayout(_lay.copyWith(collapsed: toggled(_lay.collapsed, id))),
          child: Tooltip(
            message: p.collapsed ? 'Open this page' : 'Collapse this page',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(p.collapsed ? Icons.arrow_right : Icons.arrow_drop_down, size: 18, color: Sx.dim),
                  const SizedBox(width: 2),
                  Text(p.page.title.toUpperCase(), style: Sx.label),
                ],
              ),
            ),
          ),
        ),
        if (p.page.custom) const Tooltip(message: 'Only in the SX Player, not in ShowXpress', child: _Tag('SX PLAYER')),
        if (p.hidden) const _Tag('HIDDEN'),
        ValueListenableBuilder(
          valueListenable: _live.pageOn(id),
          builder: (context, n, _) => n == 0
              ? const SizedBox.shrink()
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow, size: 13, color: Sx.green),
                    Text(
                      '$n PLAYING',
                      style: Sx.label.copyWith(color: Sx.green, fontWeight: FontWeight.w600, letterSpacing: .5),
                    ),
                  ],
                ),
        ),
        if (_arranging) ...[
          const SizedBox(width: 2),
          IconMini(Icons.arrow_drop_up, () => _movePage(id, -1), tip: 'Move this page up'),
          IconMini(Icons.arrow_drop_down, () => _movePage(id, 1), tip: 'Move this page down'),
          Tooltip(
            message: p.hidden
                ? 'This page is hidden. Press to show it in the player again'
                : 'Hide this page from the player (it still plays from the APC and the Auto Show)',
            child: MiniButton(
              p.hidden ? 'Unhide' : 'Hide',
              icon: p.hidden ? Icons.visibility : null,
              on: p.hidden,
              onPressed: () => _saveLayout(_lay.copyWith(hidden: toggled(_lay.hidden, id))),
            ),
          ),
          if (custom != null) ...[
            MiniButton('Buttons', icon: Icons.add, onPressed: () => _addButtons(id)),
            MiniButton('Settings', onPressed: () => _editPage(custom)),
            MiniButton('Delete', onPressed: () => _deletePage(custom)),
          ],
        ],
      ],
    );
    final dim = _arranging && p.hidden ? .45 : 1.0;
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Opacity(opacity: dim, child: head),
          const SizedBox(height: 6),
          if (!p.collapsed)
            Opacity(
              opacity: dim,
              child: Wrap(spacing: 8, runSpacing: 8, children: [for (final t in tiles) _arranging ? _dragTile(id, t, w, tiles) : _tile(t, w)]),
            ),
          if (!p.collapsed && p.page.custom && tiles.isEmpty)
            Text(_arranging ? 'No buttons yet. Press Buttons.' : 'No buttons yet. Press Arrange, then Buttons.', style: Sx.sub),
        ],
      ),
    );
  }

  Widget _tile(LabTile t, double w) =>
      TileView(key: ValueKey(t.sec), tile: t, state: _live.tile(t), width: w, idle: !_running, onTap: () => _press(t), onMenu: (at) => _menu(t, at));

  /// The button's menu at [at], the old right-click and long-press `ctxOpen`:
  /// opens its scene or movement in that editor (lbEditFile).
  Future<void> _menu(LabTile t, Offset at) async {
    final tab = editorTab(t.file);
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final edit = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
      color: Sx.panel,
      surfaceTintColor: Colors.transparent,
      // `box-shadow: 0 10px 28px rgba(0,0,0,.45)`: dark in both themes.
      shadowColor: Sx.isLight ? Sx.text : Sx.bg,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Sx.line2),
      ),
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 284),
      menuPadding: const EdgeInsets.all(4),
      items: [
        PopupMenuItem(
          enabled: false,
          height: 0,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: Text(
            t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Sx.mute, fontWeight: FontWeight.w600, letterSpacing: .5),
          ),
        ),
        PopupMenuItem(
          value: true,
          enabled: !t.missing && tab != null,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.edit, size: 14, color: t.missing ? Sx.mute : Sx.text),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Edit ${tab == 'move' ? 'movement' : 'scene'}${t.missing ? ' (file missing)' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: t.missing ? Sx.mute : Sx.text),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (edit == true && tab != null && mounted) _app.openFile(tab, t.file);
  }

  Widget _dragTile(String page, LabTile t, double w, List<LabTile> tiles) {
    Widget view({bool delete = true}) => TileView(
      tile: t,
      state: _live.tile(t),
      width: w,
      idle: !_running,
      arranging: true,
      onMenu: (at) => _menu(t, at),
      onDelete: delete && t.custom ? () => _deleteButton(page, t.sec) : null,
    );
    return Builder(
      key: ValueKey(t.sec),
      builder: (target) => DragTarget<String>(
        onWillAcceptWithDetails: (d) => _drag?.page == page,
        onMove: (d) {
          if (target.findRenderObject() case final RenderBox box) _dragOver(page, t.sec, d.offset, box);
        },
        builder: (context, _, _) => Draggable<String>(
          data: t.sec,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          // `.lbghost`: tilted, under the pointer.
          feedback: Transform.translate(
            offset: Offset(-w / 2, -24),
            child: Transform.rotate(
              angle: -.035,
              child: Material(type: MaterialType.transparency, child: view(delete: false)),
            ),
          ),
          childWhenDragging: Opacity(opacity: .35, child: view(delete: false)),
          onDragStarted: () {
            _dragSec = t.sec;
            setState(() => _drag = (page: page, tiles: [...tiles], start: [for (final x in tiles) x.sec]));
          },
          onDragEnd: (_) => _dragDone(),
          child: MouseRegion(cursor: SystemMouseCursors.grab, child: view()),
        ),
      ),
    );
  }
}

/// A page's tag (`.pgtag`).
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: Sx.line2),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: Sx.label.copyWith(fontSize: 9.5, letterSpacing: 1, color: Sx.mute)),
  );
}

/// "Show check: 3 problems in the show", opening to the list.
class _WarnList extends StatefulWidget {
  const _WarnList(this.lines);

  final List<String> lines;

  @override
  State<_WarnList> createState() => _WarnListState();
}

class _WarnListState extends State<_WarnList> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.lines.length;
    final style = TextStyle(color: Sx.amber, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Sx.amber),
                Flexible(child: Text('Show check: $n problem${n > 1 ? 's' : ''} in the show', style: style)),
              ],
            ),
          ),
          if (_open)
            for (final l in widget.lines) Text(l, style: style),
        ],
      ),
    );
  }
}
