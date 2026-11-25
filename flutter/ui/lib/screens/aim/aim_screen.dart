import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../remote/remote_row.dart';
import 'aim_widgets.dart';
import 'live_aim_screen.dart';

/// The Floor and Room words of the old page's `AIMTXT`.
class _Words {
  const _Words({required this.title, required this.how, required this.depth, required this.size, required this.svg});

  final String title;
  final List<(String, String)> how;
  final String depth, size, svg;
}

const _words = {
  AimMode.floor: _Words(
    title: "Dance floor: tonight's aims",
    how: [
      (
        'STEP 1 · CENTER',
        "Aim every head at the center of tonight's dancefloor, or just *one head per T-bar*: the head next to it gets the same aim (unless you aim that one too).",
      ),
      ('STEP 2 · CORNER', 'Optional: aim a head at the same corner (front-left from the DJ) to set its size. A copied head gets this too.'),
      ('THEN', 'Save, close ShowXpress, press Refresh below, check the heads and Apply. *DF CHECK* comes on by itself when ShowXpress opens again.'),
    ],
    depth: 'Depth',
    size: '100% = patterns reach the corners you aimed. Lower keeps them a bit inside the floor.',
    svg: 'dashed = dancefloor · amber = patterns',
  ),
  AimMode.room: _Words(
    title: 'Room: AROUND ROOM for tonight',
    how: [
      ('STEP 1 · CENTER', 'Aim every head at the middle of where AROUND ROOM should sweep (the walls around the room).'),
      ('STEP 2 · CORNER', 'Optional: aim a head at the front-left edge of that sweep (from the DJ) to set its size.'),
      ('THEN', 'Save, close ShowXpress, press Refresh below and Apply. *ROOM CHECK* comes on by itself when ShowXpress opens again.'),
    ],
    depth: 'Height',
    size: '100% = AROUND ROOM reaches the edge you aimed. Width = across the room, Height = up and down the walls.',
    svg: 'dashed = what you aimed · amber = AROUND ROOM',
  ),
};

/// The buttons the remote row turns on, per mode (the old `remSets`). The
/// first one goes on by itself when the tab opens.
const _remoteSets = {
  AimMode.floor: [
    RemoteSet('DF AIM (ADJUST)', ['DF AIM (ADJUST)']),
    RemoteSet('DF CHECK 140 + 251', ['DF CHECK 140', 'DF CHECK 251']),
  ],
  AimMode.room: [
    RemoteSet('ROOM AIM (ADJUST)', ['ROOM AIM (ADJUST)']),
    RemoteSet('ROOM CHECK', ['ROOM CHECK']),
  ],
};

enum _Tone { ok, warn, err, queued }

/// The result card under the tabs, the old page's `#result`.
class _Result {
  const _Result(this.tone, this.title, {this.text = const [], this.items = const [], this.warnings = const [], this.log = ''});

  final _Tone tone;
  final String title;

  /// Paragraphs. `*` marks bold, as in [boldText].
  final List<String> text;
  final List<String> items;
  final List<String> warnings;

  /// The tool's full report.
  final String log;
}

int _clamp(num v) => v.round().clamp(20, 300);

String _sign(int v) => '${v > 0 ? '+' : ''}$v';

/// Aim Movers: fit the dance floor patterns and AROUND ROOM to tonight's
/// venue from the aims in the ADJUST scene, or aim live from here.
///
/// Port of the old page's `#v-aim` view and its script.
class AimScreen extends StatefulWidget {
  const AimScreen(BuildContext _, {super.key});

  @override
  State<AimScreen> createState() => _AimScreenState();
}

class _AimScreenState extends State<AimScreen> {
  var _mode = AimMode.floor;
  final _cache = <AimMode, AimPreview>{};
  AimPreview? _p;
  var _error = '';
  var _loading = true;

  /// Modes whose sizes were taken from the show (the old `LD`).
  final _sized = <AimMode>{};
  var _w = 100, _d = 100;
  var _linked = true;

  /// What the screen is waiting for, shown over everything. '' when idle.
  var _busy = '';
  _Result? _result;

