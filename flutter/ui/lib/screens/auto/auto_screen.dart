import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../remote/remote_row.dart';
import 'auto_logic.dart';
import 'button_picker.dart';
import 'now_playing.dart';

const _tab = 'auto';

bool _isSetup(String page) => RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(page);

/// A line under the looks: what the last action did. The color is read when drawn.
typedef _Msg = ({String text, Color Function() color, IconData? icon});

/// Auto Show: SX Studio presses the user's looks in ShowXpress one after
/// another, each for a number of bars, while the DJ mixes.
///
/// Port of the old page's `v-auto` view and its script (`renderAuto`,
/// `auLooks`, `auPlay`, `auDraw`, `auSave`, `auStart`, `auTry`, `auGrab`).
class AutoScreen extends StatefulWidget {
  const AutoScreen(BuildContext _, {super.key});

  @override
  State<AutoScreen> createState() => _AutoScreenState();
}

class _AutoScreenState extends State<AutoScreen> {
  AutoInfo? _info;

  /// The working copy of the settings. Edits change it in place.
  AutoConfig? _c;
  var _error = '';

  AutoStatus? _st;
  var _stAt = DateTime.now();
  String? _polledAt;

  /// Asks the engine for the status once a second while the show plays on
  /// this tab, as the old page did.
  Timer? _poll;

  /// Titles the last "Try" pressed, released by the next Try.
  var _tried = <String>[];
  var _taps = <int>[];
  _Msg? _msg;
  Timer? _bpmSend;
  String? _first;

  /// Goes up whenever the edits are replaced, so the name fields start over.
  var _gen = 0;
  final _bpm = TextEditingController();
  final _bpmFocus = FocusNode();

  AppState get _app => AppScope.read(context);
  bool get _running => _st?.running ?? false;

  @override
  void initState() {
    super.initState();
    _bpmFocus.addListener(() {
      if (!_bpmFocus.hasFocus) _bpmTyped();
    });
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    // the status poll carries the Auto Show's status too
    final a = app.status?.auto;
    if (a != null && a.at != _polledAt) {
      _polledAt = a.at;
      _setStatus(a);
    }
    _syncPoll(app.tab == _tab);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _bpmSend?.cancel();
    _bpm.dispose();
    _bpmFocus.dispose();
    super.dispose();
  }

