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

/// A compact button, as the old page's `mini` buttons.
Widget _mini(String label, VoidCallback? onTap, {bool primary = false, String? tip}) {
  const pad = EdgeInsets.symmetric(horizontal: 10, vertical: 6);
  final b = primary
      ? FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(padding: pad, visualDensity: VisualDensity.compact),
          child: Text(label),
        )
      : OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(padding: pad, visualDensity: VisualDensity.compact),
          child: Text(label),
        );
  return tip == null ? b : Tooltip(message: tip, child: b);
}

/// Auto Show: SX Studio presses the user's looks in ShowXpress one after
/// another, each for a number of bars, while the DJ mixes.
///
/// Port of the old page's `v-auto` view and its script (`loadAuto`,
/// `renderAuto`, `auLooks`, `auPlay`, `auDraw`, `auSave`, `auStart`...).
class AutoScreen extends StatefulWidget {
  const AutoScreen(BuildContext _, {super.key});

  @override
  State<AutoScreen> createState() => _AutoScreenState();
}

class _AutoScreenState extends State<AutoScreen> {
  AutoInfo? _info;
  AutoConfig? _c;
  var _error = '';

  AutoStatus? _st;
  var _stAt = DateTime.now();
  String? _polledAt;

  /// Titles the last "Try" pressed, released by the next Try.
  var _tried = <String>[];
  var _taps = <int>[];
  var _msg = '';
  var _msgColor = Sx.dim;
  Timer? _bpmSend;

  /// Goes up whenever the edits are replaced, so the name fields start over.
  var _gen = 0;
  final _bpm = TextEditingController();

