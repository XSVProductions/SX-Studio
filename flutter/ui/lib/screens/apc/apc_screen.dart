import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../health/issue_row.dart';
import 'apc_edits.dart';
import 'apc_palette.dart';

/// APC mini: the 8x8 pad grid as it sits on the controller, in each pad's
/// own colours. Tap a pad, then tap where it should go, or pick its colours.
class ApcScreen extends StatefulWidget {
  const ApcScreen(BuildContext _, {super.key});

  @override
  State<ApcScreen> createState() => _ApcScreenState();
}

class _ApcScreenState extends State<ApcScreen> with ShowWatcher {
  ApcEdits? _e;
  var _error = '';
  var _loading = true;

  /// Whether the tab was on show at the last rebuild.
  bool? _shown;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Opening the tab with nothing unsaved reads the pads again, since a Health
  /// Check fix or another tab may have changed live.ini. The old page did this
  /// by dropping its copy after a Health fix (`hlAfter`).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = AppScope.of(context).tab == 'apc';
    if (shown && _shown == false && !_loading && !(_e?.dirty ?? false)) _load();
    _shown = shown;
  }

  /// The queue saved into the show, so edits that waited in it are saved now.
  @override
  void onQueueRan() => _load();

  @override
  void onSxClosed() {
    if (!(_e?.dirty ?? false)) _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    _loading = true;
    try {
      final d = await app.client.apc();
      if (!mounted) return;
      setState(() {
        _e = ApcEdits(d);
        _error = '';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _e = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    app.setDirty('apc', false);
  }

  /// Runs an edit, redraws, and tells the tab bar whether anything is unsaved.
  void _edit(void Function(ApcEdits e) f) {
    final e = _e;
    if (e == null) return;
    setState(() => f(e));
    AppScope.read(context).setDirty('apc', e.dirty);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final e = _e;
    final changed = e == null ? 0 : e.data.pads.where(e.changed).length;
    final stacked = MediaQuery.sizeOf(context).width <= 860;
    return ScreenBody(
      bar: SaveBar(
        hint: e == null
            ? ''
            : app.sxOpen
            ? 'ShowXpress is open. A save waits until it closes.'
            : changed > 0
            ? '$changed button(s) changed. Only the pad notes and pad colours in live.ini change.'
            : 'Pads match the show.',
        actions: [
          OutlinedButton(onPressed: changed == 0 ? null : () => _edit((e) => e.undo()), child: const Text('Undo changes')),
          FilledButton(
            onPressed: changed == 0 ? null : () => runSave(context, () => app.client.apcApply(e!.changes), after: _load),
            child: const Text('Save pads'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SxHeader(
                'APC mini pads',
                sub:
                    "The 8x8 grid as it sits on the controller (top row first), in each pad's own colours. "
                    'Tap a pad, then tap where it should go, or pick its colours.',
                actions: [OutlinedButton(onPressed: _load, child: const Text('Refresh'))],
              ),
              ErrorBox(_error),
              if (e == null && _error.isEmpty && _loading)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (e != null) ...[
                const SizedBox(height: 14),
                if (stacked) ...[_grid(e), const SizedBox(height: 18), _side(e)],
                if (!stacked)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _grid(e)),
                      const SizedBox(width: 18),
                      SizedBox(width: 270, child: _side(e)),
                    ],
                  ),
                _faders(e),
              ],
            ],
          ),
        ),
        if (e != null)
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pad problems', style: Sx.title),
                const SizedBox(height: 8),
                ..._issues(e),
              ],
            ),
          ),
      ],
    );
  }

  Widget _grid(ApcEdits e) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: apcBody,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: GridView.count(
      crossAxisCount: 8,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var r = 1; r <= 8; r++)
          for (var c = 1; c <= 8; c++) _Pad(edits: e, n: (8 - r) * 8 + (c - 1), onTap: (n) => _edit((e) => e.tap(n))),
      ],
    ),
  );

  Widget _side(ApcEdits e) {
    final sel = e.selected == null ? null : e.pad(e.selected!);
    final kv = <(String, Widget)>[];
    late final Widget body;
    if (sel != null) {
      final n = e.note[sel.sec]!;
      final where = n < 0
          ? 'none, will be taken off'
          : e.onGrid(sel)
          ? padPlace(n)
          : 'note $n (not a pad)';
      kv
        ..add(('Page', Text(sel.pageName)))
        ..add(('Scene', Text(sel.sceneOk ? sel.scene : '${sel.scene}, missing!', style: TextStyle(color: sel.sceneOk ? Sx.text : Sx.red))))
        ..add((
          'Pad',
          Row(
            children: [
              Flexible(child: Text(where)),
              if (e.moved(sel)) _Tag('moved', Sx.blue),
            ],
          ),
        ))
        ..add((
          'Light',
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              _Swatch(padColor(e.on(sel))),
              const Text('playing  '),
              _Swatch(padColor(e.off(sel))),
              const Text('idle'),
              if (e.colourChanged(sel)) _Tag('changed', Sx.blue),
            ],
          ),
        ));
      if (sel.key.isNotEmpty) kv.add(('Key', Text(sel.key)));
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sel.title, style: Sx.title),
          _Kv(kv),
          if (e.onGrid(sel)) ...[
            Text('Colour while playing', style: TextStyle(fontSize: 12, color: Sx.dim)),
            _Palette(current: e.on(sel), onPick: (v) => _edit((e) => e.setColour(sel, true, v))),
            Text('Colour when idle', style: TextStyle(fontSize: 12, color: Sx.dim)),
            _Palette(current: e.off(sel), onPick: (v) => _edit((e) => e.setColour(sel, false, v))),
          ],
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              e.message.isNotEmpty ? e.message : 'Tap a colour to change it, or tap the pad it should go to. Tapping a used pad swaps the two.',
              style: TextStyle(fontSize: 13, color: e.message.isNotEmpty ? Sx.amber : Sx.dim),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(onPressed: () => _edit((e) => e.takeOff(sel.sec)), child: const Text('Take off the pads')),
              OutlinedButton(
                onPressed: () => _edit((e) {
                  e.selected = null;
                  e.message = '';
                }),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      );
    } else {
      final used = [for (var n = 0; n < 64; n++) n].where((n) => e.at(n).isNotEmpty).length;
      final free = [
        for (var r = 1; r <= 8; r++)
          for (var c = 1; c <= 8; c++)
            if (e.at((8 - r) * 8 + (c - 1)).isEmpty) 'row $r col $c',
      ];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Move a pad', style: Sx.title),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text('Tap a pad to see what it plays, then tap where it should go. A blue dot means moved, not saved yet.', style: Sx.sub),
          ),
          if (e.message.isNotEmpty) Text(e.message, style: TextStyle(fontSize: 13, color: Sx.amber)),
          _Kv([('Pads used', Text('$used of 64')), ('Free', Text(free.isEmpty ? 'none' : free.join(', ')))]),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 13, color: Sx.text),
        child: body,
      ),
    );
  }

  Widget _faders(ApcEdits e) => LayoutBuilder(
    builder: (context, box) {
      final cols = ((box.maxWidth + 8) / (170 + 8)).floor().clamp(1, 99);
      final w = (box.maxWidth - 8 * (cols - 1)) / cols;
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in e.data.faders)
              Container(
                width: w,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Sx.panel,
                  border: Border.all(color: Sx.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fader ${f.n}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Sx.text),
                    ),
                    Row(
                      children: [
                        Text('CC ${f.cc} ', style: TextStyle(fontSize: 12.5, color: Sx.dim)),
                        Icon(Icons.arrow_forward, size: 12, color: Sx.dim),
                        Flexible(
                          child: Text(
                            ' ${f.caption.isEmpty ? '?' : f.caption} speed',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: Sx.text),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  List<Widget> _issues(ApcEdits e) {
    final list = e.issues;
    if (list.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(Icons.check, size: 16, color: Sx.green),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Every pad plays one button and every scene exists.', style: TextStyle(color: Sx.green)),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      for (final (k, i) in list.indexed)
        IssueRow(
          level: i.level,
          first: k == 0,
          title: i.title,
          detail: i.detail,
          actions: [
            if (i.action == ApcIssueAction.moveOrTakeOff)
              MiniButton(
                'Move to a pad',
                onPressed: () => _edit((e) {
                  e.selected = i.sec;
                  e.message = 'Tap a free pad to put it there.';
                }),
              ),
            if (i.action == ApcIssueAction.moveOrTakeOff || i.action == ApcIssueAction.takeOff)
              MiniButton('Take off', onPressed: () => _edit((e) => e.takeOff(i.sec!))),
            if (i.action == ApcIssueAction.putBack) MiniButton('Put back', onPressed: () => _edit((e) => e.putBack(i.sec!))),
          ],
        ),
    ];
  }
}

/// One pad of the grid.
class _Pad extends StatelessWidget {
  const _Pad({required this.edits, required this.n, required this.onTap});

  final ApcEdits edits;
  final int n;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final e = edits;
    final here = e.at(n);
    if (here.isEmpty) {
      return GestureDetector(
        onTap: () => onTap(n),
        child: CustomPaint(
          painter: _Dashed(),
          child: Container(
            alignment: Alignment.bottomLeft,
            padding: const EdgeInsets.fromLTRB(5, 5, 5, 4),
            child: Text('free', style: TextStyle(fontSize: 10, color: Sx.line2)),
          ),
        ),
      );
    }
    final p = here.firstWhere((x) => x.sec == e.selected, orElse: () => here.first);
    final sel = here.any((x) => x.sec == e.selected);
    final dup = here.length > 1;
    final moved = here.any(e.changed);
    const shadow = [Shadow(color: apcBody, blurRadius: 2, offset: Offset(0, 1))];
    return Semantics(
      button: true,
      label: '${padPlace(n)}: ${here.map((x) => x.title).join(' + ')}',
      child: GestureDetector(
        onTap: () => onTap(n),
        child: Container(
          foregroundDecoration: sel
              ? BoxDecoration(
                  border: Border.all(color: Sx.accent, width: 2),
                  borderRadius: BorderRadius.circular(7),
                )
              : null,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [.35, 1],
              colors: [(padColor(e.off(p)) ?? padNoIdle), Color.lerp(padColor(e.off(p)) ?? padNoIdle, apcBody, .6)!],
            ),
            border: Border.all(color: dup ? Sx.red : Sx.line, width: dup ? 2 : 1),
            borderRadius: BorderRadius.circular(7),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(left: 0, right: 0, top: 0, height: 5, child: ColoredBox(color: padColor(e.on(p)) ?? padNoOn)),
              if (dup)
                Positioned(
                  top: 8,
                  left: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(color: Sx.red, borderRadius: BorderRadius.circular(99)),
                    child: Text(
                      '${here.length}',
                      style: const TextStyle(color: padText, fontSize: 9, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              if (moved)
                Positioned(
                  top: 9,
                  right: 5,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: Sx.blue, shape: BoxShape.circle),
                  ),
                ),
              Positioned(
                left: 5,
                right: 5,
                bottom: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      p.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, height: 1.15, fontWeight: FontWeight.w600, color: p.sceneOk ? padText : Sx.redText, shadows: shadow),
                    ),
                    Text(
                      p.pageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 8.5, color: padSubText, shadows: shadow),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dashed outline of a free pad.
class _Dashed extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Sx.line
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashed old) => false;
}

/// The colour palette for one of a pad's two colours.
class _Palette extends StatelessWidget {
  const _Palette({required this.current, required this.onPick});

  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 3, bottom: 7),
    child: Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final v in padSwatches)
          Tooltip(
            message: v == 0 ? 'off' : 'colour $v',
            child: GestureDetector(
              onTap: () => onPick(v),
              child: Container(
                width: 17,
                height: 17,
                foregroundDecoration: v == current
                    ? BoxDecoration(
                        border: Border.all(color: Sx.accent, width: 2),
                        borderRadius: BorderRadius.circular(4),
                      )
                    : null,
                decoration: BoxDecoration(
                  color: padColor(v),
                  border: Border.all(color: Sx.line2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);

  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: color ?? apcBody,
      border: Border.all(color: Sx.line2),
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// A small outlined pill, the old app's `.tag`.
class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: .45)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// Label and value pairs, the old app's `.kv`.
class _Kv extends StatelessWidget {
  const _Kv(this.rows);

  final List<(String, Widget)> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(k, style: TextStyle(fontSize: 12.5, color: Sx.dim)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 12.5), child: v),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
