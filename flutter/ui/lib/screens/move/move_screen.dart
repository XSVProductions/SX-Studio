import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../page_store.dart';
import '../../sx_control.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'move_canvas.dart';
import 'move_parts.dart';
import 'move_preview.dart';

/// Movement Editor: change a Generator movement (.gpj), its shape, cycle,
/// shift and transition, the other channels' graphs and the heads' aim and
/// size, and see it on the lights.
///
/// The screen keeps a working copy ([MoveState]); Save sends only what differs
/// from the file. Port of the old page's Movement Editor (`renderMoves`,
/// `mvOpen`, `renderMove` and the rest of the `mv` functions in `df_aim_gui.ps1`).
class MoveScreen extends StatefulWidget {
  const MoveScreen(BuildContext _, {super.key});

  @override
  State<MoveScreen> createState() => _MoveScreenState();
}

/// A scene that can light the movement while it plays on the rig.
typedef _Scene = ({String file, String name});

const _liteKey = 'sxh_mvlite';

class _MoveScreenState extends State<MoveScreen> {
  late final AppState _app = AppScope.read(context);

  // The list of movements.
  MoveList? _list;
  var _listErr = '';
  var _query = '';
  var _loading = false;

  // The open movement: the file, the working copy, the copy as saved, and the steps to go back.
  MoveDoc? _doc;
  late MoveState _w, _w0;
  final _hist = <MoveState>[];
  var _sec = 0, _pt = -1;
  MoveView _view = wholeRange;
  var _err = '';
  MoveBackups? _bk;

  /// Goes up while a drag on the canvas moves points or a point is picked.
  /// Only the canvas and the settings beside it follow it, as the old
  /// `mvMove` redrew only those two. The rest catches up when the drag ends.
  final _live = ValueNotifier(0);

  // The clock the movement plays on (shared by the drawing and the lights).
  var _t0 = DateTime.now();
  var _hold = false;
  var _holdT = 0.0;

  // On the lights.
  MovePreview? _pv;
  var _reo = false;
  var _busy = '';
  List<_Scene>? _scenes;
  var _lite = '';
  ({String f, Map<int, int> v})? _liteV;

  @override
  void initState() {
    super.initState();
    _app.addListener(_tabChanged);
    HardwareKeyboard.instance.addHandler(_key);
    _made = _app.madeScenes.length;
    _load();
    _loadScenes();
  }