  AppState get _app => AppScope.read(context);
  bool get _running => _st?.running ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the status poll carries the Auto Show's status too
    final a = AppScope.of(context).status?.auto;
    if (a != null && a.at != _polledAt) {
      _polledAt = a.at;
      _setStatus(a);
    }
  }

  @override
  void dispose() {
    _bpmSend?.cancel();
    _bpm.dispose();
    super.dispose();
  }

  void _setStatus(AutoStatus? s) {
    _st = s;
    _stAt = DateTime.now();
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
        if (i.status != null) _setStatus(i.status);
        _bpm.text = bpmText(i.config.bpm);
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

  void _say(String m, [Color color = Sx.dim]) => setState(() => (_msg, _msgColor) = (m, color));

  void _undo() {
    setState(() {
      _c = _info!.config.copy();
      _gen++;
      _bpm.text = bpmText(_c!.bpm);
    });
    _app.setDirty(_tab, false);
  }

  /// Saves. [quiet] saves before a start or a "Play now" and only speaks up on failure.
  Future<bool> _save({bool quiet = false}) async {
    var ok = false;
    Future<void> took(ToolResult r) async {
      ok = r.ok;
      final saved = r.extra['config'];
      if (r.ok && saved is Map && mounted) {
        final cfg = AutoConfig.fromJson(saved.cast<String, Object?>());
        final i = _info!;
        setState(() {
          _info = AutoInfo(
            show: i.show,
            config: cfg,
            buttons: i.buttons,
            ready: i.ready,
            open: i.open,
            setup: i.setup,
            player: i.player,
            status: i.status,
          );
          _c = cfg.copy();
          _gen++;
        });
        _app.setDirty(_tab, false);
      }
    }

    if (quiet) {
      ToolResult r;
      try {
        r = await _app.client.autoSave(_c!);
      } on ApiException catch (e) {
        r = ToolResult.failed(e.message);
      }
      await took(r);
      if (!r.ok && mounted) _say(r.error, Sx.red);
      return ok;
    }
    await runSave(context, () async {
      final r = await _app.client.autoSave(_c!);
      await took(r);
      return r;
    });
    return ok;
  }

  Future<void> _start(String first) async {
    if (_dirty && !await _save(quiet: true)) return;
    final r = await _app.client.autoStart(first);
    if (!mounted) return;
    setState(() {
      _setStatus(r.status);
      _tried = [];
    });
    await _app.refresh();
    if (!r.ok && mounted) {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("The Auto Show didn't start", style: Sx.title),
          content: Text(r.error, style: const TextStyle(color: Sx.redText)),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    }
  }

  Future<void> _cmd(AutoCmd cmd, [String v = '']) async {
    final r = await _app.client.autoCmd(cmd, v);
    if (!mounted) return;
    setState(() {
      if (r.status != null) _setStatus(r.status);
    });
    if (!r.ok) _say(r.error, Sx.red);
  }

  Future<void> _stop() async {
    final r = await _app.client.autoStop();
    if (!mounted) return;
    final s = r.status;
    setState(() => _setStatus(s == null ? null : AutoStatus.fromJson({...s.toJson(), 'error': ''})));
    await _app.refresh();
  }

  void _setBpm(double v, {required bool live}) {
    final b = clampBpm(v);
    _c!.bpm = b;
    _bpm.text = bpmText(b);
    _edited();
    if (live && _running) {
      _bpmSend?.cancel();
      _bpmSend = Timer(const Duration(milliseconds: 350), () => _cmd(AutoCmd.bpm, bpmText(b)));
    }
  }

  void _tap() {
    final (taps, bpm) = tapTempo(_taps, DateTime.now().millisecondsSinceEpoch);
    _taps = taps;
    if (bpm != null) {
      _setBpm(bpm, live: true);
    } else {
      setState(() {});
    }
  }

  /// What plays in ShowXpress now, outside SETUP, at most 24 titles. Null
  /// (with a message) when that can't be read. Port of `auGrab`.
  Future<List<String>?> _grab() async {
    final r = await _app.client.remote();
    if (!r.connected) {
      _say(!r.ready && r.setup != null ? 'The ShowXpress remote is off.' : (r.error.isNotEmpty ? r.error : "ShowXpress isn't answering."), Sx.amber);
      return null;
    }
    final ts = <String>{
      for (final p in r.pressed)
        if (!_isSetup(p.page)) p.title,
    }.toList();
    if (ts.isEmpty) {
      _say("Nothing is playing in ShowXpress (SETUP page buttons don't count). Press the buttons for the look there first.", Sx.amber);
      return null;
    }
    _say('');
    return ts.take(24).toList();
  }

  Future<void> _try(AutoLook l) async {
    if (_running) {
      if (_dirty && !await _save(quiet: true)) return;
      return _cmd(AutoCmd.go, l.id);
    }
    final r = await _app.client.remotePress(l.titles, release: [for (final x in _tried) if (!l.titles.contains(x)) x]);
    if (!r.connected) {
      _say(!r.ready && r.setup != null ? 'The ShowXpress remote is off.' : (r.error.isNotEmpty ? r.error : "ShowXpress isn't answering."), Sx.amber);
      return;
    }
    _tried = [...l.titles];
    _say(
      '▶ Trying ${l.name} in ShowXpress${r.missing.isNotEmpty ? '. Not in the show: ${r.missing.join(', ')}' : ''}. Press Try on another look to switch.',
      r.missing.isNotEmpty ? Sx.red : Sx.dim,
    );
  }

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
    _say('✓ Split into $n looks of ${l.bars} bars. Save to keep it.');
  }

  Future<void> _lookAction(String k, int i) async {
    final looks = _c!.looks, l = looks[i];
    switch (k) {
      case 'up':
        looks.insert(i - 1, looks.removeAt(i));
      case 'down':
        looks.insert(i + 1, looks.removeAt(i));
      case 'copy':
        final c = l.copy()
          ..id = newLookId()
          ..name = '${l.name} copy';
        if (c.name.length > 40) c.name = c.name.substring(0, 40);
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
        _say('✓ ${l.name} now uses what\'s playing: ${ts.join(', ')}');
      case 'try':
        return _try(l);
    }
    _gen++;
    _edited();
  }

  void _newLook() {
    final c = _c!..looks.add(AutoLook(id: newLookId(), name: 'Look ${_c!.looks.length + 1}', bars: 16, on: true, titles: []));
    _gen++;
    _edited();
    _lookAction('add', c.looks.length - 1);
  }

  Future<void> _newFromPlaying() async {
    final ts = await _grab();
    if (ts == null) return;
    final c = _c!..looks.add(AutoLook(id: newLookId(), name: 'Look ${_c!.looks.length + 1}', bars: 16, on: true, titles: ts));
    _gen++;
    _edited();
    _say('✓ New look Look ${c.looks.length}: ${ts.join(', ')}. Give it a name and save.');
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
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (i != null && !i.ready && !i.player && !(_running && _st!.target == 'player')) _remoteOff(),
              if (i != null && c != null) ...[const SizedBox(height: 14), _play(app, c)],
            ],
          ),
        ),
        if (i != null && c != null) SxCard(child: _looks(i, c)),
      ],
    );
  }

  Widget _remoteOff() => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0x14FFB020),
      border: Border.all(color: const Color(0x66FFB020)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text("The ShowXpress remote is off, so the Auto Show can't press anything yet.", style: TextStyle(color: Sx.amber)),
        _mini('Turn on remote control', () => enableRemote(context, after: _load), primary: true),
      ],
    ),
  );

  Widget _bpmControls() => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('BPM', style: Sx.sub),
      SizedBox(
        width: 72,
        child: TextField(
          controller: _bpm,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: (v) => _setBpm(double.tryParse(v) ?? 124, live: true),
          onTapOutside: (_) {
            final v = double.tryParse(_bpm.text);
            if (v != null && clampBpm(v) != _c!.bpm) _setBpm(v, live: true);
          },
        ),
      ),
      _mini(_taps.length < 3 && _taps.isNotEmpty ? 'Tap (${3 - _taps.length} more)' : (_taps.length >= 3 ? 'Tap ✓' : 'Tap'), _tap, tip: 'Tap along with the beat (3 taps or more)'),
    ],
  );

  Widget _play(AppState app, AutoConfig c) {
    final s = _st, i = _info!;
    final act = [for (final l in c.looks) if (l.on && l.titles.isNotEmpty) l];
    if (s == null || !s.running) {
      return _StartPanel(
        looks: act,
        order: c.order,
        error: s?.error ?? '',
        canStart: act.isNotEmpty && (i.ready || i.player),
        bpm: _bpmControls(),
        onStart: _start,
      );
    }
    final player = s.target == 'player';
    if (player) {
      final v = '${s.bpm.round()}';
      if (_bpm.text != v && !FocusScope.of(context).hasFocus) _bpm.text = v;
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x803DDC84)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NowPlaying(status: s, received: _stAt, visible: app.tab == _tab),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _mini('Back', () => _cmd(AutoCmd.prev), tip: 'The look before'),
              _mini('Next look', () => _cmd(AutoCmd.next), primary: true),
              _mini(s.held ? 'Resume' : 'Hold', () => _cmd(s.held ? AutoCmd.resume : AutoCmd.hold)),
              _mini('Bar 1 now', () => _cmd(AutoCmd.sync), tip: 'Press on the first beat of a bar: the bar count starts again from here'),
              _bpmControls(),
              _mini('Stop', _stop),
            ],
          ),
        ],
      ),
    );
  }

  Widget _looks(AutoInfo i, AutoConfig c) {
    final looks = c.looks, act = [for (final l in looks) if (l.on && l.titles.isNotEmpty) l];
    final round = act.fold(0.0, (a, l) => a + lookSeconds(l, c.bpm));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SxHeader(
          'Looks',
          sub: looks.isEmpty
              ? null
              : '${act.length} of ${looks.length} look${looks.length > 1 ? 's' : ''} in the show · one round ≈ ${fmtSeconds(round)} at ${bpmText(c.bpm)} BPM',
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [_mini('+ New look', _newLook), _mini("New look from what's playing", _newFromPlaying)],
        ),
        if (looks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'No looks yet. A look is what plays at the same time, for example one movement, a colour and the uplights. '
              'To cycle through movements, make one look per movement. Build one in ShowXpress, then press New look from what\'s playing, '
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
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Order', style: Sx.sub),
                _Seg(
                  value: c.order,
                  options: const {'order': 'In order', 'shuffle': 'Shuffle'},
                  onPick: (v) {
                    c.order = v;
                    _edited();
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('When I stop', style: Sx.sub),
                _Menu<String>(
                  value: c.stop,
                  items: const {'keep': 'Leave the last look playing', 'off': 'Turn the look off'},
                  onPick: (v) {
                    c.stop = v;
                    _edited();
                  },
                ),
              ],
            ),
            _Check(
              'At start, turn off everything else that is playing',
              value: c.clean,
              onChanged: (v) {
                c.clean = v;
                _edited();
              },
            ),
          ],
        ),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_msg, style: TextStyle(color: _msgColor, fontSize: 13)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text('Show: ${i.show} · Auto Show settings are kept in the show folder (auto_show.json)', style: const TextStyle(color: Sx.mute, fontSize: 12)),
        ),
      ],
    );
  }
}

