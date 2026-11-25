import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';

// The aim maths of `df_aim.ps1`: head corrections, shape sizing, auto-symmetry
// and the curve a movement draws. Pure functions, pinned to the old tool's
// numbers by `test/aim_math_test.dart`.

/// A point of a movement shape (16-bit pan, tilt) while it is worked on.
typedef Pt = (double, double);

/// Smallest and largest size factor a corner may set.
const kMin = 0.3, kMax = 3.0;

/// A side may be off by this share of the half-size and still count as "meant symmetrical".
const symTol = 0.5;

/// Steps per shape point when a curved movement is rendered into a step scene.
const renderSub = 10;

/// Where a head points when step 2 is left alone: the front-left corner of the
/// normal floor. Port of `Get-DefaultCorner`.
PanTilt defaultCorner(PanTilt home, PanTilt refHalf) => (home.$1 - refHalf.$1, home.$2 + refHalf.$2);

/// One head's correction. Port of the hashtable `Get-HeadFix` returns.
class HeadFix {
  const HeadFix({this.op = 0, this.ot = 0, this.zp = 0, this.zt = 0, this.kp = 1.0, this.kt = 1.0, this.sized = false, this.warn = ''});

  /// OffsetPan / OffsetTilt.
  final int op;
  final int ot;

  /// ZoomPan / ZoomTilt.
  final int zp;
  final int zt;

  /// Size factor from the corner, clamped to [kMin]..[kMax].
  final double kp;
  final double kt;
  final bool sized;
  final String warn;
}

/// Works out a head's offsets and zooms from its step 1 [c] and step 2 [k]
/// aims. [reset] gives the "everything off" fix of Home.
///
/// The zoom comes from ShowXpress's measured size factor (1 + Zoom/100)^2,
/// so Zoom = 100 * (sqrt(k) - 1). Port of `Get-HeadFix`.
HeadFix headFix(PanTilt home, PanTilt refHalf, PanTilt c, PanTilt k, {bool reset = false}) {
  if (reset) return const HeadFix();
  final dp = c.$1 - home.$1, dt = c.$2 - home.$2;
  final op = dp.clamp(-32767, 32767), ot = dt.clamp(-32767, 32767);
  var warn = '';
  if (dp.abs() > 32767 || dt.abs() > 32767) warn = "CENTER TOO FAR from normal - check this head's step 1 aim";
  final dc = defaultCorner(home, refHalf);
  if (k == dc) return HeadFix(op: op, ot: ot, warn: warn);
  final kp0 = (k.$1 - c.$1).abs() / refHalf.$1, kt0 = (k.$2 - c.$2).abs() / refHalf.$2;
  if (kp0 < kMin || kp0 > kMax || kt0 < kMin || kt0 > kMax) warn = 'corner very close/far - size limited, check this head';
  final kp = math.max(kMin, math.min(kMax, kp0)), kt = math.max(kMin, math.min(kMax, kt0));
  return HeadFix(op: op, ot: ot, zp: psRound(100 * (math.sqrt(kp) - 1)), zt: psRound(100 * (math.sqrt(kt) - 1)), kp: kp, kt: kt, sized: true, warn: warn);
}

(double, double) _minMax(Iterable<double> v) => (v.reduce(math.min), v.reduce(math.max));

/// Scales a shape around the middle of its bounding box. Port of `Scale-Pts`.
List<Pt> scalePts(List<Pt> pts, double sx, double sy) {
  final (x0, x1) = _minMax(pts.map((p) => p.$1));
  final (y0, y1) = _minMax(pts.map((p) => p.$2));
  final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  return [for (final p in pts) (cx + (p.$1 - cx) * sx, cy + (p.$2 - cy) * sy)];
}

/// The middle and half-size of a shape, whole numbers, half at least 500.
/// Room mode's "normal". Port of `$midHalf`.
(PanTilt, PanTilt) midHalf(List<Pt> pts) {
  final (x0, x1) = _minMax(pts.map((p) => p.$1));
  final (y0, y1) = _minMax(pts.map((p) => p.$2));
  return ((psRound((x0 + x1) / 2), psRound((y0 + y1) / 2)), (psRound(math.max(500, (x1 - x0) / 2)), psRound(math.max(500, (y1 - y0) / 2))));
}

double _ax(Pt p, int a) => a == 0 ? p.$1 : p.$2;

Pt _with(int a, double along, double other) => a == 0 ? (along, other) : (other, along);

