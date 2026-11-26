import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';

/// The part of the 0..65535 pan/tilt range in view: top-left corner and size.
typedef MoveView = ({double x, double y, double s});

const wholeRange = (x: 0.0, y: 0.0, s: 65535.0);

/// A head's color: spread round the hue circle. Port of `mvHue`.
Color moveHue(int i, int n, double a) => HSLColor.fromAHSL(a, (360 * i / math.max(1, n)).roundToDouble(), .85, .62).toColor();

/// What the canvas shows and how it reports edits. The canvas itself keeps
/// only the drag in progress.
class MoveCanvasModel {
  const MoveCanvasModel({required this.doc, required this.state, required this.sec, required this.point, required this.view, required this.at});

  final MoveDoc doc;
  final MoveState state;

  /// Index of the section on show.
  final int sec;

  /// The selected point, or -1.
  final int point;

  /// The pan/tilt range in view (the shape only).
  final MoveView view;

  /// Where the heads are drawn: ms into the movement.
  final double at;

  bool get shape => doc.secs[sec].isShape;
}

/// The drawing of one section: the pan/tilt shape (with every head's copy of
/// it) or a value graph. Drag a point to move it, drag empty space to move the
/// whole shape, double-tap to add a point. Repaints when something changes
/// and at each tick of [clock].
///
/// Port of the old page's `mvDraw`, `mvDown`, `mvMove`, `mvUp` and `mvDbl`.
class MoveCanvas extends StatefulWidget {
  const MoveCanvas({
    super.key,
    required this.model,
    required this.onSelect,
    required this.onDrag,
    required this.onDragEnd,
    required this.onAdd,
    this.clock,
    this.now,
  });

  final MoveCanvasModel model;

  /// Ticks while the heads move (the old `mvAnim`). Each tick repaints the
  /// canvas, and nothing else, with the heads where [now] puts them.
  final Listenable? clock;

  /// Ms into the movement right now. Null draws the heads at the model's `at`.
  final double Function()? now;

  /// A point was picked (-1: none).
  final ValueChanged<int> onSelect;

  /// The points while a drag moves them. Not yet a step to go back to.
  final ValueChanged<List<MovePt>> onDrag;

  /// A drag finished. [before] is the state from before it, for "step back".
  final ValueChanged<MoveState> onDragEnd;

  /// Double-tap on empty space: add a point there (canvas pixels).
  final void Function(Offset at, Size size) onAdd;

  @override
  State<MoveCanvas> createState() => _MoveCanvasState();
}

class _Drag {
  _Drag(this.i, this.from, this.start, this.before);

  final int i;
  final Offset from;
  final List<MovePt> start;
  final MoveState before;
  var moved = false;
}

class _MoveCanvasState extends State<MoveCanvas> {
  _Drag? _drag;
  Size _size = Size.zero;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapAt = Offset.zero;

  MoveCanvasModel get m => widget.model;