  /// Another tab asked to open a movement here (the SX Player's "Edit
  /// movement"): like tapping it in the list, so unsaved edits are asked about
  /// first. Port of the old `setTab('move'); mvOpen(f)`.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = AppScope.of(context).takeFile('move');
    if (f == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open(f);
    });
  }

  @override
  void dispose() {
    _app.removeListener(_tabChanged);
    HardwareKeyboard.instance.removeHandler(_key);
    unawaited(_pv?.stop());
    _live.dispose();
    _clockTimer?.cancel();
    _clock.dispose();
    super.dispose();
  }

  /// Leaving the tab stops the movement on the lights.
  void _tabChanged() {
    _syncClock();
    if (_app.tab != 'move' && _pv != null) _pvStop(_reo);
    if (_app.madeScenes.length != _made) {
      _made = _app.madeScenes.length;
      unawaited(_loadScenes());
    }
  }

  /// How many looks were made when "Light it with" was read. A new look is a
  /// new scene to pick (old `MLS=null`).
  var _made = 0;

  double _now() => _hold ? _holdT : DateTime.now().difference(_t0).inMilliseconds.toDouble();

  /// Ticks 30 times a second while a movement is open on the tab on show and
  /// not paused, so the heads on the canvas move (the old `mvAnim`). A tick
  /// repaints the canvas only.
  final _clock = ValueNotifier(0);
  Timer? _clockTimer;

  /// Starts or stops [_clock] to match what is on show.
  void _syncClock() {
    final run = mounted && _doc != null && !_hold && _app.tab == 'move';
    if (!run) {
      _clockTimer?.cancel();
      _clockTimer = null;
    } else {
      _clockTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _clock.value++);
    }
  }

  bool get _ro => _doc?.readonly.isNotEmpty ?? true;

  bool get _dirty => _doc != null && !_ro && _w != _w0;

  void _markDirty() => _app.setDirty('move', _dirty);

  // ---------------------------------------------------------------- loading

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final l = await _app.client.moves();
      if (!mounted) return;
      setState(() {
        _list = l;
        _listErr = '';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _list = null;
        _listErr = e.message;
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  /// The scenes for "Light it with". Port of `mvLiteList`.
  Future<void> _loadScenes() async {
    final prefs = await openPageStore();
    List<_Scene> got;
    try {
      got = await _app.client.get('/api/scenes', (j) => j.list('scenes', (s) => (file: s.str('file'), name: s.str('name'))));
    } on ApiException {
      got = const [];
    } on FormatException {
      got = const [];
    }
    if (!mounted) return;
    final cur = _lite.isNotEmpty ? _lite : prefs.get(_liteKey) ?? '';
    setState(() {
      _scenes = got;
      _lite = got.any((s) => s.file == cur) ? cur : '';
    });
  }

  Future<bool> _leaveOk([String title = 'Leave this movement?']) async {
    final d = _doc;
    if (d == null || !_dirty) return true;
    return moveAsk(context, title, [
      const TextSpan(text: 'Your changes to '),
      moveBold(d.name),
      const TextSpan(text: ' are not saved yet. They will be lost.'),
    ], 'Leave it');
  }

  /// Opens movement [f]. With [keep] (after a save, revert or reload) the
  /// section, point and zoom stay. Port of `mvOpen`.
  Future<void> _open(String f, {bool keep = false}) async {
    if (!keep && !await _leaveOk()) return;
    if (!keep || _doc?.file != f) await _pvStop(_reo);
    MoveDoc r;
    try {
      r = await _app.client.move(f);
    } on ApiException catch (e) {
      if (mounted) setState(() => _err = e.message);
      return;
    }
    if (!mounted) return;
    final old = _doc;
    final was = keep && old != null && old.file == f ? (s: old.secs.elementAtOrNull(_sec)?.name, p: _pt, v: _view) : null;
    setState(() {
      _err = '';
      _doc = r;
      _reset();
      _sec = math.max(0, r.secs.indexWhere((s) => s.isShape));
      _pt = -1;
      if (was != null) {
        final i = r.secs.indexWhere((s) => s.name == was.s);
        if (i >= 0) _sec = i;
        _pt = was.p < _w.secs[_sec].pts.length ? was.p : -1;
        _view = was.v;
      } else {
        _view = moveFit(r, _w);
      }
      _t0 = DateTime.now();
      _hold = false;
      _bk = null;
    });
    _markDirty();
    _loadBackups();
  }

  void _reset() {
    _w = _w0 = MoveState.of(_doc!);
    _hist.clear();
  }

  Future<void> _back() async {
    if (!await _leaveOk()) return;
    await _pvStop(_reo);
    setState(() {
      _doc = null;
      _bk = null;
      _err = '';
    });
    _markDirty();
    if (_list == null) _load();
  }

  Future<void> _reload() async {
    final d = _doc;
    if (d == null) return _load();
    if (_dirty) {
      final yes = await moveAsk(context, 'Reload the movement?', [const TextSpan(text: 'Your changes that are not saved yet will be lost.')], 'Reload');
      if (!yes) return;
    }
    await _open(d.file, keep: true);
  }

  // ---------------------------------------------------------------- editing

  /// Makes [next] the working copy, keeping the one before as a step to go back to.
  void _set(MoveState next) {
    _hist.add(_w);
    if (_hist.length > 200) _hist.removeAt(0);
    setState(() => _w = next);
    _markDirty();
  }

  void _setSec(MoveSecState Function(MoveSecState s) fn) => _set(_w.withSec(_sec, fn(_w.secs[_sec])));

  void _stepBack() {
    if (_hist.isEmpty) return;
    setState(() {
      _w = _hist.removeLast();
      if (_pt >= _w.secs[_sec].pts.length) _pt = -1;
    });
    _markDirty();
  }

  void _undo() {
    setState(() {
      _reset();
      _pt = -1;
    });
    _markDirty();
  }

  /// Changes every point of the shape around its centre. Port of `mvShape`.
  void _shape(List<(double, double)> Function(List<MovePt> p, (double, double) c) fn) {
    final pts = _w.secs[_sec].pts;
    if (pts.isEmpty) return;
    _setSec((s) => s.copyWith(pts: [for (final q in fn(pts, moveCentre(pts))) (clamp16(q.$1), clamp16(q.$2))]));
  }

  void _scale(double k) => _shape((p, c) => [for (final q in p) (c.$1 + (q.$1 - c.$1) * k, c.$2 + (q.$2 - c.$2) * k)]);

  void _delPt() {
    final pts = _w.secs[_sec].pts;
    if (_pt < 0 || pts.length < 2 || _doc!.secs[_sec].locked) return;
    final at = _pt;
    _setSec((s) => s.copyWith(pts: [...pts]..removeAt(at)));
    setState(() => _pt = math.min(at, pts.length - 2));
  }

  /// Double-tap on empty canvas: a new point there. In the shape it goes into
  /// the side nearest to the tap. Port of `mvDbl`.
  void _add(Offset at, Size size, MoveCanvasModel m) {
    final pts = _w.secs[_sec].pts;
    if (_doc!.secs[_sec].locked || pts.length >= 256) return;
    final np = fromPx(m, at, size);
    if (m.shape) {
      var best = pts.length, bd = double.infinity;
      for (var i = 0; i < pts.length; i++) {
        final a = pts[i], b = pts[(i + 1) % pts.length];
        final dx = (b.$1 - a.$1).toDouble(), dy = (b.$2 - a.$2).toDouble(), l = dx * dx + dy * dy;
        final t = l == 0 ? 0.0 : (((np.$1 - a.$1) * dx + (np.$2 - a.$2) * dy) / l).clamp(0.0, 1.0);
        final d = math.pow(a.$1 + t * dx - np.$1, 2) + math.pow(a.$2 + t * dy - np.$2, 2);
        if (d < bd) {
          bd = d.toDouble();
          best = i + 1;
        }
      }
      _setSec((s) => s.copyWith(pts: [...pts]..insert(best, np)));
      setState(() => _pt = best);
    } else {
      _setSec((s) => s.copyWith(pts: [...pts, np]));
      setState(() => _pt = pts.length);
    }
  }

  /// Delete removes the selected point, Ctrl+Z steps back. Not while typing or
  /// while a dialog is open.
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || _app.tab != 'move' || _doc == null || _ro || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) return false;
    final k = e.logicalKey;
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _pt >= 0) {
      _delPt();
      return true;
    }
    final mod = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (mod && k == LogicalKeyboardKey.keyZ) {
      _stepBack();
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- save, backups, revert

  Future<void> _save() async {
    final d = _doc;
    if (d == null || !_dirty) return;
    final body = _w.diff(d);
    await runSave(
      context,
      () => _app.client.moveSave(body),
      what: 'move',
      busy: 'Saving the movement.',
      after: () async {
        _list = null;
        await _open(d.file, keep: true);
      },
    );
  }

  Future<void> _loadBackups() async {
    final f = _doc?.file;
    if (f == null) return;
    MoveBackups? b;
    try {
      b = await _app.client.moveBackups(f);
    } on ApiException {
      b = null;
    }
    if (mounted && _doc?.file == f) setState(() => _bk = b);
  }

  /// Port of `mvRevert`.
  Future<void> _revert(String id, {bool force = false}) async {
    final d = _doc;
    if (d == null) return;
    if (!force &&
        !await moveAsk(context, 'Put this version back?', [
          moveBold(d.name),
          TextSpan(
            text:
                ' goes back to how it was before that save.${_dirty ? ' Your changes that are not saved yet are lost.' : ''}'
                ' The movement as it is now is kept as a backup too, so this can be undone.',
          ),
        ], 'Revert')) {
      return;
    }
    ToolResult r;
    try {
      r = await _app.client.moveRevert(d.file, id, force: force);
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!mounted) return;
    if (r.ok && r.extra['conflict'] == true) {
      final again = await moveAsk(context, 'The movement changed since', [
        moveBold(d.name),
        const TextSpan(text: ' was changed after that save (in ShowXpress or here). Revert anyway? The movement as it is now is kept as a backup.'),
      ], 'Revert anyway');
      if (again) await _revert(id, force: true);
      return;
    }
    if (r.ok) {
      _list = null;
      await _open(d.file, keep: true);
    }
    _app.showResult(resultOf(r, 'moverev', reopen: _app.status?.queue.reopen ?? true));
  }

  // ---------------------------------------------------------------- on the lights

  Map<int, int> _frame() {
    final d = _doc;
    if (d == null || _ro) return const {};
    final l = _liteV;
    return {if (l != null && l.f == _lite) ...l.v, ...moveFrame(d, _w, _now())};
  }

  static const _reoNote = ' ShowXpress is closed now. Press Launch ShowXpress at the top to open it again.';

  /// Closes ShowXpress so SX Studio can use the DMX interface. Port of `sxCloseLive`.
  Future<({bool go, bool reo})> _closeSx() async {
    await _app.refresh();
    if (!_app.sxOpen) return (go: true, reo: false);
    if (!mounted) return (go: false, reo: false);
    final yes = await moveAsk(context, 'Close ShowXpress to see the movement on the lights?', [
      const TextSpan(text: 'Only one program can use the DMX interface, so ShowXpress closes while you preview. '),
      moveBold('Save your show first'),
      const TextSpan(text: ' if you changed anything. If ShowXpress asks, answer it there.\n\nIt can open again when you stop.'),
    ], 'Close and preview');
    if (!yes) return (go: false, reo: false);
    ToolResult r;
    try {
      r = await _app.client.sxClose(live: true);
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!r.ok) {
      _app.showResult(failedResult('clprev', r.error, out: r.out));
      return (go: false, reo: false);
    }
    setState(() => _busy = 'Waiting for ShowXpress to close. Save it if it asks.');
    final t0 = DateTime.now();
    var open = true;
    while (DateTime.now().difference(t0).inSeconds < 120) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        open = (await _app.client.status()).open;
      } on ApiException {
        // Keep waiting.
      }
      if (!open || !mounted) break;
    }
    if (!mounted) return (go: false, reo: false);
    if (open) {
      setState(() => _busy = '');
      try {
        await _app.client.run('/api/live/stop');
      } on ApiException {
        // Nothing was running.
      }
      _app.showResult(failedResult('clprev', 'ShowXpress is still open. Close it (save if it asks), then press Show on the lights again.'));
      return (go: false, reo: false);
    }
    setState(() => _busy = 'ShowXpress closed. Waiting for it to let go of the interface.');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    return (go: true, reo: true);
  }

  /// Port of `mvPvGo`.
  Future<void> _pvGo() async {
    if (_pv != null || _doc == null || _ro || _busy.isNotEmpty) return;
    final c = await _closeSx();
    if (!c.go || !mounted) {
      if (mounted) setState(() => _busy = '');
      return;
    }
    setState(() => _busy = 'Connecting to the DMX interface.');
    final pv = MovePreview(_app.client, frame: _frame, onLost: _lost);
    var r = await _start(pv, false);
    if (!r.ok && r.extra['nova'] == true && mounted) {
      final yes = await moveAsk(context, 'NovaStar is using the DMX interface', [
        const TextSpan(
          text:
              'The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while you preview? '
              'NovaLCT starts it again by itself. Your LED screens are not touched.',
        ),
      ], 'Pause it and continue');
      if (yes) r = await _start(pv, true);
    }
    if (!mounted) {
      await pv.stop();
      return;
    }
    setState(() => _busy = '');
    if (!r.ok) {
      try {
        await _app.client.run('/api/live/stop');
      } on ApiException {
        // Nothing to stop.
      }
      _app.showResult(failedResult('clprev', '${r.error}${c.reo ? _reoNote : ''}', out: r.out));
      return;
    }
    setState(() {
      _pv = pv;
      _reo = c.reo;
    });
    _liteLoad();
  }

  Future<ToolResult> _start(MovePreview pv, bool nova) async {
    try {
      return await pv.start(stopNova: nova);
    } on ApiException catch (e) {
      return ToolResult.failed(e.message);
    }
  }

  void _lost(String error) {
    if (!mounted) return;
    final reo = _reo;
    setState(() => _pv = null);
    _app.showResult(failedResult('clprev', '$error${reo ? _reoNote : ''}'));
  }

  /// Stops the movement on the lights and, with [reo], opens ShowXpress again. Port of `mvPvStop`.
  Future<void> _pvStop(bool reo) async {
    final pv = _pv;
    if (pv == null) return;
    if (mounted) {
      setState(() {
        _pv = null;
        _busy = 'Stopping the DMX output.';
      });
    }
    await pv.stop();
    if (mounted) setState(() => _busy = '');
    if (reo && mounted) await launchSx(context);
    await _app.refresh();
  }

  /// Loads the scene picked in "Light it with". Port of `mvLiteLoad`.
  Future<void> _liteLoad() async {
    final f = _lite;
    unawaited(openPageStore().then((p) => p.set(_liteKey, f)));
    if (f.isEmpty) {
      _liteV = null;
      _pv?.push();
      return;
    }
    if (_liteV?.f == f) return;
    try {
      final s = await _app.client.get('/api/scene', (j) => j, query: {'f': f});
      if (_lite != f) return;
      _liteV = (f: f, v: moveLiteFrame(s));
      _pv?.push();
    } on ApiException catch (e) {
      if (mounted) setState(() => _err = e.message);
    } on FormatException {
      // A scene this can't read lights nothing.
    }
  }

  // ---------------------------------------------------------------- the page

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _doc;
    // every change that starts or stops the heads moving (open, close, pause) rebuilds the screen
    _syncClock();
    final narrow = MediaQuery.sizeOf(context).width <= 640;
    final dirty = _dirty;
    return ScreenBody(
      bar: SaveBar(
        hint: d == null
            ? 'Open a movement to change it.'
            : _ro
            ? 'This movement can only be changed in ShowXpress.'
            : app.sxOpen
            ? 'ShowXpress is open. A save waits until it closes.'
            : dirty
            ? '${moveWhat(_w.diff(d))}. Only that is changed in the file.'
            : 'Matches the show.',
        actions: [
          OutlinedButton(onPressed: dirty ? _undo : null, child: const Text('Undo changes')),
          FilledButton(onPressed: dirty ? _save : null, child: const Text('Save movement')),
        ],
      ),
      children: [
        // one child per movement in the list and per head in the editor, so only the rows on screen are built
        SxListCard(
          children: [
            _header(d, dirty, narrow),
            ErrorBox(d == null && _err.isEmpty ? _listErr : _err),
            if (d == null) ..._picker(narrow) else ..._editor(d, narrow),
          ],
        ),
        if (d != null && (_bk?.backups.isNotEmpty ?? false)) _backups(_bk!, app.sxOpen, narrow),
      ],
    );
  }

  Widget _header(MoveDoc? d, bool dirty, bool narrow) {
    final buttons = [
      if (d != null) ...[
        if (!_ro) MoveStateTag(dirty: dirty),
        OutlinedButton.icon(onPressed: _back, icon: const Icon(Icons.arrow_back, size: 16), label: const Text('All movements')),
      ],
      OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh, size: 16), label: const Text('Reload')),
    ];
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(d?.name ?? 'Movement Editor', style: Sx.title.copyWith(fontSize: 15)),
        const SizedBox(height: 4),
        Text(
          "Change a movement's shape, speed and the way the heads follow each other, and see it on the lights. "
          'Saving changes only what you changed in the movement file. Everything else in it stays exactly as ShowXpress wrote it.',
          style: Sx.sub,
        ),
      ],
    );
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: title),
        for (final b in buttons) Padding(padding: const EdgeInsets.only(left: 8), child: b),
      ],
    );
  }

  // ---- the list of movements. Port of `renderMoves`.

  List<Widget> _picker(bool narrow) {
    final l = _list;
    if (l == null) {
      return [
        if (_listErr.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(_loading ? 'Loading.' : '', style: Sx.sub),
          ),
      ];
    }
    final q = _query.trim().toLowerCase();
    final width = MediaQuery.sizeOf(context).width;
    // 30 % of a row's inside, 150 to 250: the screen's column, less the card's
    // padding (2 x 20) and the row's padding and border (2 x 13)
    final inner = width - 2 * math.max(sxGutter(context), (width - Sx.contentWidth) / 2) - 40 - 26;
    final nameW = width <= 860 ? null : math.min(250.0, math.max(150.0, inner * .3));
    final shown = [...l.moves.where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.used.any((u) => u.toLowerCase().contains(q)))];
    final count = Text('${l.moves.length} movements${q.isEmpty ? '' : ' · ${shown.length} found'} · tap one to open it', style: Sx.sub.copyWith(height: 1.2));
    final search = TextField(
      decoration: const InputDecoration(hintText: 'Find a movement or button', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9)),
      style: const TextStyle(fontSize: 13),
      onChanged: (v) => setState(() => _query = v),
    );
    return [
      const SizedBox(height: 14),
      if (narrow) ...[
        count,
        const SizedBox(height: 8),
        search,
      ] else
        Row(
          children: [
            Expanded(child: count),
            SizedBox(width: 230, child: search),
          ],
        ),
      const SizedBox(height: 10),
      if (shown.isEmpty) Text('No movement matches.', style: Sx.sub),
      for (final m in shown) Padding(padding: const EdgeInsets.only(bottom: 6), child: _listRow(m, nameW)),
    ];
  }

  /// One movement in the list. On a laptop the name column is [nameW] wide,
  /// on a narrow screen everything is stacked.
  Widget _listRow(MoveListItem m, double? nameW) {
    final name = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 2,
      children: [
        Text(
          m.name,
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Sx.text),
        ),
        if (m.aim.isNotEmpty) MoveTag('Aim · ${m.aim == 'room' ? 'Room' : 'Floor'}'),
        if (m.readonly.isNotEmpty) MoveTag('ShowXpress only', color: Sx.amber),
      ],
    );
    final used = Text(m.used.isEmpty ? 'not on a live button' : m.used.join(' · '), style: TextStyle(color: Sx.dim, fontSize: 11.5));
    final on = Text(m.on.isEmpty ? '' : 'also plays ${m.on.join(', ')}', style: TextStyle(color: Sx.dim, fontSize: 12));
    TextSpan b(String t) => TextSpan(
      text: t,
      style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
    );
    final st = Text.rich(
      TextSpan(
        style: TextStyle(color: Sx.dim, fontSize: 12),
        children: [
          if (m.moves) ...[b('${m.points}'), TextSpan(text: ' point${m.points == 1 ? '' : 's'} · '), b(_num(m.cycle)), const TextSpan(text: ' s · ')],
          b('${m.heads}'),
          TextSpan(text: ' head${m.heads == 1 ? '' : 's'}'),
        ],
      ),
    );
    return _Row(
      onTap: () => _open(m.file),
      child: nameW == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                used,
                if (m.on.isNotEmpty) ...[const SizedBox(height: 4), on],
                const SizedBox(height: 4),
                st,
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: nameW,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, used]),
                ),
                const SizedBox(width: 12),
                Expanded(child: on),
                const SizedBox(width: 12),
                st,
              ],
            ),
    );
  }

  // ---- the open movement. Port of `renderMove`.

  List<Widget> _editor(MoveDoc d, bool narrow) {
    final np = d.heads.where((h) => h.addr == 0).length;
    final warn = [
      if (_ro) "SX Studio doesn't change this movement: ${d.readonly}. ShowXpress still opens and edits it as before.",
      if (!_ro && np > 0)
        "$np head${np == 1 ? " isn't" : "s aren't"} patched in the show (no DMX address), so ${np == 1 ? "it doesn't" : "they don't"} show on the lights.",
    ];
    return [
      const SizedBox(height: 8),
      Text('${d.used.isEmpty ? 'Not on a live button' : 'On ${d.used.join(' · ')}'} · ${d.heads.length} head${d.heads.length == 1 ? '' : 's'}', style: Sx.sub),
      ErrorBox(warn.join('\n\n')),
      if (!_ro && d.aim.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Sx.panel,
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text.rich(
            TextSpan(
              style: TextStyle(color: Sx.dim, fontSize: 13),
              children: [
                moveBold('Aim Movers looks after this movement'),
                TextSpan(
                  text:
                      ' (${d.aim == 'room' ? 'Room' : 'Dance Floor'}): it sets where each head points and how big the shape is, so those are changed in the Aim Movers tab. '
                      'The shape you draw here is kept as you draw it the next time Aim Movers saves.',
                ),
              ],
            ),
          ),
        ),
      if (!_ro) ...[
        _lights(),
        _gh('Channels', 'only the ones that play are sent to the lights'),
        Wrap(spacing: 6, runSpacing: 6, children: [for (var i = 0; i < d.secs.length; i++) _secChip(d, i)]),
        const SizedBox(height: 14),
        ValueListenableBuilder(
          valueListenable: _live,
          builder: (context, _, _) {
            final canvas = _canvasCol(d);
            final side = _side(d);
            if (MediaQuery.sizeOf(context).width <= 900) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [canvas, const SizedBox(height: 16), side]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: canvas),
                const SizedBox(width: 16),
                SizedBox(width: 290, child: side),
              ],
            );
          },
        ),
        _gh('Heads', d.aim.isNotEmpty ? 'aim and size are set by Aim Movers' : 'aim = where it points, as 16-bit pan / tilt steps · zoom = size of its shape'),
        ..._heads(d, narrow),
      ],
    ];
  }

  /// A group heading with a note after it, the old `.gh`.
  Widget _gh(String title, String note) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Row(
      children: [
        Text(title.toUpperCase(), style: Sx.label),
        const SizedBox(width: 8),
        Flexible(
          child: Text(note, style: TextStyle(color: Sx.mute, fontSize: 12)),
        ),
      ],
    ),
  );

  /// The "On the lights" strip, the old `.sepv`. Port of `mvPvUi`.
  Widget _lights() {
    final pv = _pv, on = pv != null;
    final scenes = _scenes ?? const [];
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.radio_button_checked, size: 15, color: on ? Sx.green : Sx.text),
        const SizedBox(width: 6),
        Text(
          'On the lights',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Sx.text),
        ),
      ],
    );
    final note = _busy.isNotEmpty
        ? Text(_busy, style: TextStyle(color: Sx.amber, fontSize: 13))
        : on
        ? null
        : Text(
            'See the movement on the rig as you change it. ShowXpress is closed while this runs; nothing is saved until you press Save.',
            style: TextStyle(color: Sx.dim, fontSize: 13),
          );
    final controls = [
      Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Light it with', style: TextStyle(color: Sx.dim, fontSize: 13)),
          MoveDrop<String>(
            // 220 like the old page, less on a narrow phone.
            width: math.min(220, MediaQuery.sizeOf(context).width - 100),
            value: _lite,
            items: {'': 'nothing (only moves the heads)', for (final s in scenes) s.file: s.name},
            onChanged: (v) {
              setState(() => _lite = v);
              _liteLoad();
            },
          ),
        ],
      ),
      if (pv != null) ...[
        MoveTag(pv.test ? 'TEST - no real output' : 'Output: ${pv.iface}', color: pv.test ? Sx.red : Sx.blue),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 24,
              child: Checkbox(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, value: _reo, onChanged: (v) => setState(() => _reo = v ?? false)),
            ),
            Text('Open ShowXpress again when I stop', style: TextStyle(color: Sx.dim, fontSize: 13)),
          ],
        ),
        MiniButton('Stop', icon: Icons.stop, onPressed: () => _pvStop(_reo)),
      ] else
        MiniButton('Show on the lights', onPressed: _busy.isEmpty ? _pvGo : null),
    ];
    // On a laptop the explanation fills the middle of one row; on a phone, and
    // while it runs (more controls), everything wraps.
    final wide = !on && MediaQuery.sizeOf(context).width > 900;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: on ? Sx.green.withValues(alpha: .5) : Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: wide
          ? Row(
              children: [
                title,
                const SizedBox(width: 10),
                Expanded(child: note ?? const SizedBox.shrink()),
                const SizedBox(width: 10),
                for (final c in controls) Padding(padding: const EdgeInsets.only(left: 10), child: c),
              ],
            )
          : Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [title, ?note, ...controls]),
    );
  }

  /// One section's chip, the old `.sst`. Port of `mvSecsDraw`.
  Widget _secChip(MoveDoc d, int i) {
    final w = _w.secs[i], on = i == _sec, changed = w != _w0.secs[i];
    return Opacity(
      opacity: w.sel != 0 ? 1 : .62,
      child: GestureDetector(
        onTap: () => setState(() {
          _sec = i;
          _pt = -1;
        }),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: on ? Sx.accent.withValues(alpha: .13) : Sx.panel,
              border: Border.all(color: on ? Sx.accent : Sx.line),
              borderRadius: BorderRadius.circular(9),
            ),
            // A changed section has a blue line along the bottom (`.sst.chg`).
            foregroundDecoration: changed
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: Sx.blue, width: 2)),
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  moveSecName(d.secs[i].name),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Sx.text),
                ),
                Text('${w.sel != 0 ? 'plays' : 'off'}${w.pts.isNotEmpty ? ' · ${w.pts.length} pt' : ''}', style: TextStyle(fontSize: 11, color: Sx.dim)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The canvas, its hint and the tool buttons.
  Widget _canvasCol(MoveDoc d) {
    final s = d.secs[_sec], shape = s.isShape;
    final m = MoveCanvasModel(doc: d, state: _w, sec: _sec, point: _pt, view: _view, at: _now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.locked)
          const ErrorBox(
            "The points of this channel are written in a way SX Studio doesn't change, so they can only be edited in ShowXpress. Its other settings can be changed here.",
          )
        else
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Sx.well,
              border: Border.all(color: Sx.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: MoveCanvas(
              model: m,
              clock: _clock,
              now: _now,
              onSelect: (i) {
                _pt = i;
                _live.value++;
              },
              onDrag: (pts) {
                _w = _w.withSec(_sec, _w.secs[_sec].copyWith(pts: pts));
                _live.value++;
              },
              onDragEnd: (before) {
                _hist.add(before);
                if (_hist.length > 200) _hist.removeAt(0);
                setState(() {});
                _markDirty();
              },
              onAdd: (at, size) => _add(at, size, m),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            shape
                ? 'Drag a point to move it · drag empty space to move the whole shape · double-click to add a point · Delete removes the selected one'
                : 'Drag a point · double-click to add one · Delete removes the selected one. Left to right = once round the cycle, bottom to top = value 0 to 255',
            style: TextStyle(color: Sx.dim, fontSize: 12),
          ),
        ),
        if (shape && !s.locked)
          _tools([
            MiniButton('Smaller', onPressed: () => _scale(1 / 1.1)),
            MiniButton('Bigger', onPressed: () => _scale(1.1)),
            MiniButton('Mirror', icon: Icons.swap_horiz, onPressed: () => _shape((p, c) => [for (final q in p) (2 * c.$1 - q.$1, q.$2.toDouble())])),
            MiniButton('Mirror', icon: Icons.swap_vert, onPressed: () => _shape((p, c) => [for (final q in p) (q.$1.toDouble(), 2 * c.$2 - q.$2)])),
            MiniButton(
              'Reverse direction',
              onPressed: () {
                _shape(
                  (p, c) => [
                    for (final q in [p.first, ...p.skip(1).toList().reversed]) (q.$1.toDouble(), q.$2.toDouble()),
                  ],
                );
                setState(() => _pt = -1);
              },
            ),
            MiniButton('Centre', onPressed: () => _shape((p, c) => [for (final q in p) (q.$1 + moveMax / 2 - c.$1, q.$2 + moveMax / 2 - c.$2)])),
          ]),
        _tools([
          MiniButton(_hold ? 'Play' : 'Pause', icon: _hold ? Icons.play_arrow : Icons.pause, onPressed: _holdToggle),
          MiniButton(
            'Start again',
            onPressed: () => setState(() {
              _t0 = DateTime.now();
              _holdT = 0;
            }),
          ),
          if (shape) MiniButton('Zoom to the shape', onPressed: () => setState(() => _view = moveFit(d, _w))),
          MiniButton('Whole range', onPressed: () => setState(() => _view = wholeRange)),
          MiniButton('Step back', icon: Icons.undo, onPressed: _hist.isEmpty ? null : _stepBack),
        ]),
      ],
    );
  }

  void _holdToggle() => setState(() {
    if (_hold) {
      _t0 = DateTime.now().subtract(Duration(milliseconds: _holdT.round()));
      _hold = false;
    } else {
      _holdT = DateTime.now().difference(_t0).inMilliseconds.toDouble();
      _hold = true;
    }
  });

  Widget _tools(List<Widget> b) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Wrap(spacing: 6, runSpacing: 6, children: b),
  );

  /// The settings of the section on show and of the picked point, the old `.mvside`. Port of `mvSideDraw`.
  Widget _side(MoveDoc d) {
    final o = d.secs[_sec], w = _w.secs[_sec], shape = o.isShape;
    final p = _pt >= 0 && _pt < w.pts.length && !o.locked ? w.pts[_pt] : null;
    Widget f(String label, Widget control) => Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 13, color: Sx.text)),
        ),
        const SizedBox(width: 8),
        control,
      ],
    );
    Widget unit(Widget n, String u) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        n,
        Text(' $u', style: TextStyle(fontSize: 13, color: Sx.text)),
      ],
    );
    const gap = SizedBox(height: 9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            moveSecName(o.name),
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Sx.text),
          ),
          gap,
          f(
            'Plays',
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                value: w.sel != 0,
                onChanged: o.has.contains('Selected') ? (v) => _setSec((s) => s.copyWith(sel: v == true ? 1 : 0)) : null,
              ),
            ),
          ),
          gap,
          f(
            'Between points',
            MoveDrop<int>(
              value: w.tr,
              items: const {2: 'Smooth curve', 1: 'Straight lines', 0: 'Jump'},
              onChanged: o.has.contains('Transition') ? (v) => _setSec((s) => s.copyWith(tr: v)) : null,
            ),
          ),
          gap,
          f(
            'Once round in',
            unit(
              MoveNum(
                value: _secs(w.dur),
                enabled: o.has.contains('Duration'),
                onCommit: (t) {
                  final v = double.tryParse(t);
                  final dur = v == null || !v.isFinite ? w.dur : (v * 10).roundToDouble().clamp(1, 360000).toDouble();
                  _setSec((s) => s.copyWith(dur: dur));
                },
              ),
              's',
            ),
          ),
          gap,
          f(
            'Each next head behind by',
            unit(
              MoveNum(
                value: _num(w.shift),
                enabled: o.has.contains('Shift'),
                onCommit: (t) {
                  final v = double.tryParse(t);
                  final sh = v == null || !v.isFinite ? w.shift : (v.clamp(0, 100) * 100).roundToDouble() / 100;
                  _setSec((s) => s.copyWith(shift: sh));
                },
              ),
              '%',
            ),
          ),
          if (p != null) ...[
            gap,
            Container(
              padding: const EdgeInsets.only(top: 9),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Sx.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Point ${_pt + 1}',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Sx.text),
                  ),
                  gap,
                  f(
                    shape ? 'Pan' : 'At %',
                    MoveNum(
                      key: ValueKey('px$_sec.$_pt'),
                      value: shape ? '${p.$1}' : (p.$1 / moveMax * 100).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), ''),
                      onCommit: (t) => _setPt(t, null),
                    ),
                  ),
                  gap,
                  f(
                    shape ? 'Tilt' : 'Value',
                    MoveNum(key: ValueKey('py$_sec.$_pt'), value: shape ? '${p.$2}' : '${p.$2 >> 8}', onCommit: (t) => _setPt(null, t)),
                  ),
                  gap,
                  MiniButton('Delete point', onPressed: w.pts.length < 2 ? null : _delPt),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A point's pan or tilt (shape) or its place and value (graph) typed in.
  void _setPt(String? xs, String? ys) {
    final w = _w.secs[_sec], i = _pt;
    if (i < 0 || i >= w.pts.length) return;
    final p = w.pts[i], shape = _doc!.secs[_sec].isShape;
    double? read(String? t) {
      final v = t == null ? null : double.tryParse(t);
      return v != null && v.isFinite ? v : null;
    }

    final x = read(xs) ?? (shape ? p.$1.toDouble() : p.$1 / moveMax * 100);
    final y = read(ys) ?? (shape ? p.$2.toDouble() : (p.$2 >> 8).toDouble());
    final MovePt np = shape ? (clamp16(x), clamp16(y)) : (clamp16(x.clamp(0, 100) / 100 * moveMax), clamp16(y.round().clamp(0, 255) * 256));
    _setSec((s) => s.copyWith(pts: [...s.pts]..[i] = np));
  }

  /// The heads' aim and size. Port of `mvHeadsDraw`: a table on a laptop,
  /// one block per head on a phone. One child per head, for the card's lazy list.
  List<Widget> _heads(MoveDoc d, bool narrow) {
    final own = d.aim.isNotEmpty;
    const cols = [('op', 'Aim pan', 'OffsetPan'), ('ot', 'Aim tilt', 'OffsetTilt'), ('zp', 'Zoom pan', 'ZoomPan'), ('zt', 'Zoom tilt', 'ZoomTilt')];
    Widget cell(int i, MoveHead h, (String, String, String) c) {
      final (p, _, key) = c;
      if (!h.has.contains(key)) return const SizedBox.shrink();
      final v = _w.heads[i].get(p);
      if (own) return Text(_num(v), style: TextStyle(fontSize: 12.5, color: Sx.text));
      return MoveNum(
        key: ValueKey('h$i$p'),
        width: 86,
        value: _num(v),
        changed: v != _w0.heads[i].get(p),
        onCommit: (t) {
          final lim = p.startsWith('o') ? (-65535, 65535) : (-99, 900);
          final n = t.isEmpty ? 0.0 : double.tryParse(t);
          final r = n == null || !n.isFinite ? 0 : n.round();
          _set(_w.withHead(i, _w.heads[i].with_(p, r.clamp(lim.$1, lim.$2).toDouble())));
        },
      );
    }

    Widget name(MoveHead h) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          h.label.isEmpty ? h.name : h.label,
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: Sx.text),
        ),
        if (h.model.isNotEmpty) Text(h.model, style: TextStyle(fontSize: 12, color: Sx.dim)),
      ],
    );
    Widget dmx(MoveHead h) => h.addr == 0 ? MoveTag('not patched', color: Sx.amber) : Text('${h.addr}', style: TextStyle(fontSize: 12.5, color: Sx.text));
    List<Widget> tags(MoveHead h) => [if (h.rp != 0) const MoveTag('reverse pan'), if (h.rt != 0) const MoveTag('reverse tilt')];
    final th = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: Sx.dim);
    final line = Border(top: BorderSide(color: Sx.line));

    if (narrow) {
      return [
        for (final (i, h) in d.heads.indexed)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            decoration: BoxDecoration(border: line),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: name(h)),
                    Text('DMX ', style: th),
                    dmx(h),
                  ],
                ),
                if (tags(h).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(runSpacing: 4, children: tags(h)),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    for (final c in cols)
                      if (h.has.contains(c.$3))
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.$2, style: th.copyWith(fontSize: 11.5)),
                            cell(i, h, c),
                          ],
                        ),
                  ],
                ),
              ],
            ),
          ),
      ];
    }
    Widget pad(Widget c) => Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: c);
    // The old table as rows of fixed columns, so each head is its own child.
    // The number columns fit a number box (86 + 12), or a number in Aim Movers'
    // movements. The DMX column fits "not patched" when a head is.
    final numW = own ? 72.0 : 98.0, dmxW = d.heads.any((h) => h.addr == 0) ? 104.0 : 56.0;
    Widget row(List<Widget> cells, {Decoration? deco}) => Container(
      decoration: deco,
      child: Row(
        children: [
          Expanded(flex: 20, child: pad(cells[0])),
          SizedBox(width: dmxW, child: pad(cells[1])),
          for (final c in cells.sublist(2, 6)) SizedBox(width: numW, child: pad(c)),
          Expanded(flex: 14, child: pad(cells[6])),
        ],
      ),
    );
    return [
      row([
        for (final t in ['Head', 'DMX', for (final c in cols) c.$2, '']) Text(t, style: th),
      ]),
      for (final (i, h) in d.heads.indexed)
        row([name(h), dmx(h), for (final c in cols) cell(i, h, c), Wrap(runSpacing: 4, children: tags(h))], deco: BoxDecoration(border: line)),
    ];
  }

  /// Earlier versions, with Revert. Port of `mvBackups`.
  Widget _backups(MoveBackups b, bool sxOpen, bool narrow) => SxListCard(
    children: [
      Text('Earlier versions', style: Sx.title.copyWith(fontSize: 15)),
      const SizedBox(height: 4),
      Text('Every save keeps the movement as it was just before. Revert puts one back (with ShowXpress closed).', style: Sx.sub),
      const SizedBox(height: 10),
      for (final x in b.backups)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _Row(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        x.at.replaceFirst('T', ' '),
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Sx.text),
                      ),
                      Text(x.what, style: TextStyle(color: Sx.dim, fontSize: 11.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                MiniButton('Revert to this', onPressed: sxOpen ? null : () => _revert(x.id)),
              ],
            ),
          ),
        ),
    ],
  );
}

/// A row of a list, the old `.sc`: panel, thin border, radius 10. With
/// [onTap] the border lights up under the mouse (`.sesc`).
class _Row extends StatefulWidget {
  const _Row({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: _hover ? Sx.line2 : Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: widget.child,
    );
    final tap = widget.onTap;
    if (tap == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: tap, child: box),
    );
  }
}

/// A number as the old page wrote it (`String(v)`): no ".0" on whole numbers.
String _num(double v) => v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';

/// 1/10 s to seconds as text, "2.5". Port of `mvSecs`.
String _secs(double d) => _num(d.round() / 10);