/// Mirror-averages a shape across its middle on axis [a] (0 = left/right,
/// 1 = up/down). Each point is paired with the point nearest its mirror image,
/// closest pairs first. Null when the shape is too lopsided to be meant
/// symmetrical. Port of `Get-Mirror`.
List<Pt>? mirror(List<Pt> pts, int a) {
  final o = 1 - a;
  final (lo, hi) = _minMax(pts.map((p) => _ax(p, a)));
  final c = (lo + hi) / 2, half = (hi - lo) / 2;
  if (half < 50) return [for (final p in pts) _with(a, c, _ax(p, o))];
  final n = pts.length;
  final pairs = <(double, int, int)>[];
  for (var i = 0; i < n; i++) {
    for (var j = i; j < n; j++) {
      final da = (2 * c - _ax(pts[i], a)) - _ax(pts[j], a), dd = _ax(pts[i], o) - _ax(pts[j], o);
      pairs.add((math.sqrt(da * da + dd * dd), i, j));
    }
  }
  mergeSort(pairs, compare: (x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : (x.$2 != y.$2 ? x.$2 - y.$2 : x.$3 - y.$3));
  final part = List.filled(n, -1);
  var maxd = 0.0;
  for (final (d, i, j) in pairs) {
    if (part[i] == -1 && part[j] == -1) {
      part[i] = j;
      part[j] = i;
      if (d > maxd) maxd = d;
    }
  }
  if (maxd > symTol * half) return null;
  return [for (var i = 0; i < n; i++) _with(a, (_ax(pts[i], a) + 2 * c - _ax(pts[part[i]], a)) / 2, (_ax(pts[i], o) + _ax(pts[part[i]], o)) / 2)];
}

/// A shape changed in Generator, made symmetrical and moved back to [home].
/// An axis that isn't meant symmetrical is only moved back to where [master]
/// (the last clean shape) had its middle, or to home for a new scene.
/// [onlyMove] skips the mirroring. Port of `Get-SymShape`.
({List<Pt> pts, String note}) symShape(List<Pt> pts, PanTilt home, List<Pt>? master, bool onlyMove) {
  var out = pts;
  final done = [false, false];
  if (!onlyMove) {
    for (final a in [0, 1]) {
      final r = mirror(out, a);
      if (r != null) {
        out = r;
        done[a] = true;
      }
    }
  }
  final shift = [0.0, 0.0];
  for (final a in [0, 1]) {
    final (lo, hi) = _minMax(out.map((p) => _ax(p, a)));
    final c = (lo + hi) / 2;
    var t = (a == 0 ? home.$1 : home.$2).toDouble();
    if (!done[a] && master != null) {
      final (mlo, mhi) = _minMax(master.map((p) => _ax(p, a)));
      t = (mlo + mhi) / 2;
    }
    shift[a] = t - c;
  }
  out = [for (final p in out) (p.$1 + shift[0], p.$2 + shift[1])];
  final note = done[0] && done[1]
      ? ' (changed in Generator -> made symmetrical + centered)'
      : done[0]
      ? ' (changed in Generator -> made symmetrical left/right + centered)'
      : done[1]
      ? ' (changed in Generator -> made symmetrical up/down + centered)'
      : ' (changed in Generator -> moved back to center, shape kept)';
  return (pts: out, note: note);
}

/// One position per step of a step scene made from a movement: where each
/// step fades to. Straight lines visit the points in turn. Curves
/// ([transition] 2) follow a closed cardinal spline with tangents
/// 0.75 x (next - previous), which is what ShowXpress's Generator draws,
/// [renderSub] steps per point. Port of `Get-CurvePath`.
List<Pt> curvePath(List<Pt> pts, int transition) {
  final n = pts.length;
  if (transition != 2) return [for (var k = 1; k <= n; k++) pts[k % n]];
  final all = <Pt>[];
  for (var k = 0; k < n; k++) {
    final p = [
      for (final d in [-1, 0, 1, 2]) pts[((k + d) % n + n) % n],
    ];
    for (var j = 0; j < renderSub; j++) {
      final t = j / renderSub;
      final xy = <double>[];
      for (final a in [0, 1]) {
        final p0 = _ax(p[0], a), p1 = _ax(p[1], a), p2 = _ax(p[2], a), p3 = _ax(p[3], a);
        final m1 = 0.75 * (p2 - p0), m2 = 0.75 * (p3 - p1);
        final t2 = t * t, t3 = t2 * t;
        xy.add((2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2);
      }
      all.add((xy[0], xy[1]));
    }
  }
  return [for (var k = 1; k <= all.length; k++) all[k % all.length]];
}

/// Reads "120" or "120 90" (width, depth in percent) into factors.
/// Port of `ConvertTo-Size`.
(double, double) parseSize(String input) {
  final parts = input.trim().split(RegExp(r'[\s,x/]+', caseSensitive: false)).where((s) => s.isNotEmpty).toList();
  final ok = RegExp(r'^\d+(\.\d+)?%?$');
  if (parts.isEmpty || parts.length > 2 || parts.any((p) => !ok.hasMatch(p))) {
    throw ToolError("Size '$input' not understood - use e.g. 100 or 120 90. NOTHING was changed.");
  }
  final w = double.parse(parts[0].replaceAll('%', '')), d = parts.length == 2 ? double.parse(parts[1].replaceAll('%', '')) : w;
  for (final v in [w, d]) {
    if (v < 20 || v > 300) throw ToolError('Size ${psNum(v)}% is outside 20-300. NOTHING was changed.');
  }
  return (w / 100, d / 100);
}

/// `"x,y;x,y"` as the state file keeps shapes. Port of `ConvertTo-Pts`.
List<Pt> textToPts(String s) => [
  for (final xy in s.split(';'))
    () {
      final v = xy.split(',');
      return (psDouble(v[0]), psDouble(v.length > 1 ? v[1] : null));
    }(),
];

/// Port of `ConvertFrom-Pts`: each value rounded half to even.
String ptsToText(List<Pt> pts) => pts.map((p) => '${psRound(p.$1)},${psRound(p.$2)}').join(';');

/// `[double]$x` for text from a file: '' and null are 0.
double psDouble(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1 : 0;
  final s = '$v'.trim();
  if (s.isEmpty) return 0;
  return double.tryParse(s) ?? (throw FormatException('Cannot convert "$v" to a number.'));
}

/// How PowerShell writes a number into text (`"$x"`, `-f '{0}'`): whole
/// numbers without ".0", doubles as [psDoubleText] writes them.
String psNum(num v) => v is int ? '$v' : psDoubleText(v.toDouble());

/// .NET's `{0:0}` for a double: rounded to 15 significant digits, then to a
/// whole number with halves away from zero.
String psFormat0(double v) {
  final r = double.parse(v.toStringAsPrecision(15));
  return '${r.round()}';
}

/// True when [name] matches any of [patterns]. Port of `Test-Like`.
bool likeAny(String name, Iterable<String> patterns) => patterns.any((p) => psLike(name, p));