  SxClient get _client => AppScope.read(context).client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = _mode;
    setState(() => _loading = true);
    AimPreview? p;
    var err = '';
    try {
      p = await _client.aimPreview(m);
    } on ApiException catch (e) {
      err = e.message;
    }
    if (!mounted || _mode != m) return;
    setState(() {
      _loading = false;
      _p = p;
      _error = err;
      if (p == null) return;
      _cache[m] = p;
      if (_sized.add(m)) {
        _linked = p.lastW == p.lastD;
        _w = _clamp(p.lastW);
        _d = _clamp(p.lastD);
      }
    });
  }

  void _switch(AimMode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      _p = _cache[m];
      _error = '';
      _result = null;
      _sized.remove(m);
    });
    _load();
  }

  void _setW(num v) => setState(() {
    _w = _clamp(v);
    if (_linked) _d = _w;
  });

  void _setD(num v) => setState(() {
    _d = _clamp(v);
    if (_linked) _w = _d;
  });

  Future<T> _during<T>(String text, Future<T> Function() work) async {
    setState(() => _busy = text);
    try {
      return await work();
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<ToolResult> _call(Future<ToolResult> Function() f) async {
    try {
      return await f();
    } on ApiException {
      return const ToolResult(ok: false, error: 'Lost connection.');
    }
  }

  // ---- results, the old `showResult` for 'apply', 'home' and 'roominstall'

  _Result _queued(ToolResult r) => _Result(
    _Tone.queued,
    'Queued: ${r.extra['label'] ?? ''}',
    text: [
      "${r.extra['replaced'] == true ? 'Replaces what was queued for it before. ' : ''}Nothing is changed yet. Keep setting up. When you're done, *save and close ShowXpress*: SX Studio does everything in the list at the top"
          "${AppScope.read(context).status?.queue.reopen ?? true ? ' and opens ShowXpress again' : ''}.",
    ],
  );

  _Result _applied(ToolResult r, {required bool home}) {
    final lines = r.out.split(RegExp(r'\r?\n'));
    final total = lines.firstWhere((l) => l.contains('movement scenes checked'), orElse: () => '').trim().replaceFirst(RegExp(r'^->\s*'), '');
    final changed = [
      for (final l in lines)
        if (RegExp(r'\s[1-9]\d* values changed').hasMatch(l)) l.trim().replaceAll(RegExp(r'\s{2,}'), ' · '),
    ];
    final warn = [
      for (final l in lines)
        if (l.contains('WARNING')) l.replaceFirst(RegExp(r'^\s*WARNING:\s*'), ''),
    ];
    final check = home
        ? ''
        : _mode == AimMode.room
        ? 'When ShowXpress opens, *ROOM CHECK* comes on by itself (with the remote on). The beams should trace the edge you aimed.'
        : 'When ShowXpress opens, *DF CHECK 140* + *DF CHECK 251* come on by themselves (with the remote on). The beams should trace the floor corners.';
    return _Result(
      _Tone.ok,
      home ? 'Everything is back to normal' : 'Applied to the show',
      text: ['$total. $check'],
      items: changed,
      warnings: warn,
      log: r.out,
    );
  }

  _Result _installed(ToolResult r) {
    final lines = r.out.split(RegExp(r'\r?\n'));
    final same = lines.any((l) => l.contains('nothing to change'));
    final items = [
      for (final l in lines)
        if (RegExp(r'^ {2}\S').hasMatch(l) && !RegExp(r'^(same\s|live\.ini saved|nothing to change)').hasMatch(l.trim()))
          l.trim().replaceFirst(RegExp(r'^CHANGED\s+'), ''),
    ];
    return _Result(
      _Tone.ok,
      same ? 'Nothing needed changing' : 'ROOM buttons added to the SETUP page',
      items: items,
      text: const ['Open ShowXpress to use it.'],
      log: r.out,
    );
  }

  _Result _failed(ToolResult r, String title) => _Result(_Tone.err, title, text: [r.error, 'Nothing was changed.'], log: r.out);

  /// Runs a save, shows its result, and reads the show again.
  Future<void> _save(String busy, Future<ToolResult> Function() call, _Result Function(ToolResult) shown, {String failed = 'Not applied'}) async {
    final r = await _during(busy, () => _call(call));
    if (!mounted) return;
    setState(() => _result = !r.ok ? _failed(r, failed) : (r.extra['queued'] == true ? _queued(r) : shown(r)));
    await AppScope.read(context).refresh();
    await _load();
  }

  Future<void> _apply() async {
    final p = _p!, wrong = p.heads.where((h) => h.warn.isNotEmpty).length;
    var force = false;
    if (wrong > 0) {
      final go = await askUser(
        context,
        '$wrong head(s) look wrong',
        Text('Their aims in ${p.aimTitle} look far off the floor, usually step 1 / step 2 not aimed yet.\n\nApply anyway?'),
        'Apply anyway',
      );
      if (!go) return;
      force = true;
    }
    final mode = _mode;
    await _save('Applying to the show...', () => _client.aimApply(mode, w: _w, d: _d, force: force), (r) => _applied(r, home: false));
  }

  Future<void> _home() async {
    final go = await askUser(
      context,
      'Reset to normal?',
      Text('All heads go back to the normal center, size 100%, and the ${_p!.aimTitle} scene is reset. Your shapes are kept.'),
      'Reset',
    );
    if (!go) return;
    final mode = _mode;
    await _save('Resetting...', () => _client.aimHome(mode), (r) {
      _sized.remove(mode);
      return _applied(r, home: true);
    });
  }

  Future<void> _install() => _save('Adding the ROOM buttons...', _client.aimInstall, (r) {
    _sized.remove(AimMode.room);
    return _installed(r);
  }, failed: 'Not saved');

  // ---- live aim, the old `lvGo`, `sxCloseLive` and `lvResult`

  /// Closes ShowXpress for live output. Returns null to stop, or whether it was open.
  Future<bool?> _closeSx() async {
    final app = AppScope.read(context);
    await app.refresh();
    if (!mounted || !app.sxOpen) return false;
    final go = await askUser(
      context,
      'Close ShowXpress to aim live?',
      boldText(
        'Only one program can use the DMX interface, so ShowXpress closes while you aim. *Save your show first* if you changed anything. If ShowXpress asks, answer it there.\n\nIt opens again when you finish.',
      ),
      'Close and aim live',
    );
    if (!go) return null;
    // `live` tells the engine not to run the save queue (and reopen ShowXpress) now
    final r = await _call(() => _client.run('/api/sx/close', {'live': true}));
    if (!r.ok) {
      if (mounted) setState(() => _result = _failed(r, "Live aim didn't start"));
      return null;
    }
    final closed = await _during('Waiting for ShowXpress to close... (save it if it asks)', () async {
      final t0 = DateTime.now();
      while (DateTime.now().difference(t0) < const Duration(seconds: 120)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        try {
          if (!(await _client.status()).open) return true;
        } on ApiException {
          // keep waiting
        }
      }
      return false;
    });
    if (!mounted) return null;
    if (!closed) {
      await _call(_client.liveStop);
      setState(
        () => _result = _failed(
          const ToolResult(ok: false, error: 'ShowXpress is still open. Close it (save if it asks), then press Aim live again.'),
          "Live aim didn't start",
        ),
      );
      return null;
    }
    await _during('ShowXpress closed. Waiting for it to let go of the interface...', () => Future<void>.delayed(const Duration(milliseconds: 2500)));
    return true;
  }

  Future<LiveStart> _startLive(AimMode mode) async {
    LiveStart r;
    try {
      r = await _during('Connecting to the DMX interface...', () => _client.liveStart(mode: mode));
    } on ApiException {
      r = const LiveStart(ok: false, error: 'Lost connection.');
    }
    // NovaStar only exists on Windows; the engine never asks for it here
    return r;
  }

  Future<void> _goLive() async {
    final reopen = await _closeSx();
    if (reopen == null || !mounted) return;
    final mode = _mode;
    final r = await _startLive(mode);
    if (!mounted) return;
    if (!r.ok) {
      await _call(_client.liveStop);
      final err = '${r.error}${reopen ? ' ShowXpress is closed now. Press Launch ShowXpress at the top to open it again.' : ''}';
      setState(() => _result = _failed(ToolResult(ok: false, error: err), "Live aim didn't start"));
      return;
    }
    final exit = await openLiveAim(context, mode: mode, start: r, reopen: reopen);
    if (!mounted) return;
    final app = AppScope.read(context)..setDirty('aim', false);
    final aims = exit?.aims;
    if (aims == null) {
      await _during('Stopping the DMX output...', () => _call(_client.liveStop));
      if (exit?.reopen ?? false) await _call(_client.sxLaunch);
      await app.refresh();
      return;
    }
    final n = aims.length;
    LiveSaveResult s;
    try {
      s = await _during(
        'Saving $n aim${n > 1 ? 's' : ''} and applying them to the show...',
        () => _client.liveSave(mode: mode, aims: aims, w: _w, d: _d, reopen: exit!.reopen),
      );
    } on ApiException {
      s = const LiveSaveResult(ok: false, saved: false, applied: false, error: 'Lost connection.', out: '', applyError: '');
    }
    if (!mounted) return;
    final reo = s.reopened
        ? 'ShowXpress is opening again.'
        : s.reopenError.isNotEmpty
        ? "ShowXpress didn't open: ${s.reopenError}"
        : '';
    setState(() {
      if (s.ok && s.applied) {
        final a = _applied(ToolResult(ok: true, out: s.out), home: false);
        _result = _Result(
          _Tone.ok,
          'Live aims saved and applied',
          text: [...a.text, if (reo.isNotEmpty) reo],
          items: a.items,
          warnings: a.warnings,
          log: s.out,
        );
      } else if (s.ok) {
        _result = _Result(
          _Tone.warn,
          'Aims saved, not applied yet',
          text: [
            "The aims are saved in *${mode.aimTitle}*, but applying them to the show didn't work: ${s.applyError.isEmpty ? 'unknown error' : s.applyError}",
            'Check the heads above, then press *Apply to show*.',
            if (reo.isNotEmpty) reo,
          ],
          log: s.out,
        );
      } else {
        _result = _Result(
          _Tone.err,
          'Live aims not saved',
          text: [s.error.isEmpty ? 'Unknown error.' : s.error, 'Nothing was changed.', if (reo.isNotEmpty) reo],
          log: s.out,
        );
      }
    });
    await app.refresh();
    await _load();
  }

  // ---- drawing

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = _p, ok = p != null && _error.isEmpty;
    final words = _words[_mode]!;
    final hint = !ok
        ? ''
        : app.sxOpen
        ? "ShowXpress is open. This is queued and done as soon as you save and close ShowXpress."
        : '${_mode == AimMode.room ? 'Writes to ${p.targets.where((t) => !t.contains('CHECK')).join(', ').ifEmpty('AROUND ROOM')}' : 'Writes to all dancefloor movement scenes'}'
              ' + CENTER SPOT (step 1 aims). Nothing is changed until you press Apply.';
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final body = ScreenBody(
      bar: SaveBar(
        hint: hint,
        actions: [
          OutlinedButton(onPressed: ok ? _home : null, child: Text(phone ? 'Reset' : 'Reset to normal')),
          FilledButton(onPressed: ok ? _apply : null, child: Text(phone ? 'Apply' : 'Apply to show')),
        ],
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Seg<AimMode>(value: _mode, options: const {AimMode.floor: 'Dance Floor', AimMode.room: 'Room'}, onChanged: _switch),
        ),
        if (_result != null) _resultCard(_result!),
        _aimsCard(words, p),
        _sizeCard(words),
      ],
    );
    return Stack(
      children: [
        body,
        if (_busy.isNotEmpty) ...[
          ModalBarrier(color: Sx.bg.withValues(alpha: .7), dismissible: false),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              decoration: BoxDecoration(
                color: Sx.card,
                border: Border.all(color: Sx.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _busy,
                style: TextStyle(fontWeight: FontWeight.w600, color: Sx.text),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _aimsCard(_Words words, AimPreview? p) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final how = [
      for (final (head, text) in words.how)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Sx.panel,
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                head,
                style: TextStyle(color: Sx.accent, fontSize: 12, letterSpacing: .6, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              boldText(text, style: TextStyle(color: Sx.text2, fontSize: 13)),
            ],
          ),
        ),
    ];
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(words.title, style: Sx.title),
          const SizedBox(height: 4),
          boldText('Read from the scene *${_mode.aimTitle}* in ShowXpress.', style: Sx.sub),
          const SizedBox(height: 14),
          if (phone)
            for (final h in how) Padding(padding: const EdgeInsets.only(bottom: 10), child: h)
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, h) in how.indexed) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: h)],
                ],
              ),
            ),
          if (!phone) const SizedBox(height: 14),
          // the old `#aimrem`: SX Studio presses the ADJUST scene or the CHECK buttons
          RemoteRow(tab: 'aim', sets: _remoteSets[_mode]!),
          _liveCall(phone),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _summary(p)),
              OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh')),
            ],
          ),
          if (p != null && _error.isEmpty) ..._heads(p),
          if (p != null && _error.isEmpty) ..._boxes(p),
        ],
      ),
    );
  }

  Widget _liveCall(bool phone) {
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Aim live. ',
            style: TextStyle(color: Sx.text, fontWeight: FontWeight.w600),
          ),
          const TextSpan(
            text:
                'Aim from here instead of ShowXpress: slow, fine mouse control, and the real head follows as you drag. ShowXpress closes while you aim and opens again when you finish.',
          ),
        ],
      ),
      style: TextStyle(color: Sx.text2, fontSize: 13),
    );
    final button = FilledButton.icon(
      onPressed: _p == null || _error.isNotEmpty ? null : _goLive,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 14, fontWeight: FontWeight.w700),
      ),
      icon: const Icon(Icons.gps_fixed, size: 16),
      label: const Text('Aim live'),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: Sx.tint(Sx.blue, radius: 12).copyWith(color: Sx.blue.withValues(alpha: .07)),
      child: phone
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [text, const SizedBox(height: 10), button])
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 14),
                button,
              ],
            ),
    );
  }

  Widget _summary(AimPreview? p) {
    final style = TextStyle(fontSize: 13, color: Sx.dim);
    if (_error.isNotEmpty) return Text(_error, style: style.copyWith(color: Sx.red));
    if (p == null || _loading && p.heads.isEmpty) return Text('Loading...', style: style);
    final hs = p.heads, a = hs.where((h) => h.is140).length, b = hs.length - a;
    final moved = hs.where((h) => h.op != 0 || h.ot != 0).length, sized = hs.where((h) => h.sized).length;
    final cp = hs.where((h) => h.copyFrom.isNotEmpty).length, wrong = hs.where((h) => h.warn.isNotEmpty).length;
    TextSpan n(int v) => TextSpan(
      text: '$v',
      style: TextStyle(color: Sx.text, fontWeight: FontWeight.w600),
    );
    return Text.rich(
      TextSpan(
        children: [
          n(a),
          const TextSpan(text: ' × 140SR'),
          if (b > 0) ...[const TextSpan(text: ' · '), n(b), const TextSpan(text: ' × 251SR')],
          const TextSpan(text: '   ·   '),
          n(moved),
          const TextSpan(text: ' re-aimed'),
          if (cp > 0) ...[const TextSpan(text: ' ('), n(cp), const TextSpan(text: ' copied from the head next to it on the T-bar)')],
          const TextSpan(text: ' · '),
          n(sized),
          const TextSpan(text: ' with a corner set'),
          if (wrong > 0) ...[
            const TextSpan(text: ' · '),
            TextSpan(
              text: '$wrong look wrong',
              style: TextStyle(color: Sx.red, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
      style: style,
    );
  }

  List<Widget> _heads(AimPreview p) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    Widget group(String name, List<AimHeadFix> hs) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 22, 0, 8),
          child: Text(name, style: Sx.label),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final min = phone ? 100.0 : 118.0, cols = ((c.maxWidth + 8) / (min + 8)).floor().clamp(1, 99);
            final w = (c.maxWidth - 8 * (cols - 1)) / cols;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final h in hs) SizedBox(width: w, child: _HeadTile(h))],
            );
          },
        ),
      ],
    );
    final a = p.heads.where((h) => h.is140).toList(), b = p.heads.where((h) => !h.is140).toList();
    return [group('140SR', a), if (b.isNotEmpty) group('251SR', b)];
  }

  List<Widget> _boxes(AimPreview p) {
    final wrong = p.heads.where((h) => h.warn.isNotEmpty).toList(), ins = p.install;
    final style = TextStyle(color: Sx.redText, fontSize: 13);
    Widget box(Widget child) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: Sx.tint(Sx.red).copyWith(border: Border.all(color: Sx.red.withValues(alpha: .35))),
      child: DefaultTextStyle.merge(style: style, child: child),
    );
    return [
      if (wrong.isNotEmpty) box(boldText('*Check these heads:* ${wrong.map((h) => '${h.label}: ${h.warn}').join('\n')}', style: style, bold: Sx.redText)),
      if (_mode == AimMode.room && ins != null && (!ins.aim || !ins.check))
        box(
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              boldText("*ROOM AIM (ADJUST)* and *ROOM CHECK* aren't on the SETUP page yet.", style: style, bold: Sx.redText),
              MiniButton('Add them to the SETUP page', primary: true, onPressed: _install),
            ],
          ),
        ),
    ];
  }

  Widget _sizeCard(_Words words) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    Widget slider(String label, int v, ValueChanged<num> set) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              _NumBox(value: v, onChanged: set),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Sx.accent,
              inactiveTrackColor: Sx.line,
              thumbColor: Sx.accent,
              overlayShape: SliderComponentShape.noOverlay,
              trackHeight: 4,
            ),
            child: Slider(value: v.toDouble(), min: 20, max: 300, divisions: 280, onChanged: set),
          ),
        ],
      ),
    );
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        slider('Width', _w, _setW),
        slider(words.depth, _d, _setD),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            CheckRow(
              'Same both ways',
              value: _linked,
              onChanged: (v) {
                _linked = v;
                if (v) _setW(_w);
                setState(() {});
              },
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in const [80, 90, 100, 110, 120])
                  _SizeChip(
                    '$v',
                    onTap: () {
                      _setW(v);
                      if (!_linked) _setD(v);
                    },
                  ),
              ],
            ),
          ],
        ),
      ],
    );
    final picture = AspectRatio(
      aspectRatio: 300 / 210,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Sx.well,
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(
          painter: _SizePainter(w: _w, d: _d, legend: words.svg),
        ),
      ),
    );
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Overall pattern size', style: Sx.title),
          const SizedBox(height: 4),
          Text(words.size, style: Sx.sub),
          const SizedBox(height: 4),
          if (phone) ...[
            controls,
            const SizedBox(height: 12),
            picture,
          ] else
            Row(
              children: [
                Expanded(child: controls),
                const SizedBox(width: 22),
                SizedBox(width: 300, child: picture),
              ],
            ),
        ],
      ),
    );
  }

  Widget _resultCard(_Result r) {
    final (color, icon) = switch (r.tone) {
      _Tone.ok => (Sx.green, Icons.check),
      _Tone.warn => (Sx.amber, Icons.warning_amber_rounded),
      _Tone.err => (Sx.red, Icons.close),
      _Tone.queued => (Sx.amber, Icons.hourglass_empty),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: Sx.card,
        border: Border.all(color: color.withValues(alpha: r.tone == _Tone.err ? .5 : .4)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(r.title, style: Sx.title)),
              if (r.log.trim().isNotEmpty) MiniButton('Full details', onPressed: () => showReport(context, r.title, r.log)),
              const SizedBox(width: 6),
              MiniButton('Close', onPressed: () => setState(() => _result = null)),
            ],
          ),
          for (final (i, t) in r.text.indexed)
            if (t.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: boldText(t, style: i == 0 && r.tone == _Tone.err ? TextStyle(color: Sx.text, fontSize: 14) : Sx.sub),
              ),
          if (r.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final l in r.items) Text('·  $l', style: TextStyle(color: Sx.text2, fontSize: 13))],
              ),
            ),
          if (r.warnings.isNotEmpty) ErrorBox(r.warnings.join('\n')),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// One head, the old `.tile`: center offset, size, and the T-bar copy.