/// The panel when the Auto Show is not playing.
class _StartPanel extends StatefulWidget {
  const _StartPanel({required this.looks, required this.order, required this.error, required this.canStart, required this.bpm, required this.onStart});

  final List<AutoLook> looks;
  final String order;
  final String error;
  final bool canStart;
  final Widget bpm;
  final void Function(String first) onStart;

  @override
  State<_StartPanel> createState() => _StartPanelState();
}

class _StartPanelState extends State<_StartPanel> {
  String? _first;

  @override
  Widget build(BuildContext context) {
    final act = widget.looks;
    final first = act.any((l) => l.id == _first) ? _first : act.firstOrNull?.id;
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Not playing', style: TextStyle(fontFamily: Sx.display, fontSize: 20, fontWeight: FontWeight.w600)),
              Text(
                act.isNotEmpty
                    ? '${act.length} look${act.length > 1 ? 's' : ''} ready · ${widget.order == 'shuffle' ? 'shuffled' : 'in order'}'
                    : 'Add a look below to start.',
                style: Sx.sub,
              ),
              if (widget.error.isNotEmpty) Text(widget.error, style: const TextStyle(color: Sx.red, fontSize: 13)),
            ],
          ),
        ),
        widget.bpm,
        if (act.isNotEmpty)
          _Menu<String>(
            value: first!,
            items: {for (final l in act) l.id: 'Start with ${l.name}'},
            onPick: (v) => setState(() => _first = v),
          ),
        FilledButton(onPressed: widget.canStart ? () => widget.onStart(first ?? '') : null, child: const Text('Start Auto Show')),
      ],
    );
  }
}