  void _syncPoll(bool onTab) {
    final want = onTab && _running;
    if (want && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          final s = await _app.client.autoStatus();
          if (mounted) setState(() => _setStatus(s));
        } on ApiException {
          // the next tick tries again
        }
      });
    } else if (!want) {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _setStatus(AutoStatus? s) {
    _st = s;
    _stAt = DateTime.now();
    if (s != null && s.running && s.target == 'player' && !_bpmFocus.hasFocus) _bpm.text = '${s.bpm.round()}';
    if (mounted) _syncPoll(_app.tab == _tab);
  }

  Future<void> _load() async {
    try {
      final i = await _app.client.auto();
      if (!mounted) return;
      setState(() {
        _info = i;
        _c = i.config.copy();
        _error = '';
        _gen++;
        _bpm.text = bpmText(i.config.bpm);
        _setStatus(i.status);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    _app.setDirty(_tab, false);
  }

  bool get _dirty => _info != null && _c != null && jsonEncode(_c!.toJson()) != jsonEncode(_info!.config.toJson());

  /// Call after every edit of [_c].
  void _edited() {
    setState(() {});
    _app.setDirty(_tab, _dirty);
  }

  void _say(String text, {Color Function()? color, IconData? icon}) =>
      setState(() => _msg = text.isEmpty ? null : (text: text, color: color ?? () => Sx.dim, icon: icon));

  void _undo() {
    setState(() {
      _c = _info!.config.copy();
      _gen++;
      _bpm.text = bpmText(_c!.bpm);
    });
    _app.setDirty(_tab, false);
  }

  /// Takes the settings the engine saved, cleaned, as the new baseline.
  void _saved(ToolResult r) {
    final saved = r.extra['config'];
    if (!r.ok || saved is! Map || !mounted) return;
    final cfg = AutoConfig.fromJson(saved.cast<String, Object?>());
    final i = _info!;
    setState(() {
      _info = AutoInfo(show: i.show, config: cfg, buttons: i.buttons, ready: i.ready, open: i.open, setup: i.setup, player: i.player, status: i.status);
      _c = cfg.copy();
      _gen++;
      _bpm.text = bpmText(cfg.bpm);
    });
    _app.setDirty(_tab, false);
  }

  /// Saves. [quiet] saves before a start or a "Play now" and only speaks up
  /// on failure. Port of `auSave`.
  Future<bool> _save({bool quiet = false}) async {
    var ok = false;
    await runSave(context, quiet: quiet, () async {
      final r = await _app.client.autoSave(_c!);
      ok = r.ok;
      _saved(r);
      return r;
    });
    return ok;
  }

  /// Port of `auStart`.
  Future<void> _start() async {
    if (_dirty && !await _save(quiet: true)) return;
    final act = _active;
    final first = act.any((l) => l.id == _first) ? _first! : (act.firstOrNull?.id ?? '');
    final r = await _app.client.autoStart(first);
    if (!mounted) return;
    setState(() {
      _setStatus(r.status);
      _tried = [];
    });
    await _app.refresh();
    if (!r.ok && mounted) await showReport(context, "The Auto Show didn't start", '', error: r.error);
  }

  Future<void> _cmd(AutoCmd cmd, [String v = '']) async {
    final r = await _app.client.autoCmd(cmd, v);
    if (!mounted) return;
    setState(() {
      if (r.status != null) _setStatus(r.status);
    });
    if (!r.ok) _say(r.error, color: () => Sx.red);
  }

  Future<void> _stop() async {
    final r = await _app.client.autoStop();
    if (!mounted) return;
    final s = r.status;
    setState(() => _setStatus(s == null ? null : AutoStatus.fromJson({...s.toJson(), 'error': ''})));
    await _app.refresh();
  }

  /// Port of `auSetBpm`. [live] sends it to a running show too.
  void _setBpm(double v, {required bool live}) {
    final b = clampBpm(v);
    _c!.bpm = b;
    if (!_bpmFocus.hasFocus) _bpm.text = bpmText(b);
    _edited();
    if (live && _running) {
      _bpmSend?.cancel();
      _bpmSend = Timer(const Duration(milliseconds: 350), () => _cmd(AutoCmd.bpm, bpmText(b)));
    }
  }

  void _bpmTyped() {
    final c = _c;
    if (c == null) return;
    final v = double.tryParse(_bpm.text.trim()) ?? 124;
    if (clampBpm(v) != c.bpm) {
      _setBpm(v, live: true);
    } else {
      _bpm.text = bpmText(c.bpm);
    }
  }

  /// Port of `auTap`.
  void _tap() {
    final (taps, bpm) = tapTempo(_taps, DateTime.now().millisecondsSinceEpoch);
    _taps = taps;
    if (bpm != null) {
      _bpmFocus.unfocus();
      _setBpm(bpm, live: true);
    } else {
      setState(() {});
    }
  }

  List<AutoLook> get _active => [
    for (final l in _c?.looks ?? const <AutoLook>[])
      if (l.on && l.titles.isNotEmpty) l,
  ];

  void _remoteProblem(RemoteState r) => _say(
    !r.ready && r.setup != null ? 'The ShowXpress remote is off.' : (r.error.isNotEmpty ? r.error : "ShowXpress isn't answering."),
    color: () => Sx.amber,
  );

  /// What plays in ShowXpress now, outside SETUP, at most 24 titles. Null
  /// (with a message) when that can't be read. Port of `auGrab`.
  Future<List<String>?> _grab() async {
    final r = await _app.client.remote();
    if (!r.connected) {
      _remoteProblem(r);
      return null;
    }
    final ts = <String>{
      for (final p in r.pressed)
        if (!_isSetup(p.page)) p.title,
    }.toList();
    if (ts.isEmpty) {
      _say("Nothing is playing in ShowXpress (SETUP page buttons don't count). Press the buttons for the look there first.", color: () => Sx.amber);
      return null;
    }
    _say('');
    return ts.take(24).toList();
  }

  /// Port of `auTry`: plays a running show's look now, or tries it in ShowXpress.
  Future<void> _try(AutoLook l) async {
    if (_running) {
      if (_dirty && !await _save(quiet: true)) return;
      return _cmd(AutoCmd.go, l.id);
    }
    final r = await _app.client.remotePress(
      l.titles,
      release: [
        for (final x in _tried)
          if (!l.titles.contains(x)) x,
      ],
    );
    if (!r.connected) return _remoteProblem(r);
    _tried = [...l.titles];
    final miss = r.missing.isEmpty ? '' : '. Not in the show: ${r.missing.join(', ')}';
    _say('Trying ${l.name} in ShowXpress$miss. Press Try on another look to switch.', color: miss.isEmpty ? null : () => Sx.red, icon: Icons.play_arrow);
  }

  /// Port of `auAskSplit`.
  Future<void> _askSplit(int i) async {
    final c = _c!, l = c.looks[i], clash = biggestClash(l, _info!.buttons);
    if (clash == null) return;
    final (page, many) = clash;
    final ok = await askSx(
      context,
      'Make each one its own look?',
      "$page plays one button at a time in ShowXpress, so ${many.length} of them in one look can't play together. Only the last would stay on.\n\n"
          'Split it into ${many.length} looks (${many.join(', ')})${l.titles.length > many.length ? ', each keeping the other buttons of this look' : ''}, '
          'so the Auto Show cycles through them?',
      'Split into ${many.length} looks',
    );
    if (!ok) return;
    final n = splitLook(c, i, _info!.buttons);
    _gen++;
    _edited();
    _say('Split into $n looks of ${l.bars} bars. Save to keep it.', icon: Icons.check);
  }

  /// Port of `auLookAct`.
  Future<void> _lookAction(String k, int i) async {
    final looks = _c!.looks, l = looks[i];
    switch (k) {
      case 'up':
        looks.insert(i - 1, looks.removeAt(i));
      case 'down':
        looks.insert(i + 1, looks.removeAt(i));
      case 'copy':
        final c = l.copy()..id = newLookId();
        final name = '${l.name} copy';
        c.name = name.length > 40 ? name.substring(0, 40) : name;
        looks.insert(i + 1, c);
      case 'del':
        final ok = await askSx(
          context,
          'Delete ${l.name}?',
          'The look is taken out of the Auto Show (nothing in ShowXpress changes). Undo brings it back until you save.',
          'Delete',
        );
        if (!ok) return;
        looks.removeAt(i);
      case 'add':
        await pickButtons(context, l, _info!.buttons);
        _edited();
        if (mounted) await _askSplit(i);
        return;
      case 'grab':
        final ts = await _grab();
        if (ts == null) return;
        l.titles = ts;
        _say("${l.name} now uses what's playing: ${ts.join(', ')}", icon: Icons.check);
      case 'try':
        return _try(l);
    }
    _gen++;
    _edited();
  }

  void _newLook() {
    final c = _c!;
    c.looks.add(AutoLook(id: newLookId(), name: 'Look ${c.looks.length + 1}', bars: 16, on: true, titles: []));
    _gen++;
    _edited();
    _lookAction('add', c.looks.length - 1);
  }

  Future<void> _newFromPlaying() async {
    final ts = await _grab();
    if (ts == null) return;
    final c = _c!;
    c.looks.add(AutoLook(id: newLookId(), name: 'Look ${c.looks.length + 1}', bars: 16, on: true, titles: ts));
    _gen++;
    _edited();
    _say('New look Look ${c.looks.length}: ${ts.join(', ')}. Give it a name and save.', icon: Icons.check);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final i = _info, c = _c;
    final dirty = _dirty;
    return ScreenBody(
      bar: SaveBar(
        hint: i == null
            ? ''
            : dirty
            ? 'Not saved yet${_running ? '. The Auto Show picks the changes up when you save' : ''}.'
            : 'Saved. Starting, stopping and BPM taps work any time. ShowXpress stays open.',
        actions: [
          TextButton(onPressed: dirty ? _undo : null, child: const Text('Undo')),
          FilledButton(onPressed: dirty ? () => _save() : null, child: const Text('Save')),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SxHeader(
                'Auto Show',
                sub:
                    'SX Studio presses your looks in ShowXpress one after another, each for a number of bars, for the stretches when you are busy mixing. '
                    'A look is a few buttons that play together (a movement, a colour, uplights). Whatever you press yourself on the APC still works on top. '
                    'Tap the BPM to the music and press Bar 1 now on a downbeat to line the changes up.',
              ),
              ErrorBox(_error),
              if (i == null && _error.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (i != null && !i.ready && !i.player && !(_running && _st!.target == 'player')) _remoteOff(),
              if (i != null && c != null) _play(app, i, c),
            ],
          ),
        ),
        if (i != null && c != null) SxCard(child: _looks(i, c)),
      ],
    );
  }

  /// The old `#aurem` warnbox.
  Widget _remoteOff() => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: Sx.tint(Sx.red),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text("The ShowXpress remote is off, so the Auto Show can't press anything yet.", style: TextStyle(color: Sx.redText, fontSize: 13)),
        MiniButton('Turn on remote control', onPressed: () => enableRemote(context, after: _load), primary: true),
      ],
    ),
  );

  Widget _bpmControls() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('BPM', style: Sx.sub),
      const SizedBox(width: 8),
      SizedBox(
        width: 76,
        child: TextField(
          controller: _bpm,
          focusNode: _bpmFocus,
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 15, color: Sx.text),
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7)),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: (_) => _bpmTyped(),
        ),
      ),
      const SizedBox(width: 8),
      Tooltip(
        message: 'Tap along with the beat (3 taps or more)',
        child: MiniButton(
          _taps.isNotEmpty && _taps.length < 3 ? 'Tap (${3 - _taps.length} more)' : 'Tap',
          icon: _taps.length >= 3 ? Icons.check : null,
          onPressed: _tap,
        ),
      ),
    ],
  );

  /// The old `.auplay` box.
  Widget _play(AppState app, AutoInfo i, AutoConfig c) {
    final s = _st, run = s != null && s.running;
    final phone = MediaQuery.sizeOf(context).width <= 640;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: Sx.well,
        border: Border.all(color: run ? Sx.green.withValues(alpha: .5) : Sx.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: run ? _playing(app, s, phone) : _notPlaying(i, c, s, phone),
    );
  }

  Widget _notPlaying(AutoInfo i, AutoConfig c, AutoStatus? s, bool phone) {
    final act = _active;
    final first = act.any((l) => l.id == _first) ? _first! : act.firstOrNull?.id;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: phone ? 0 : 260),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Not playing', style: _big(phone)),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  act.isNotEmpty
                      ? '${act.length} look${act.length > 1 ? 's' : ''} ready · ${c.order == 'shuffle' ? 'shuffled' : 'in order'}'
                      : 'Add a look below to start.',
                  style: Sx.sub,
                ),
              ),
              if (s != null && s.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(s.error, style: TextStyle(color: Sx.red)),
                ),
            ],
          ),
        ),
        _bpmControls(),
        if (first != null) _Select<String>(value: first, items: {for (final l in act) l.id: 'Start with ${l.name}'}, onPick: (v) => setState(() => _first = v)),
        FilledButton.icon(
          onPressed: act.isNotEmpty && (i.ready || i.player) ? _start : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Start Auto Show'),
        ),
      ],
    );
  }

  /// The old `.aubig`.
  TextStyle _big(bool phone) =>
      TextStyle(fontFamily: Sx.display, letterSpacing: .5, fontSize: phone ? 22 : 28, fontWeight: FontWeight.w700, height: 1.15, color: Sx.text);

  Widget _playing(AppState app, AutoStatus s, bool phone) {
    const pad = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NowPlaying(status: s, received: _stAt, visible: app.tab == _tab, big: _big(phone)),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: 'The look before',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: pad),
                onPressed: () => _cmd(AutoCmd.prev),
                icon: const Icon(Icons.skip_previous, size: 18),
                label: const Text('Back'),
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 14, fontWeight: FontWeight.w700),
              ),
              onPressed: () => _cmd(AutoCmd.next),
              icon: const Icon(Icons.skip_next, size: 18),
              label: const Text('Next look'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(padding: pad),
              onPressed: () => _cmd(s.held ? AutoCmd.resume : AutoCmd.hold),
              child: Text(s.held ? 'Resume' : 'Hold'),
            ),
            Tooltip(
              message: 'Press on the first beat of a bar: the bar count starts again from here',
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: pad),
                onPressed: () => _cmd(AutoCmd.sync),
                child: const Text('Bar 1 now'),
              ),
            ),
            _bpmControls(),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: pad),
              onPressed: _stop,
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _looks(AutoInfo i, AutoConfig c) {
    final looks = c.looks, act = _active;
    final round = act.fold(0.0, (a, l) => a + lookSeconds(l, c.bpm));
    final msg = _msg;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Looks', style: Sx.title),
                  if (looks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${act.length} of ${looks.length} look${looks.length > 1 ? 's' : ''} in the show · one round ≈ ${fmtSeconds(round)} at ${bpmText(c.bpm)} BPM',
                        style: Sx.sub,
                      ),
                    ),
                ],
              ),
            ),
            OutlinedButton(onPressed: _newLook, child: const Text('+ New look')),
            OutlinedButton.icon(onPressed: _newFromPlaying, icon: const Icon(Icons.download, size: 18), label: const Text("New look from what's playing")),
          ],
        ),
        if (looks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'No looks yet. A look is what plays at the same time, for example one movement, a colour and the uplights. '
              "To cycle through movements, make one look per movement. Build one in ShowXpress, then press New look from what's playing, "
              'or press + New look and pick the buttons.',
              style: Sx.sub,
            ),
          ),
        for (final (k, l) in looks.indexed) _LookRow(key: ValueKey('${l.id}-$_gen'), index: k, count: looks.length, look: l, state: this),
        const SizedBox(height: 16),
        Wrap(
          spacing: 14,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Order', style: Sx.sub),
            Seg<String>(
              value: c.order,
              options: const {'order': 'In order', 'shuffle': 'Shuffle'},
              onChanged: (v) {
                c.order = v;
                _edited();
              },
            ),
            Text('When I stop', style: Sx.sub),
            _Select<String>(
              value: c.stop,
              items: const {'keep': 'Leave the last look playing', 'off': 'Turn the look off'},
              onPick: (v) {
                c.stop = v;
                _edited();
              },
            ),
            _Check(
              "At start, turn off everything else that's playing",
              value: c.clean,
              onChanged: (v) {
                c.clean = v;
                _edited();
              },
            ),
          ],
        ),
        if (msg != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text.rich(
              TextSpan(
                children: [
                  if (msg.icon != null)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(msg.icon, size: 15, color: msg.color()),
                      ),
                    ),
                  TextSpan(text: msg.text),
                ],
              ),
              style: TextStyle(color: msg.color(), fontSize: 13, height: 1.4),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text('Show: ${i.show} · Auto Show settings are kept in the show folder (auto_show.json)', style: TextStyle(color: Sx.mute, fontSize: 12)),
        ),
      ],
    );
  }
}

