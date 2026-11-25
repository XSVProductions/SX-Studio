import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/scene/scene_work.dart';

import 'scene_fixture.dart';

void main() {
  late SceneWork w;
  setUp(() => w = SceneWork(testScene()));

  test('a fresh scene has nothing to save', () {
    expect(w.dirty, isFalse);
    expect([for (final s in w.body().steps) (s.src, s.set.length, s.len)], [(0, 0, null), (1, 0, null), (2, 0, null)]);
  });

  test('a changed value goes in the save, and undo takes it out', () {
    w.setValue(0, ['1|0'], 10);
    final b = w.body();
    expect(b.sha, 'abc123');
    expect(b.steps[0].set.single.toJson(), {'fx': '1', 'ix': 0, 'v': 10});
    expect(w.what(), '1 value');
    expect(w.stepChanged(0), isTrue);
    expect(w.stepChanged(1), isFalse);
    w.reset();
    expect(w.dirty, isFalse);
  });

  test('setting a value back to the file value is not a change', () {
    w.setValue(0, ['1|0'], 10);
    w.setValue(0, ['1|0'], 255);
    expect(w.dirty, isFalse);
  });

  test('step moves, copies and deletes', () {
    expect(w.move(0, 1), 1);
    expect(w.what(), 'steps moved');
    w.reset();
    w.copy(0);
    expect(w.isCopy(1), isTrue);
    expect([for (final s in w.body().steps) s.src], [0, 0, 1, 2]);
    expect(w.what(), '3 to 4 steps');
    w.reset();
    w.delete(1);
    expect([for (final s in w.body().steps) s.src], [0, 2]);
  });

  test('step time', () {
    w.setLen(1, 125);
    expect(w.body().steps[1].len, 125);
    expect(w.what(), '1 step time');
    w.setLenAll(50);
    expect([for (final s in w.body().steps) s.len], [null, 50, 50]);
  });

  test('a channel added and taken out again leaves nothing to save', () {
    w.addCh(['1'], 2);
    expect(w.body().addch.single.toJson(), {'fx': '1', 'ix': 2});
    expect(w.steps.every((s) => s.ch['1|2']?.v == 0), isTrue);
    expect(w.withChannel(['1', '2'], 2), ['1']);
    w.delCh(['1'], 2);
    expect(w.dirty, isFalse);
  });

  test('a channel taken out and put back gets its values back', () {
    w.delCh(['1'], 0);
    expect(w.body().delch.single.toJson(), {'fx': '1', 'ix': 0});
    expect(w.what(), '1 taken out');
    w.addCh(['1'], 0);
    expect(w.dirty, isFalse);
    expect(w.steps[0].ch['1|0']!.v, 255);
  });

  test('lit or dark: dimmer above 0 and the shutter not closed', () {
    final h1 = w.byId['1']!, h2 = w.byId['2']!;
    expect(w.lit(w.steps[0], h1), isTrue);
    expect(w.lit(w.steps[0], h2), isFalse);
    expect(w.lit(w.steps[1], h1), isFalse, reason: 'shutter 0 is in the closed range');
    expect(w.inStep(w.steps[1], '2'), isFalse);
  });

  test('channels to add are the model channels the picked heads lack', () {
    expect(
      [
        for (final c in w.addable(0, 'Spot', ['1'])) c.name,
      ],
      ['color'],
    );
    expect(w.addable(1, 'Spot', ['2']), isEmpty, reason: 'head 2 is not in step 2');
  });

  test('frames: a missing head keeps the step before, fades glide while playing', () {
    expect(w.frame(0), {1: 255, 2: 255, 11: 0, 12: 255});
    expect(w.frame(1), {1: 100, 2: 0, 11: 0, 12: 255});
    expect(w.frame(1, frac: .5)[1], 178, reason: 'halfway from 255 to 100, halves round up');
    expect(w.frame(1, frac: .5)[2], 0, reason: 'no fade on the shutter');
  });

  test('play position', () {
    final (at, frac) = w.playAt(600);
    expect(at, 1);
    expect(frac, closeTo(.1, 1e-9));
    expect(w.playAt(3600).$1, 0);
  });

  test('step seconds read like the old page', () {
    expect(stepSeconds(50), '0.5');
    expect(stepSeconds(125), '1.25');
    expect(stepSeconds(100), '1.0');
  });
}