  /// The nearest point within reach of a finger (or a mouse), or -1.
  int _hit(Offset at, PointerDeviceKind kind) {
    final reach = kind == PointerDeviceKind.mouse ? 13.0 : 24.0;
    var best = -1, bd = reach * reach;
    final pts = m.state.secs[m.sec].pts;
    for (var i = 0; i < pts.length; i++) {
      final q = toPx(m, pts[i], _size);
      final d = (q - at).distanceSquared;
      if (d <= bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
    final i = _hit(e.localPosition, e.kind);
    _drag = _Drag(i, e.localPosition, [...m.state.secs[m.sec].pts], m.state);
    if (i >= 0) widget.onSelect(i);
  }

  void _move(PointerMoveEvent e) {
    final d = _drag;
    if (d == null) return;
    final at = e.localPosition;
    if (!d.moved && (at.dx - d.from.dx).abs() + (at.dy - d.from.dy).abs() < 3) return;
    d.moved = true;
    final pts = [...d.start];
    if (d.i >= 0) {
      pts[d.i] = fromPx(m, at, _size);
    } else if (m.shape && pts.isNotEmpty) {
      final a = fromPxRaw(m, d.from, _size), b = fromPxRaw(m, at, _size);
      final x0 = pts.map((p) => p.$1).reduce(math.min), x1 = pts.map((p) => p.$1).reduce(math.max);
      final y0 = pts.map((p) => p.$2).reduce(math.min), y1 = pts.map((p) => p.$2).reduce(math.max);
      final dx = (b.dx - a.dx).clamp(-x0.toDouble(), (moveMax - x1).toDouble()), dy = (b.dy - a.dy).clamp(-y0.toDouble(), (moveMax - y1).toDouble());
      for (var i = 0; i < pts.length; i++) {
        pts[i] = (clamp16(d.start[i].$1 + dx), clamp16(d.start[i].$2 + dy));
      }
    } else {
      return;
    }
    widget.onDrag(pts);
  }

  void _up(PointerEvent e) {
    final d = _drag;
    _drag = null;
    if (d == null) return;
    if (d.moved) {
      widget.onDragEnd(d.before);
      return;
    }
    if (e is PointerCancelEvent) return;
    // Two taps close together: add a point.
    final now = DateTime.now();
    final dbl = now.difference(_lastTap).inMilliseconds < 350 && (e.localPosition - _lastTapAt).distance < 20;
    _lastTap = dbl ? DateTime.fromMillisecondsSinceEpoch(0) : now;
    _lastTapAt = e.localPosition;
    if (dbl && d.i < 0) {
      widget.onAdd(e.localPosition, _size);
    } else if (d.i < 0 && m.point >= 0) {
      widget.onSelect(-1);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth;
      _size = Size(w, m.shape ? w : 220);
      return Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: RepaintBoundary(
          child: CustomPaint(size: _size, painter: _Painter(m, widget.now, widget.clock)),
        ),
      );
    },
  );
}

int clamp16(num v) => v.round().clamp(0, moveMax);

// ---- canvas pixels and movement values. Port of mvToPx, mvFromPx, mvGx, mvGy and their inverses.

double _gx(double x, double w) => 30 + x / moveMax * (w - 40);
double _gy(double y, double h) => h - 18 - y / moveMax * (h - 30);

/// A point's place on the canvas.
Offset toPx(MoveCanvasModel m, MovePt p, Size s) =>
    m.shape ? shapePx(m.view, (p.$1.toDouble(), p.$2.toDouble()), s) : Offset(_gx(p.$1.toDouble(), s.width), _gy(p.$2.toDouble(), s.height));

Offset shapePx(MoveView v, (double, double) p, Size s) => Offset((p.$1 - v.x) / v.s * s.width, (p.$2 - v.y) / v.s * s.height);

/// Canvas pixels to movement values, not rounded or clamped (pan/tilt only).
Offset fromPxRaw(MoveCanvasModel m, Offset at, Size s) => Offset(m.view.x + at.dx / s.width * m.view.s, m.view.y + at.dy / s.height * m.view.s);

/// Canvas pixels to a point. A value graph's value snaps to whole DMX steps (256).
MovePt fromPx(MoveCanvasModel m, Offset at, Size s) {
  if (m.shape) {
    final q = fromPxRaw(m, at, s);
    return (clamp16(q.dx), clamp16(q.dy));
  }
  final x = (at.dx - 30) / (s.width - 40) * moveMax, y = (s.height - 18 - at.dy) / (s.height - 30) * moveMax;
  return (clamp16(x), clamp16((y / 256).round() * 256));
}

class _Painter extends CustomPainter {
  _Painter(this.m, this.now, Listenable? clock) : light = Sx.isLight, super(repaint: clock);

  final MoveCanvasModel m;
  final double Function()? now;

  /// Where the heads are in the movement as this frame is painted.
  double get _at => now?.call() ?? m.at;

  /// The theme it was painted in, so a theme switch repaints.
  final bool light;