/// One look, the old `.aulook`: number, name, bars, in the show, actions,
/// and its buttons.
class _LookRow extends StatelessWidget {
  const _LookRow({super.key, required this.index, required this.count, required this.look, required this.state});

  final int index;
  final int count;
  final AutoLook look;
  final _AutoScreenState state;

  @override
  Widget build(BuildContext context) {
    final l = look, i = index, s = state;
    final buttons = s._info!.buttons, bpm = s._c!.bpm;
    final run = s._running;
    final cur = run && s._st!.lookId == l.id;
    final bars = autoBars.contains(l.bars) ? autoBars : ([...autoBars, l.bars]..sort());
    final clashes = lookClashes(l, buttons);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: cur ? Sx.green : Sx.line, width: cur ? 2 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Opacity(
        opacity: l.on ? 1 : .55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: cur ? Sx.green : Sx.tabOn),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cur ? Sx.onPrimary : Sx.text),
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: TextFormField(
                    initialValue: l.name,
                    maxLength: 40,
                    style: TextStyle(fontSize: 13.5, color: Sx.text),
                    decoration: const InputDecoration(counterText: '', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                    onChanged: (v) {
                      l.name = v;
                      s._edited();
                    },
                  ),
                ),
                _Select<int>(
                  value: l.bars,
                  items: {for (final b in bars) b: '$b bar${b > 1 ? 's' : ''}'},
                  onPick: (v) {
                    l.bars = v;
                    s._edited();
                  },
                ),
                Text('≈ ${fmtSeconds(lookSeconds(l, bpm))}', style: Sx.sub),
                _Check(
                  'In the show',
                  value: l.on,
                  onChanged: (v) {
                    l.on = v;
                    s._edited();
                  },
                ),
                MiniButton(run ? 'Play now' : 'Try', icon: Icons.play_arrow, onPressed: l.titles.isEmpty ? null : () => s._lookAction('try', i)),
                Tooltip(message: 'Move up', child: _IconMini(Icons.arrow_upward, i > 0 ? () => s._lookAction('up', i) : null)),
                Tooltip(message: 'Move down', child: _IconMini(Icons.arrow_downward, i < count - 1 ? () => s._lookAction('down', i) : null)),
                MiniButton('Copy', onPressed: () => s._lookAction('copy', i)),
                MiniButton('Delete', onPressed: () => s._lookAction('del', i)),
              ],
            ),
            if (clashes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.warning_amber, size: 15, color: Sx.amber),
                            ),
                          ),
                          TextSpan(
                            text: clashes.map((c) => '${c.$1} plays one button at a time, only ${c.$2.last} of these ${c.$2.length} would play.').join(' '),
                          ),
                        ],
                      ),
                      style: TextStyle(color: Sx.amber, fontSize: 13),
                    ),
                    MiniButton('Split into one look each', primary: true, onPressed: () => s._askSplit(i)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (l.titles.isEmpty) Text('No buttons yet.', style: TextStyle(color: Sx.mute, fontSize: 12.5)),
                for (final (j, x) in l.titles.indexed)
                  _TitleChip(
                    x,
                    problem: switch (buttonFor(buttons, x)) {
                      null => 'Not in the show (renamed or deleted?)',
                      final b when !b.reach => "Its page can't be reached by the remote. Turn the remote on again.",
                      _ => null,
                    },
                    page: buttonFor(buttons, x)?.page ?? '',
                    onRemove: () {
                      l.titles.removeAt(j);
                      s._edited();
                    },
                  ),
                MiniButton('+ Button', onPressed: () => s._lookAction('add', i)),
                Tooltip(
                  message: 'Use the buttons playing in ShowXpress now',
                  child: MiniButton("What's playing", icon: Icons.download, onPressed: () => s._lookAction('grab', i)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A `.mini` button with only an icon (the old arrows).
class _IconMini extends StatelessWidget {
  const _IconMini(this.icon, this.onPressed);

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const StadiumBorder(),
      backgroundColor: Sx.hover,
      foregroundColor: Sx.text,
      side: BorderSide(color: Sx.line),
    ),
    child: Icon(icon, size: 14),
  );
}

/// A button of a look, the old `.auchip`, with a cross to take it out.
class _TitleChip extends StatelessWidget {
  const _TitleChip(this.title, {required this.problem, required this.page, required this.onRemove});

  final String title;
  final String? problem;
  final String page;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final bad = problem != null;
    return Tooltip(
      message: problem ?? page,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 3, 4, 3),
        decoration: BoxDecoration(
          color: Sx.well,
          border: Border.all(color: bad ? Sx.red : Sx.line2),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: TextStyle(fontSize: 12.5, color: bad ? Sx.redText : Sx.text)),
            InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Icon(Icons.close, size: 13, color: Sx.dim, semanticLabel: 'Take it out of this look'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A drop-down, the old `select`.
class _Select<T> extends StatelessWidget {
  const _Select({required this.value, required this.items, required this.onPick});

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: Sx.well,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        isDense: true,
        dropdownColor: Sx.panel,
        style: TextStyle(fontFamily: Sx.body, fontSize: 13, color: Sx.text),
        value: items.containsKey(value) ? value : null,
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) {
          if (v != null) onPick(v);
        },
      ),
    ),
  );
}

/// A checkbox with its label, the old `label.link`.
class _Check extends StatelessWidget {
  const _Check(this.label, {required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            activeColor: Sx.accent,
            checkColor: Sx.isLight ? Sx.card : Sx.onPrimary,
            side: BorderSide(color: Sx.line2),
            onChanged: (v) => onChanged(v ?? false),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: TextStyle(fontSize: 13, color: Sx.dim)),
        ),
      ],
    ),
  );
}