/// One look: name, bars, in the show, actions, and its buttons.
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
    final st = s._st;
    final cur = (st?.running ?? false) && st!.lookId == l.id;
    final bars = autoBars.contains(l.bars) ? autoBars : ([...autoBars, l.bars]..sort());
    final clashes = lookClashes(l, buttons);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cur ? const Color(0x0F3DDC84) : null,
        border: Border.all(color: cur ? Sx.green : Sx.line),
        borderRadius: BorderRadius.circular(10),
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
                Text('${i + 1}', style: const TextStyle(color: Sx.dim, fontWeight: FontWeight.w700)),
                SizedBox(
                  width: 190,
                  child: TextFormField(
                    initialValue: l.name,
                    maxLength: 40,
                    decoration: const InputDecoration(counterText: ''),
                    onChanged: (v) {
                      l.name = v;
                      s._edited();
                    },
                  ),
                ),
                _Menu<int>(
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
                _mini(cur || (st?.running ?? false) ? 'Play now' : 'Try', l.titles.isEmpty ? null : () => s._lookAction('try', i)),
                _mini('↑', i > 0 ? () => s._lookAction('up', i) : null, tip: 'Move up'),
                _mini('↓', i < count - 1 ? () => s._lookAction('down', i) : null, tip: 'Move down'),
                _mini('Copy', () => s._lookAction('copy', i)),
                _mini('Delete', () => s._lookAction('del', i)),
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
                    Text(
                      clashes.map((c) => '${c.$1} plays one button at a time, only ${c.$2.last} of these ${c.$2.length} would play.').join(' '),
                      style: const TextStyle(color: Sx.amber, fontSize: 13),
                    ),
                    _mini('Split into one look each', () => s._askSplit(i), primary: true),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (l.titles.isEmpty) const Text('No buttons yet.', style: Sx.sub),
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
                _mini('+ Button', () => s._lookAction('add', i)),
                _mini("What's playing", () => s._lookAction('grab', i), tip: 'Use the buttons playing in ShowXpress now'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          border: Border.all(color: bad ? Sx.red : Sx.line2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: TextStyle(fontSize: 13, color: bad ? Sx.redText : Sx.text)),
            InkWell(
              onTap: onRemove,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Text('×', style: TextStyle(color: Sx.dim, fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two or more buttons, one of them on.
class _Seg extends StatelessWidget {
  const _Seg({required this.value, required this.options, required this.onPick});

  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final e in options.entries)
        InkWell(
          onTap: () => onPick(e.key),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: e.key == value ? const Color(0x1AA3E635) : null,
              border: Border.all(color: e.key == value ? Sx.accent : Sx.line),
            ),
            child: Text(e.value, style: TextStyle(fontSize: 13, color: e.key == value ? Sx.accent : Sx.text2)),
          ),
        ),
    ],
  );
}

class _Menu<T> extends StatelessWidget {
  const _Menu({required this.value, required this.items, required this.onPick});

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: Sx.well,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        isDense: true,
        dropdownColor: Sx.panel,
        style: const TextStyle(fontFamily: Sx.body, fontSize: 13.5, color: Sx.text),
        value: items.containsKey(value) ? value : null,
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) {
          if (v != null) onPick(v);
        },
      ),
    ),
  );
}

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
          width: 28,
          height: 28,
          child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        ),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: const TextStyle(fontSize: 13, color: Sx.text2))),
      ],
    ),
  );
}
