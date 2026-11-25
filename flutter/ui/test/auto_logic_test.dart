import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/auto/auto_logic.dart';

void main() {
  const buttons = [
    AutoButton(title: 'CIRCLE', page: 'MOVEMENTS', dup: false, reach: true, swap: true),
    AutoButton(title: 'FIGURE 8', page: 'MOVEMENTS', dup: false, reach: true, swap: true),
    AutoButton(title: 'RED', page: 'COLORS', dup: false, reach: true, swap: false),
  ];

  test('a look with two buttons of a one-at-a-time page splits into one look each, keeping the rest', () {
    final c = AutoConfig(
      looks: [
        AutoLook(id: 'aaaaaaaa', name: 'Mix', bars: 8, on: true, titles: ['CIRCLE', 'RED', 'FIGURE 8']),
      ],
    );
    expect([for (final (page, many) in lookClashes(c.looks[0], buttons)) '$page: ${many.join(', ')}'], ['MOVEMENTS: CIRCLE, FIGURE 8']);

    expect(splitLook(c, 0, buttons, random: Random(1)), 2);
    expect([for (final l in c.looks) l.name], ['CIRCLE', 'FIGURE 8']);
    expect(
      [for (final l in c.looks) l.titles],
      [
        ['RED', 'CIRCLE'],
        ['RED', 'FIGURE 8'],
      ],
    );
    expect(c.looks[0].id, 'aaaaaaaa');
    expect(c.looks.every((l) => l.bars == 8), isTrue);
  });

  test('tap tempo needs three taps and starts over after a two second gap', () {
    var (taps, bpm) = tapTempo([], 0);
    expect(bpm, isNull);
    (taps, bpm) = tapTempo(taps, 500);
    expect(bpm, isNull);
    (taps, bpm) = tapTempo(taps, 1000);
    expect(bpm, 120);
    (taps, bpm) = tapTempo(taps, 4000);
    expect(taps, [4000]);
    expect(bpm, isNull);
  });

  test('progress counts on from the status by the clock, and stands still when held', () {
    const s = AutoStatus(running: true, bars: 2, bar: 1, beat: 1, msLeft: 4000, bpm: 120);
    // 2 bars at 120 BPM is 4 seconds; 2.5 s in is bar 2, beat 2
    final p = lookProgress(s, 2500);
    expect((p.bar, p.beat, p.leftMs), (2, 2, 1500));
    expect(p.fraction, closeTo(.625, 1e-9));

    const held = AutoStatus(running: true, held: true, bars: 4, bar: 3, beat: 2, msLeft: 900, bpm: 120);
    final h = lookProgress(held, 5000);
    expect((h.bar, h.beat, h.leftMs), (3, 2, null));
  });

  test('BPM keeps one decimal between 40 and 220', () {
    expect(clampBpm(300), 220);
    expect(clampBpm(12), 40);
    expect(clampBpm(127.46), 127.5);
    expect(bpmText(128), '128');
    expect(bpmText(127.5), '127.5');
  });
}