  void _text(Canvas c, String t, Offset at, {Color? color, double size = 11, FontWeight weight = FontWeight.w400, TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(color: color ?? Sx.dim, fontSize: size, fontWeight: weight, fontFamily: Sx.body),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (align) {
      TextAlign.center => tp.width / 2,
      TextAlign.right => tp.width,
      _ => 0.0,
    };
    tp.paint(c, at - Offset(dx, tp.height / 2));
  }

  Path _line(Iterable<Offset> pts) {
    final path = Path();
    var first = true;
    for (final q in pts) {
      if (first) {
        path.moveTo(q.dx, q.dy);
      } else {
        path.lineTo(q.dx, q.dy);
      }
      first = false;
    }
    return path;
  }

  /// An axis name with a small arrow after it, pointing the way the value grows.
  void _axis(Canvas c, String t, Offset at) {
    _text(c, t, at);
    final x = at.dx + (t.length * 6.0) + 4, y = at.dy;
    final p = Paint()
      ..color = Sx.dim
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    c.drawPath(
      Path()
        ..moveTo(x, y)
        ..lineTo(x + 10, y)
        ..moveTo(x + 6, y - 3)
        ..lineTo(x + 10, y)
        ..lineTo(x + 6, y + 3),
      p,
    );
  }

  @override
  void paint(Canvas c, Size size) {
    final w = m.state.secs[m.sec], s = m.doc.secs[m.sec];
    final grid = Paint()
      ..color = Sx.line
      ..strokeWidth = 1;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final n = m.doc.heads.length;
    c.clipRect(Offset.zero & size);
    if (s.isShape) {
      final v = m.view, cen = moveCentre(w.pts);
      // Grid every 1/8 of the range that is in view.
      for (var k = 0; k <= 8; k++) {
        final a = k * moveMax / 8, x = (a - v.x) / v.s * size.width, y = (a - v.y) / v.s * size.height;
        if (x >= 0 && x <= size.width) c.drawLine(Offset(x, 0), Offset(x, size.height), grid);
        if (y >= 0 && y <= size.height) c.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
      _axis(c, 'pan', Offset(size.width - 44, size.height - 10));
      c.save();
      c.translate(12, 46);
      c.rotate(math.pi / 2);
      _axis(c, 'tilt', Offset.zero);
      c.restore();
      final steps = math.max(48, w.pts.length * 24);
      final path = [for (var k = 0; k <= steps; k++) movePathAt(w.pts, w.tr, k / steps)];
      // Each head's own copy of the shape (its aim and size), faint.
      for (final (hi, h) in m.doc.heads.indexed) {
        c.drawPath(_line(path.map((p) => shapePx(v, moveHeadXY(h, m.state.heads[hi], cen, p), size))), stroke..color = moveHue(hi, n, .35));
      }
      c.drawPath(
        _line(path.map((p) => shapePx(v, p, size))),
        stroke
          ..color = Sx.accent
          ..strokeWidth = 2.2,
      );
      stroke.strokeWidth = 1;
      for (final (i, p) in w.pts.indexed) {
        final q = shapePx(v, (p.$1.toDouble(), p.$2.toDouble()), size);
        c.drawCircle(q, i == m.point ? 8 : 6, Paint()..color = i == m.point ? Sx.blue : Sx.accent);
        _text(c, '${i + 1}', q, color: Sx.isLight ? Sx.bg : Sx.onPrimary, size: 10, weight: FontWeight.w700, align: TextAlign.center);
      }
      // Where each head is at [m.at].
      if (w.pts.isNotEmpty) {
        for (final (hi, h) in m.doc.heads.indexed) {
          final q = shapePx(v, moveHeadXY(h, m.state.heads[hi], cen, movePathAt(w.pts, w.tr, movePhase(w, h.k, _at))), size);
          c.drawCircle(q, 5, Paint()..color = moveHue(hi, n, 1));
          if (n <= 8) _text(c, h.label.isEmpty ? '#${hi + 1}' : h.label, q + const Offset(7, -6), size: 10);
        }
      }
    } else {
      // A value graph: left to right is once round the cycle, bottom to top the value.
      for (var k = 0; k <= 4; k++) {
        final y = _gy(k * moveMax / 4, size.height);
        c.drawLine(Offset(30, y), Offset(size.width - 10, y), grid);
        _text(c, '${(k * 255 / 4).round()}', Offset(2, y));
      }
      for (var k = 0; k <= 4; k++) {
        final x = _gx(k * moveMax / 4, size.width);
        c.drawLine(Offset(x, 12), Offset(x, size.height - 18), grid);
        _text(c, '${k * 25}%', Offset(x, size.height - 8), align: k == 0 ? TextAlign.left : (k == 4 ? TextAlign.right : TextAlign.center));
      }
      final sorted = moveSorted(w.pts);
      if (sorted.isNotEmpty) {
        c.drawPath(
          _line([for (var k = 0; k <= 240; k++) Offset(_gx(k / 240 * moveMax, size.width), _gy(moveValAt(sorted, w.tr, k / 240 * moveMax), size.height))]),
          stroke
            ..color = Sx.accent
            ..strokeWidth = 2.2,
        );
        stroke.strokeWidth = 1;
      }
      for (final (i, p) in w.pts.indexed) {
        c.drawCircle(
          Offset(_gx(p.$1.toDouble(), size.width), _gy(p.$2.toDouble(), size.height)),
          i == m.point ? 8 : 6,
          Paint()..color = i == m.point ? Sx.blue : Sx.accent,
        );
      }
      for (final (hi, h) in m.doc.heads.indexed) {
        final u = movePhase(w, h.k, _at), x = _gx((u - u.floorToDouble()) * moveMax, size.width);
        c.drawLine(Offset(x, 12), Offset(x, size.height - 18), stroke..color = moveHue(hi, n, hi == 0 ? .9 : .35));
      }
    }
  }

  @override
  bool shouldRepaint(_Painter old) =>
      old.light != light ||
      old.m.state != m.state ||
      old.m.sec != m.sec ||
      old.m.point != m.point ||
      old.m.view != m.view ||
      old.m.at != m.at ||
      !identical(old.m.doc, m.doc);
}
