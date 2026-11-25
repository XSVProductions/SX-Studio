import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import 'scene_work.dart';

// The Scene Editor's two step views: the strip of steps, and the grid of
// heads by steps (lit, dark, or not in the step). Both stay smooth with
// hundreds of steps: the strip builds only the chips on screen, and the grid
// is one painter that repaints only when the scene, the step or the picked
// heads change.

const _cell = 15.0, _cellH = 14.0, _gap = 2.0;

/// The old page's `.segrid`: one row per head, one column per step.
///
/// Tapping a cell picks that step and head, a step number picks the step,
/// a head name picks the head. With Shift (or Ctrl) held, a head is added
/// to the ones picked.
class SceneGrid extends StatelessWidget {
  const SceneGrid({super.key, required this.work, required this.cur, required this.sel, required this.selVer, required this.onPick});

  final SceneWork work;

  /// The step on screen.
  final int cur;

  /// The picked heads.
  final Set<String> sel;

  /// Goes up whenever [sel] changes, so the painter knows.
  final int selVer;

  /// (step or null, head id or null, add to the picked heads).
  final void Function(int? step, String? head, bool add) onPick;

  static bool get _multi => HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;

  @override
  Widget build(BuildContext context) {
    final heads = work.heads;
    if (heads.isEmpty) return const SizedBox.shrink();
    final n = work.steps.length;
    final names = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const SizedBox(height: _cellH + _gap + 2),
        for (final h in heads)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onPick(null, h.id, _multi),
            child: SizedBox(
              height: _cellH + _gap,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  h.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, height: 1.2, fontWeight: FontWeight.w500, color: sel.contains(h.id) ? Sx.text : Sx.dim),
                ),
              ),
            ),
          ),
      ],
    );
    final size = Size(n * (_cell + _gap), (heads.length + 1) * (_cellH + _gap) + 2);
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Sx.well,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width < 640 ? 96 : 170),
            child: names,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: GestureDetector(
                onTapUp: (d) {
                  final col = (d.localPosition.dx / (_cell + _gap)).floor();
                  final row = ((d.localPosition.dy - 2) / (_cellH + _gap)).floor() - 1;
                  if (col < 0 || col >= n) return;
                  onPick(col, row >= 0 && row < heads.length ? heads[row].id : null, _multi);
                },
                child: RepaintBoundary(
                  child: CustomPaint(size: size, painter: _GridPainter(work, cur, sel, work.ver, selVer, Sx.isLight)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.work, this.cur, this.sel, this.ver, this.selVer, this.light);

  final SceneWork work;
  final int cur;
  final Set<String> sel;
  final int ver, selVer;
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final steps = work.steps, heads = work.heads;
    final big = steps.length > 60;
    for (var i = 0; i < steps.length; i++) {
      if (big && i % 5 != 0) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(fontFamily: Sx.body, fontSize: 11, fontWeight: FontWeight.w500, color: i == cur ? Sx.text : Sx.dim),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(i * (_cell + _gap) + (_cell - tp.width) / 2, 0));
    }
    final fill = Paint(), stroke = Paint()..style = PaintingStyle.stroke;
    for (final (r, h) in heads.indexed) {
      final y = (r + 1) * (_cellH + _gap) + 2;
      for (final (i, w) in steps.indexed) {
        final rect = RRect.fromRectAndRadius(Rect.fromLTWH(i * (_cell + _gap), y, _cell, _cellH), const Radius.circular(3));
        if (!work.inStep(w, h.id)) {
          stroke
            ..color = Sx.line
            ..strokeWidth = 1;
          canvas.drawRRect(rect.deflate(.5), stroke);
        } else {
          fill.color = work.lit(w, h) ? Sx.accent : Sx.tabOn;
          canvas.drawRRect(rect, fill);
        }
        if (i == cur && sel.contains(h.id)) {
          stroke
            ..color = Sx.blue
            ..strokeWidth = 2;
          canvas.drawRRect(rect.inflate(1), stroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => o.ver != ver || o.selVer != selVer || o.cur != cur || o.light != light || o.work != work;
}

/// The old page's `.sesteps`: a chip per step with its number and time.
/// Only the chips on screen are built.
class StepStrip extends StatefulWidget {
  const StepStrip({super.key, required this.work, required this.cur, required this.playing, required this.onPick});

  final SceneWork work;
  final int cur;

  /// The step a playing preview is on, or -1.
  final int playing;
  final ValueChanged<int> onPick;

  @override
  State<StepStrip> createState() => _StepStripState();
}

class _StepStripState extends State<StepStrip> {
  static const _w = 58.0, _space = 6.0;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(StepStrip old) {
    super.didUpdateWidget(old);
    final at = widget.playing >= 0 ? widget.playing : widget.cur;
    if (at != (old.playing >= 0 ? old.playing : old.cur)) WidgetsBinding.instance.addPostFrameCallback((_) => _show(at));
  }

  /// Scrolls just enough to bring chip [i] into view.
  void _show(int i) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position, left = i * (_w + _space), right = left + _w;
    if (left < pos.pixels) {
      _scroll.jumpTo(left);
    } else if (right > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo((right - pos.viewportDimension).clamp(0, pos.maxScrollExtent));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemExtent: _w + _space,
        itemCount: work.steps.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(right: _space),
          child: _StepChip(
            n: i + 1,
            secs: stepSeconds(work.steps[i].cs),
            on: i == widget.cur,
            changed: work.stepChanged(i),
            copy: work.isCopy(i),
            playing: i == widget.playing,
            onTap: () => widget.onPick(i),
          ),
        ),
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.n,
    required this.secs,
    required this.on,
    required this.changed,
    required this.copy,
    required this.playing,
    required this.onTap,
  });

  final int n;
  final String secs;
  final bool on, changed, copy, playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: CustomPaint(
      painter: _ChipPainter(on: on, playing: playing, copy: copy, changed: changed, light: Sx.isLight),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$n',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.15, color: Sx.text),
            ),
            Text('$secs s', style: TextStyle(fontSize: 11, height: 1.15, color: Sx.dim)),
          ],
        ),
      ),
    ),
  );
}

/// A step chip's box: solid or dashed (a copied step), with a blue line
/// along the bottom when the step has changes.
class _ChipPainter extends CustomPainter {
  _ChipPainter({required this.on, required this.playing, required this.copy, required this.changed, required this.light});

  final bool on, playing, copy, changed, light;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(9));
    final fill = playing
        ? Sx.green.withValues(alpha: .18)
        : on
        ? Sx.accent.withValues(alpha: .13)
        : Sx.panel;
    canvas.drawRRect(r, Paint()..color = fill);
    if (changed) {
      canvas.save();
      canvas.clipRRect(r);
      canvas.drawRect(Rect.fromLTWH(0, size.height - 2, size.width, 2), Paint()..color = Sx.blue);
      canvas.restore();
    }
    final stroke = Paint()
      ..color = playing
          ? Sx.green
          : on
          ? Sx.accent
          : Sx.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(r.deflate(.5));
    if (!copy) {
      canvas.drawPath(path, stroke);
      return;
    }
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 4), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(_ChipPainter o) => o.on != on || o.playing != playing || o.copy != copy || o.changed != changed || o.light != light;
}
