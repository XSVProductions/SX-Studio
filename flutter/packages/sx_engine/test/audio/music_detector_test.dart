import 'dart:typed_data';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'edm_track.dart';

/// Runs a whole track through the detector in 50 ms blocks, like a live feed.
List<MusicEvent> run(Float64List y, int fs, {double gain = 1}) {
  final d = MusicDetector(fs);
  final out = <MusicEvent>[];
  final step = fs ~/ 20;
  for (var i = 0; i < y.length; i += step) {
    final end = i + step < y.length ? i + step : y.length;
    final blk = Float64List(end - i);
    for (var k = 0; k < blk.length; k++) {
      blk[k] = y[i + k] * gain;
    }
    out.addAll(d.feed(blk));
  }
  return out;
}

List<double> times(List<MusicEvent> ev, MusicEventKind k) => [
  for (final e in ev)
    if (e.kind == k) e.t,
];

double median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

void main() {
  group('main track (break, build, drop, break, back)', () {
    final tr = EdmTrack.main();
    final ev = run(tr.y, tr.fs);

    test('one drop, on the first kick of the drop', () {
      final d = times(ev, MusicEventKind.drop);
      expect(d, hasLength(1));
      expect(d.single, closeTo(tr.drops.single, 0.05));
    });

    test('the break without a build comes back as a return, not a drop', () {
      final r = times(ev, MusicEventKind.back);
      expect(r, hasLength(1));
      expect(r.single, closeTo(tr.returns.single, 0.1));
    });

    test('the gap just before the drop', () {
      final g = times(ev, MusicEventKind.gap);
      expect(g, hasLength(1));
      expect(g.single, inInclusiveRange(tr.gaps.single.$1 - 0.05, tr.gaps.single.$2));
    });

    test('build starts during the build and climbs', () {
      final b = [
        for (final e in ev)
          if (e.kind == MusicEventKind.section && e.section == MusicSection.build) e.t,
      ];
      expect(b, hasLength(1));
      expect(b.single, inInclusiveRange(tr.builds.single.$1, tr.builds.single.$1 + 4));
      final lv = [
        for (final e in ev)
          if (e.kind == MusicEventKind.build && e.t > tr.builds.single.$1 + 2 && e.t < tr.builds.single.$2) e.value,
      ];
      // it falls again in the last beat or so, when the roll stops for the gap
      expect(lv.reduce((a, b) => a > b ? a : b), greaterThan(lv.first + 0.15));
    });

    test('tempo 128 and bar 1 on the downbeats after the drop', () {
      final beats = [
        for (final e in ev)
          if (e.kind == MusicEventKind.beat && e.t > 8) e,
      ];
      expect(median([for (final e in beats) e.value]), closeTo(128, 0.3));
      final bar = 4 * 60 / 128;
      final down = [
        for (final e in beats)
          if (e.t > tr.drops.single - 0.05 && (((e.t - tr.drops.single + 0.2) % bar) - 0.2).abs() < 0.06) e,
      ];
      expect(down.length, greaterThan(20));
      expect(down.every((e) => e.bar == 1), isTrue);
    });

    test('a quiet feed (-26 dB) gives the same drop', () {
      final q = run(tr.y, tr.fs, gain: 0.05);
      expect(times(q, MusicEventKind.drop).single, closeTo(times(ev, MusicEventKind.drop).single, 0.011));
    });
  });

  group('steady house groove', () {
    final tr = EdmTrack.steady();
    final ev = run(tr.y, tr.fs);

    test('no drop and no build', () {
      expect(times(ev, MusicEventKind.drop), isEmpty);
      expect(ev.where((e) => e.kind == MusicEventKind.section && e.section == MusicSection.build), isEmpty);
    });

    test('kicks found within 30 ms, nearly no extras', () {
      final k = times(ev, MusicEventKind.kick);
      final hits = tr.kicks.where((t) => k.any((x) => (t - x).abs() < 0.03)).length;
      expect(hits, greaterThanOrEqualTo((0.97 * tr.kicks.length).floor()));
      expect(k.length, lessThanOrEqualTo((1.03 * tr.kicks.length).ceil()));
    });

    test('beat clock within 15 ms of the kicks', () {
      const per = 60 / 124;
      final errs = [
        for (final e in ev)
          if (e.kind == MusicEventKind.beat && e.t > 8) (((e.t - tr.kicks.first + per / 2) % per) - per / 2).abs(),
      ]..sort();
      expect(errs[(errs.length * 0.95).floor()], lessThan(0.015));
    });

    test('a lead gives each beat out early, at the same beat time', () {
      final d = MusicDetector(tr.fs, leadS: 0.05);
      final y = tr.y;
      var seen = 0;
      var block = 0.0;
      for (var i = 0; i < y.length; i += 441) {
        final end = i + 441 < y.length ? i + 441 : y.length;
        final now = end / tr.fs;
        for (final e in d.feed(Float64List.sublistView(y, i, end))) {
          if (e.kind != MusicEventKind.beat || e.t < 8) continue;
          seen++;
          block = e.t - now;
          expect(block, greaterThan(0.03)); // known about before it happens
        }
      }
      expect(seen, greaterThan(100));
    });
  });
}