class _HeadTile extends StatelessWidget {
  const _HeadTile(this.h);

  final AimHeadFix h;

  @override
  Widget build(BuildContext context) {
    final moved = h.op != 0 || h.ot != 0, warn = h.warn.isNotEmpty, copied = h.copyFrom.isNotEmpty;
    final l = TextStyle(color: Sx.dim, fontSize: 12.5), v = TextStyle(color: Sx.text, fontSize: 12.5);
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: warn ? Sx.red.withValues(alpha: .07) : Sx.panel,
        border: Border.all(
          color: warn
              ? Sx.red
              : moved
              ? Sx.blue.withValues(alpha: .45)
              : Sx.line,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: h.label),
                if (warn)
                  TextSpan(
                    text: ' !',
                    style: TextStyle(color: Sx.red),
                  ),
              ],
            ),
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Sx.text),
          ),
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'center ', style: l),
                TextSpan(text: moved ? '${_sign(h.op)} / ${_sign(h.ot)}' : 'normal', style: v),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'size ', style: l),
                TextSpan(
                  text: h.sized ? '${h.kp}% × ${h.kt}%' : 'normal',
                  style: h.sized ? v.copyWith(color: Sx.accent) : v,
                ),
              ],
            ),
          ),
          if (copied)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Icon(Icons.swap_horiz, size: 12, color: Sx.blue),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text('same as ${h.copyFrom}', style: TextStyle(fontSize: 11, color: Sx.blue)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    final tip = warn
        ? h.warn
        : copied
        ? 'Not aimed by you. It gets the same aim as ${h.copyFrom} on its T-bar. Aim it yourself and it keeps its own.'
        : '';
    return tip.isEmpty ? tile : Tooltip(message: tip, child: tile);
  }
}

