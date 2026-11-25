import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'scene_grid.dart';
import 'scene_parts.dart';
import 'scene_preview.dart';
import 'scene_work.dart';

/// The Scene Editor: pick a scene, change its steps and values, see it on
/// the lights, save only what changed. Port of the old page's `v-scene`
/// view and its script in `df_aim_gui.ps1`.
class SceneScreen extends StatefulWidget {
  const SceneScreen(BuildContext _, {super.key});

  @override
  State<SceneScreen> createState() => _SceneScreenState();
}

class _SceneScreenState extends State<SceneScreen> {
  static const _tab = 'scene';
  static const _reoNote = ' ShowXpress is closed now - press Launch ShowXpress at the top to open it again.';

  late final AppState _app;
  SceneList? _list;
  var _error = '';
  var _query = '';

  /// The open scene's working copy, or null on the list.
  SceneWork? _work;
  var _cur = 0;
  var _sel = <String>{};
  var _selVer = 0;
  var _mo = '';
  var _backups = <SceneBackup>[];

  ScenePreview? _pv;

  /// "Open ShowXpress again when I stop".
  var _reo = false;

  /// What the screen is waiting for, shown in the bar. Empty when idle.
  var _busy = '';

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _app.addListener(_onApp);
    _loadList();
  }

  /// Another tab asked for a scene (the SX Player's "Edit scene", Looks'
  /// "Change it in the Scene Editor"). Opens it as the old `seOpen(f)` did:
  /// unsaved edits to the scene on screen are asked about first.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = AppScope.of(context).takeFile(_tab);
    if (f == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open(f);
    });
  }

  @override
  void dispose() {
    _app.removeListener(_onApp);
    unawaited(_pv?.stop());
    super.dispose();
  }

  /// Leaving the tab stops the preview, as if the user pressed Stop.
  void _onApp() {
    if (_app.tab != _tab && _pv != null) unawaited(_pvStop(_reo));
  }

  void _markDirty() => _app.setDirty(_tab, _work?.dirty ?? false);

  Future<void> _loadList() async {
    setState(() => _busy = 'Loading.');
    try {
      final l = await _app.client.scenes();
      if (!mounted) return;
      setState(() {
        _list = l;
        _error = '';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = '');
  }

  Future<bool> _leaveOk() async =>
      !(_work?.dirty ?? false) ||
      await sceneAsk(context, 'Leave this scene?', [
        ('Your changes to ', false),
        (_work!.scene.name, true),
        (' are not saved yet. They will be lost.', false),
      ], 'Leave it');

  /// Opens [file]. With [keep] it is the same scene again (after a save,
  /// revert or reload) and the step and picked heads stay.
  Future<void> _open(String file, {bool keep = false}) async {
    if (!keep && !await _leaveOk()) return;
    await _pvStop(_pv != null && _reo);
    if (!mounted) return;
    setState(() => _busy = 'Opening the scene.');
    SceneOpen r;
    try {
      r = await _app.client.scene(file);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = '';
          _error = e.message;
        });
      }
      return;
    }
    if (!mounted) return;
    final was = keep && _work?.scene.file == file;
    final w = SceneWork(r);
    setState(() {
      _busy = '';
      _error = '';
      _work = w;
      _backups = [];
      if (was) {
        _cur = _cur.clamp(0, w.steps.isEmpty ? 0 : w.steps.length - 1);
      } else {
        _cur = 0;
        _sel = {};
        _mo = '';
        if (w.heads.isNotEmpty) {
          _sel.add(w.heads.first.id);
          _mo = w.heads.first.model;
        }
      }
      _selVer++;
    });
    _markDirty();
    unawaited(_loadBackups());
  }

  Future<void> _loadBackups() async {
    final w = _work;
    if (w == null) return;
    try {
      final b = await _app.client.sceneBackups(w.scene.file);
      if (mounted && _work?.scene.file == w.scene.file) setState(() => _backups = b.backups);
    } on ApiException {
      // no list of earlier versions, nothing to show
    }
  }

  Future<void> _back() async {
    if (!await _leaveOk()) return;
    await _pvStop(_pv != null && _reo);
    if (!mounted) return;
    setState(() {
      _work = null;
      _backups = [];
    });
    _markDirty();
    if (_list == null) await _loadList();
  }

  Future<void> _reload() async {
    final w = _work;
    if (w == null) return _loadList();
    if (w.dirty && !await sceneAsk(context, 'Reload the scene?', [('Your changes that are not saved yet will be lost.', false)], 'Reload')) return;
    await _open(w.scene.file, keep: true);
  }

  /// Something in the working copy or the step on screen changed: redraw,
  /// mark the tab, and send the new frame to the lights.
  void _changed(VoidCallback f) {
    setState(f);
    _markDirty();
    _pv?.push(_work!, _cur);
  }

  void _pickStep(int i) => _changed(() => _cur = i);

  /// A tap in the grid: a step, a head, or both. [add] keeps the other heads
  /// of the same model picked.
  void _gridPick(int? step, String? head, bool add) => _changed(() {
    if (step != null) _cur = step;
    if (head != null) {
      final m = _work!.byId[head]!.model;
      if (m != _mo || !add) _sel = {};
      _mo = m;
      if (_sel.contains(head) && _sel.length > 1) {
        _sel.remove(head);
      } else {
        _sel.add(head);
      }
      _selVer++;
    }
  });

  void _headTap(SceneHead h) => setState(() {
    if (h.model != _mo) {
      _sel = {};
      _mo = h.model;
    }
    if (!_sel.remove(h.id)) _sel.add(h.id);
    _selVer++;
  });

  void _all() => setState(() {
    final w = _work!;
    if (_mo.isEmpty && w.heads.isNotEmpty) _mo = w.heads.first.model;
    _sel = {for (final h in w.heads.where((h) => h.model == _mo)) h.id};
    _selVer++;
  });

  void _none() => setState(() {
    _sel = {};
    _selVer++;
  });

  /// Step time typed in seconds, as hundredths, or null when it isn't a time.
  int? _lenIn(String t) {
    final v = double.tryParse(t.replaceAll(',', '.'));
    if (v == null || !v.isFinite || v <= 0) return null;
    final cs = jsRound(v * 100);
    return cs < 1 ? 1 : cs;
  }

  Future<void> _delCh(int ix) async {
    final w = _work!;
    final ids = w.withChannel(_sel, ix);
    if (ids.isEmpty) return;
    final n = w.chName(_mo, ix, chKey(ids.first, ix));
    final ok = await sceneAsk(context, 'Take $n out?', [
      ('Channel ', false),
      (n, true),
      (' comes out of ${ids.length == 1 ? w.byId[ids.first]!.name : '${ids.length} heads'} in ', false),
      ('every step', true),
      (" of this scene. In ShowXpress it then isn't set by this scene at all.", false),
    ], 'Take it out');
    if (ok && mounted) _changed(() => w.delCh(ids, ix));
  }

  int? _addIx;

  Future<void> _save() async {
    final w = _work;
    if (w == null || !w.dirty) return;
    await runSave(context, () => _app.client.sceneSave(w.body()), after: () => _open(w.scene.file, keep: true));
    unawaited(_loadList());
  }

  Future<void> _revert(String id, {bool force = false}) async {
    final w = _work;
    if (w == null) return;
    if (!force &&
        !await sceneAsk(context, 'Put this version back?', [
          (w.scene.name, true),
          (
            ' goes back to how it was before that save.${w.dirty ? ' Your changes that are not saved yet are lost.' : ''}'
                ' The scene as it is now is kept as a backup too, so this can be undone.',
            false,
          ),
        ], 'Revert')) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = 'Reverting.');
    ToolResult r;
    try {
      r = await _app.client.sceneRevert(w.scene.file, id, force: force);
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!mounted) return;
    setState(() => _busy = '');
    if (r.ok && r.extra['conflict'] == true) {
      final again = await sceneAsk(context, 'The scene changed since', [
        (w.scene.name, true),
        (' was changed after that save (in ShowXpress or here). Revert anyway? The scene as it is now is kept as a backup.', false),
      ], 'Revert anyway');
      if (again && mounted) await _revert(id, force: true);
      return;
    }
    if (r.ok) {
      await _open(w.scene.file, keep: true);
      unawaited(_loadList());
    }
    if (!mounted) return;
    await showReport(context, r.ok ? 'Scene reverted' : 'Not saved', r.out, error: r.error);
  }

  // ---- on the lights

  /// Closes ShowXpress for the preview when it is open, after asking. Port of `sxCloseLive`.
  Future<({bool go, bool reo})> _closeSx() async {
    if (!_app.sxOpen) return (go: true, reo: false);
    final ok = await sceneAsk(context, 'Close ShowXpress to see the scene on the lights?', [
      ('Only one program can use the DMX interface, so ShowXpress closes while you preview. ', false),
      ('Save your show first', true),
      (' if you changed anything. If ShowXpress asks, answer it there.\n\nIt can open again when you stop.', false),
    ], 'Close and preview');
    if (!ok || !mounted) return (go: false, reo: false);
    ToolResult r;
    try {
      r = await _app.client.run('/api/sx/close', {'live': true});
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!mounted) return (go: false, reo: false);
    if (!r.ok) {
      await showReport(context, "Preview didn't start", r.out, error: r.error);
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
        // keep waiting
      }
      if (!open || !mounted) break;
    }
    if (!mounted) return (go: false, reo: false);
    if (open) {
      setState(() => _busy = '');
      await _liveStop();
      if (mounted) {
        await showReport(
          context,
          "Preview didn't start",
          '',
          error: 'ShowXpress is still open. Close it (save if it asks), then press Show on the lights again.',
        );
      }
      return (go: false, reo: false);
    }
    setState(() => _busy = 'ShowXpress closed. Waiting for it to let go of the interface.');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    return (go: true, reo: true);
  }

  Future<void> _liveStop() async {
    try {
      await _app.client.run('/api/live/stop', const {});
    } on ApiException {
      // nothing is running
    }
  }

  /// "Show on the lights". Port of `sePvGo`.
  Future<void> _pvGo() async {
    final w = _work;
    if (_pv != null || w == null || w.readonly) return;
    final c = await _closeSx();
    if (!c.go || !mounted) return;
    setState(() => _busy = '');
    final (pv, r) = await ScenePreview.start(
      _app.client,
      w,
      onFailed: _pvFailed,
      onStep: (_) {
        if (mounted) setState(() {});
      },
    );
    if (!mounted) {
      await pv?.stop();
      return;
    }
    if (pv == null) {
      await _liveStop();
      if (!mounted) return;
      await showReport(context, "Preview didn't start", r.out, error: '${r.error}${c.reo ? _reoNote : ''}');
      return;
    }
    if (_app.tab != _tab || _work != w) {
      await pv.stop();
      return;
    }
    setState(() {
      _pv = pv;
      _reo = c.reo;
    });
    pv.push(w, _cur);
  }

  void _pvFailed(String error) {
    final reo = _reo;
    if (!mounted) return;
    setState(() => _pv = null);
    unawaited(showReport(context, "Preview didn't start", '', error: '$error${reo ? _reoNote : ''}'));
  }

  /// Stops the preview, and opens ShowXpress again when [reo]. Port of `sePvStop`.
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
    if (!mounted) return;
    setState(() => _busy = '');
    if (!reo) return;
    setState(() => _busy = 'Starting ShowXpress.');
    ToolResult r;
    try {
      r = await _app.client.sxLaunch();
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    await _app.refresh();
    if (!mounted) return;
    setState(() => _busy = '');
    if (!r.ok) await showReport(context, "Didn't work", r.out, error: r.error);
  }

  void _play() {
    final pv = _pv;
    if (pv == null) return;
    setState(() {
      if (pv.playing) {
        if (pv.playingAt >= 0) _cur = pv.playingAt;
        pv.play(false);
      } else {
        pv.play(true);
      }
    });
    pv.push(_work!, _cur);
  }

  // ---- drawing

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final w = _work;
    final dirty = w?.dirty ?? false;
    final hint = _busy.isNotEmpty
        ? _busy
        : w == null
        ? 'Open a scene to change it.'
        : w.readonly
        ? 'This scene can only be changed in ShowXpress.'
        : app.sxOpen
        ? 'ShowXpress is open. A save waits until it closes.'
        : dirty
        ? '${w.what()}. Only that is changed in the file.'
        : 'Matches the show.';
    final phone = sxGutter(context) < 22;
    return ScreenBody(
      bar: SaveBar(
        hint: hint,
        actions: [
          OutlinedButton(onPressed: dirty && _busy.isEmpty ? _undo : null, child: const Text('Undo changes')),
          FilledButton(onPressed: dirty && _busy.isEmpty ? _save : null, child: const Text('Save scene')),
        ],
      ),
      children: [
        SxCard(
          padding: phone ? const EdgeInsets.fromLTRB(14, 14, 14, 14) : const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SxHeader(
                w?.scene.name ?? 'Scene Editor',
                sub:
                    "Change a scene's steps and values and see it on the lights. Saving changes only what you changed in the scene file. "
                    'Everything else in it stays exactly as ShowXpress wrote it.',
                actions: [
                  if (w != null && !phone) SceneStateTag(dirty: dirty),
                  if (w != null) OutlinedButton.icon(onPressed: _back, icon: const Icon(Icons.arrow_back, size: 16), label: const Text('All scenes')),
                  if (!phone || w == null) OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh, size: 16), label: const Text('Reload')),
                ],
              ),
              ErrorBox(_error),
              if (w == null) ..._listView(phone) else ..._editor(w, phone),
            ],
          ),
        ),
        if (w != null && _backups.isNotEmpty) _backupsCard(app.sxOpen),
      ],
    );
  }

  void _undo() => _changed(() {
    final w = _work!;
    w.reset();
    _cur = _cur.clamp(0, w.steps.isEmpty ? 0 : w.steps.length - 1);
  });

  List<Widget> _listView(bool phone) {
    final l = _list;
    if (l == null) {
      return [
        if (_error.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('Loading.', style: Sx.sub),
          ),
      ];
    }
    final q = _query.trim().toLowerCase();
    final ls = [
      for (final s in l.scenes)
        if (q.isEmpty || s.name.toLowerCase().contains(q) || s.used.any((u) => u.toLowerCase().contains(q))) s,
    ];
    final count = Text('${l.scenes.length} scenes${q.isNotEmpty ? ' · ${ls.length} found' : ''} · tap one to open it', style: Sx.sub);
    final search = SizedBox(
      width: phone ? double.infinity : 230,
      child: TextField(
        decoration: const InputDecoration(hintText: 'Find a scene or button', isDense: true),
        style: const TextStyle(fontSize: 13),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
    return [
      const SizedBox(height: 14),
      if (phone) ...[
        count,
        const SizedBox(height: 8),
        search,
      ] else
        Row(
          children: [
            Expanded(child: count),
            search,
          ],
        ),
      const SizedBox(height: 4),
      if (ls.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('No scene matches.', style: Sx.sub),
        ),
      for (final s in ls.take(500))
        SceneRow(
          name: s.name,
          tag: s.trimmed ? SceneTag('trimmed tonight', color: Sx.amber) : null,
          small: s.used.isEmpty ? 'not on a live button' : s.used.join(' · '),
          right: _counts(s.steps, 'step', s.heads, 'head'),
          onTap: () => _open(s.file),
        ),
    ];
  }

  Widget _counts(int a, String an, int b, String bn) {
    final dim = TextStyle(fontSize: 12, color: Sx.dim), bold = TextStyle(fontWeight: FontWeight.w700, color: Sx.text);
    return Text.rich(
      TextSpan(
        style: dim,
        children: [
          TextSpan(text: '$a', style: bold),
          TextSpan(text: ' $an${a == 1 ? '' : 's'} · '),
          TextSpan(text: '$b', style: bold),
          TextSpan(text: ' $bn${b == 1 ? '' : 's'}'),
        ],
      ),
    );
  }

  List<(String, String)> _warnings(SceneWork w) {
    final s = w.scene, ro = s.readonly;
    final np = w.heads.where((h) => h.addr == 0).length;
    return [
      if (ro.isNotEmpty) ('', "SX Studio doesn't change this scene: $ro. ShowXpress still opens and edits it as before."),
      if (s.trimmed)
        (
          "Tonight's Rig has trimmed this scene for tonight.",
          " If you save it, the version you save counts as the full scene from then on: the steps Tonight's Rig took out don't come back.",
        ),
      if (ro.isEmpty && !s.structural)
        ('', "This scene has something between its steps that SX Studio doesn't know, so its steps can be changed here but not added, moved or taken out."),
      if (ro.isEmpty && np > 0)
        (
          '',
          '$np head${np == 1 ? " isn't" : "s aren't"} patched in the show (no DMX address), so ${np == 1 ? "it doesn't" : "they don't"} show on the lights.',
        ),
    ];
  }

  List<Widget> _editor(SceneWork w, bool phone) {
    final s = w.scene;
    return [
      if (phone)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SceneStateTag(dirty: w.dirty),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '${s.used.isNotEmpty ? 'On ${s.used.join(' · ')}' : 'Not on a live button'} · ${w.heads.length} head${w.heads.length == 1 ? '' : 's'}',
          style: Sx.sub,
        ),
      ),
      SceneWarnBox(_warnings(w)),
      if (!w.readonly) ..._steps(w, phone),
    ];
  }

  Widget _preview(SceneWork w) {
    final pv = _pv, on = pv != null;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: on ? Sx.green.withValues(alpha: .5) : Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lightbulb_outline, size: 16, color: Sx.text),
              const SizedBox(width: 4),
              Text(
                'On the lights',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Sx.text),
              ),
            ],
          ),
          if (!on)
            Text(
              "See the step you're on as you change it, or play the whole scene. ShowXpress is closed while this runs; nothing is saved until you press Save.",
              style: Sx.sub,
            ),
          if (on) SceneTag(pv.test ? 'TEST - no real output' : 'Output: ${pv.iface}', color: pv.test ? Sx.red : Sx.blue),
          if (on)
            InkWell(
              onTap: () => setState(() => _reo = !_reo),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(value: _reo, onChanged: (b) => setState(() => _reo = b ?? false), visualDensity: VisualDensity.compact),
                  ),
                  const SizedBox(width: 6),
                  Text('Open ShowXpress again when I stop', style: TextStyle(fontSize: 13, color: Sx.dim)),
                ],
              ),
            ),
          if (!on) MiniButton('Show on the lights', onPressed: _busy.isEmpty ? _pvGo : null),
          if (on) MiniButton(pv.playing ? 'Hold this step' : 'Play the scene', icon: pv.playing ? Icons.pause : Icons.play_arrow, onPressed: _play),
          if (on) MiniButton('Stop', icon: Icons.stop, on: true, onPressed: () => _pvStop(_reo)),
        ],
      ),
    );
  }

  List<Widget> _steps(SceneWork w, bool phone) {
    final n = w.steps.length, st = w.scene.structural;
    if (_cur >= n) _cur = n == 0 ? 0 : n - 1;
    final loop = stepSeconds(w.steps.fold(0, (a, x) => a + x.cs));
    final curLen = n == 0 ? '' : stepSeconds(w.steps[_cur].cs);
    final wide = MediaQuery.sizeOf(context).width > 760 + 2 * sxGutter(context);
    return [
      _preview(w),
      SceneGroupHead('STEPS', count: '$n step${n == 1 ? '' : 's'} · loop $loop s'),
      StepStrip(work: w, cur: _cur, playing: _pv?.playingAt ?? -1, onPick: _pickStep),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          MiniButton('Move', icon: Icons.chevron_left, onPressed: st && _cur > 0 ? () => _changed(() => _cur = w.move(_cur, -1)) : null),
          MiniButton('Move', icon: Icons.chevron_right, onPressed: st && _cur < n - 1 ? () => _changed(() => _cur = w.move(_cur, 1)) : null),
          MiniButton(
            'Copy step',
            onPressed: st && n < 999
                ? () => _changed(() {
                    w.copy(_cur);
                    _cur++;
                  })
                : null,
          ),
          MiniButton(
            'Delete step',
            onPressed: st && n >= 2
                ? () => _changed(() {
                    w.delete(_cur);
                    _cur = _cur.clamp(0, w.steps.length - 1);
                  })
                : null,
          ),
          if (!phone) const SizedBox(width: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Step time ', style: TextStyle(fontSize: 13, color: Sx.dim)),
              SceneNumber(
                key: ValueKey('len$_cur'),
                text: curLen,
                width: 84,
                decimal: true,
                onChanged: (t) {
                  final cs = _lenIn(t);
                  if (cs != null && n > 0) _changed(() => w.setLen(_cur, cs));
                },
              ),
              Text(' s', style: TextStyle(fontSize: 13, color: Sx.dim)),
            ],
          ),
          MiniButton(
            'Same for every step',
            onPressed: () {
              if (n > 0) _changed(() => w.setLenAll(w.steps[_cur].cs));
            },
          ),
        ],
      ),
      SceneGrid(work: w, cur: _cur, sel: _sel, selVer: _selVer, onPick: _gridPick),
      const SizedBox(height: 14),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 230, child: _heads(w, 560)),
            const SizedBox(width: 16),
            Expanded(child: _channels(w, false)),
          ],
        )
      else ...[
        _heads(w, 260),
        const SizedBox(height: 14),
        _channels(w, true),
      ],
    ];
  }

  Widget _heads(SceneWork w, double maxHeight) => SceneHeads(work: w, step: _cur, sel: _sel, maxHeight: maxHeight, onTap: _headTap, onAll: _all, onNone: _none);

  Widget _channels(SceneWork w, bool narrow) {
    final box = BoxDecoration(
      color: Sx.panel,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(12),
    );
    Widget wrap(List<Widget> kids) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: box,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids),
    );
    if (w.steps.isEmpty || _sel.isEmpty) {
      return wrap([Text('Pick one or more heads on the left or in the grid. Shift-click in the grid picks more.', style: Sx.sub)]);
    }
    final rows = w.rows(_cur, _sel);
    final names = [for (final id in _sel) w.byId[id]!.name];
    final add = w.addable(_cur, _mo, _sel);
    if (_addIx != null && !add.any((c) => c.ix == _addIx)) _addIx = null;
    return wrap([
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                '${names.length > 3 ? '${names.length} heads' : names.join(', ')} · step ${_cur + 1}',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Sx.text),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(_mo, style: Sx.sub, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
      if (rows.isEmpty) Text('${names.length == 1 ? 'This head has' : 'These heads have'} no channels in this step.', style: Sx.sub),
      for (final r in rows)
        SceneChannelRow(
          key: ValueKey(r.ix),
          work: w,
          step: _cur,
          row: r,
          model: _mo,
          narrow: narrow,
          onValue: (v) => _changed(() => w.setValue(_cur, r.keys, v)),
          onFade: (on) => _changed(() => w.setFade(_cur, r.keys, on)),
          onDelete: () => _delCh(r.ix),
        ),
      if (add.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: SceneSelect<int>(
                  items: {for (final c in add) c.ix: '${c.name} (ch ${c.ix + 1})'},
                  value: _addIx ?? add.first.ix,
                  hint: '',
                  onChanged: (ix) => setState(() => _addIx = ix),
                ),
              ),
              MiniButton(
                'Add channel',
                onPressed: () {
                  final ix = _addIx ?? add.first.ix;
                  _changed(() {
                    w.addCh(_sel, ix);
                    _addIx = null;
                  });
                },
              ),
              Text('to these heads, in every step', style: Sx.sub),
            ],
          ),
        ),
    ]);
  }

  Widget _backupsCard(bool sxOpen) => SxCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SxHeader('Earlier versions', sub: 'Every save keeps the scene as it was just before. Revert puts one back (with ShowXpress closed).'),
        const SizedBox(height: 4),
        for (final b in _backups)
          SceneRow(
            name: b.at.replaceFirst('T', ' '),
            small: b.what,
            right: MiniButton('Revert to this', onPressed: sxOpen || _busy.isNotEmpty ? null : () => _revert(b.id)),
          ),
      ],
    ),
  );
}
