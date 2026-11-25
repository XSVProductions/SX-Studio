import 'dart:math' as math;

import 'package:sx_api/sx_api.dart';

import '../color/color_wheel.dart' show jsRound;
import '../color/on_the_lights.dart';

/// Where a look is [ms] milliseconds after it started: the step, how far into
/// it (0 to 1), and the milliseconds left until the next step. It loops. A
/// beat look is shown at 120 BPM, a flash every 500 ms. Port of `lkAt`.
({int at, double frac, int left}) lookAt(BuiltLook l, int ms) {
  final lens = [for (final s in l.steps) s.len * 10];
  final total = lens.fold(0, (a, b) => a + b);
  final cycle = l.beat ? 500 : total;
  if (lens.isEmpty || cycle <= 0) return (at: 0, frac: 0, left: 1 << 30);
  final pos = ms % cycle;
  var p = pos, at = 0, end = lens[0];
  while (at < lens.length - 1 && p >= lens[at]) {
    p -= lens[at];
    at++;
    end += lens[at];
  }
  final next = at == lens.length - 1 ? cycle : math.min(end, cycle);
  return (at: at, frac: math.min(1, p / lens[at]), left: math.max(1, next - pos));
}

/// The DMX bytes of the look at step [at], [frac] of the way in: each
/// channel of each head at its address, a fading channel part way from the
/// step before. Port of `lkFrame`.
LiveFrame lookFrame(LookRig rig, BuiltLook l, int at, double frac) {
  final out = <String, String>{};
  if (l.steps.isEmpty) return out;
  final byId = {for (final h in rig.heads) h.id: h};
  final s = l.steps[at], prev = l.steps[(at - 1 + l.steps.length) % l.steps.length];
  for (final MapEntry(key: id, value: chans) in s.f.entries) {
    final h = byId[id];
    if (h == null || h.addr == 0) continue;
    final pv = {for (final c in prev.f[id] ?? const <List<int>>[]) c[0]: c[1]};
    for (final c in chans) {
      final ch = h.addr + c[0];
      if (ch < 1 || ch > 8192) continue;
      num v = c[1];
      final from = pv[c[0]];
      if (c.length > 2 && c[2] != 0 && l.steps.length > 1 && from != null) v = from + (v - from) * frac;
      out['b$ch'] = 'b:$ch:${jsRound(v).clamp(0, 255)}';
    }
  }
  return out;
}