/// The number box beside a size slider, the old `.num`.
class _NumBox extends StatefulWidget {
  const _NumBox({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<num> onChanged;

  @override
  State<_NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<_NumBox> {
  late final _c = TextEditingController(text: '${widget.value}');
  final _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumBox old) {
    super.didUpdateWidget(old);
    if (!_f.hasFocus && _c.text != '${widget.value}') _c.text = '${widget.value}';
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  void _commit() {
    widget.onChanged(num.tryParse(_c.text) ?? 100);
    _c.text = '${widget.value}';
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 76,
    child: TextField(
      controller: _c,
      focusNode: _f,
      textAlign: TextAlign.right,
      keyboardType: TextInputType.number,
      style: TextStyle(fontSize: 15, color: Sx.text),
      onSubmitted: (_) => _commit(),
    ),
  );
}

class _SizeChip extends StatelessWidget {
  const _SizeChip(this.text, {required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(99),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: Sx.text)),
    ),
  );
}

/// The size picture: the floor (dashed) and the patterns at [w] x [d]
/// percent (amber), in the old SVG's 300 x 210 units.
class _SizePainter extends CustomPainter {
  _SizePainter({required this.w, required this.d, required this.legend});

  final int w, d;
  final String legend;

  /// So a theme switch repaints.
  final light = Sx.isLight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)))
      ..scale(size.width / 300, size.height / 210);
    void text(String s, double y) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(color: Sx.mute, fontSize: 10, fontFamily: Sx.body),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(150 - tp.width / 2, y - tp.height + 2));
    }

    text('DJ / front', 16);
    final floor = RRect.fromRectAndRadius(const Rect.fromLTWH(60, 45, 180, 120), const Radius.circular(4));
    final dash = Paint()
      ..color = Sx.mute
      ..style = PaintingStyle.stroke;
    for (final m in (Path()..addRRect(floor)).computeMetrics()) {
      for (var t = 0.0; t < m.length; t += 9) {
        canvas.drawPath(m.extractPath(t, t + 5), dash);
      }
    }
    final pat = RRect.fromRectAndRadius(Rect.fromCenter(center: const Offset(150, 105), width: 180 * w / 100, height: 120 * d / 100), const Radius.circular(6));
    canvas
      ..drawRRect(pat, Paint()..color = Sx.amber.withValues(alpha: .16))
      ..drawRRect(
        pat,
        Paint()
          ..color = Sx.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      )
      ..drawCircle(const Offset(150, 105), 4, Paint()..color = Sx.amber);
    text(legend, 200);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SizePainter old) => old.w != w || old.d != d || old.legend != legend || old.light != light;
}
