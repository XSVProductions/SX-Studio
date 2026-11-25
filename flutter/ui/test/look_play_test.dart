import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/look/look_play.dart';

/// Two steps of 0.2 s and 0.3 s; head 1 at address 10, its channel 0 fading.
BuiltLook _look({bool beat = false}) {
  final a = BuiltStep(20), b = BuiltStep(30);
  a.f['1'] = [
    [0, 0, 1],
    [1, 255],
  ];
  b.f['1'] = [
    [0, 200, 1],
    [1, 0],
  ];
  return BuiltLook([a, b], beat: beat);
}

LookRig _rig() => const LookRig(
  show: '/show',
  sxOpen: false,
  heads: [LookHead(id: '1', name: 'PAR 1', model: 'RGB PAR', addr: 10)],
  skipped: [],
  models: {},
  scenes: [],
);

void main() {
  test('steps follow their times and loop', () {
    final l = _look();
    expect(lookAt(l, 0), (at: 0, frac: 0.0, left: 200));
    expect(lookAt(l, 250), (at: 1, frac: 50 / 300, left: 250));
    expect(lookAt(l, 650).at, 0); // 500 ms round
  });

  test('a beat look is shown at 120 BPM', () {
    final l = _look(beat: true);
    expect(lookAt(l, 450), (at: 1, frac: 250 / 300, left: 50));
    expect(lookAt(l, 520).at, 0);
  });

  test('the frame puts each channel at the head address, fading ones part way', () {
    final l = _look();
    expect(lookFrame(_rig(), l, 1, .5), {'b10': 'b:10:100', 'b11': 'b:11:0'});
    expect(lookFrame(_rig(), l, 0, 0), {'b10': 'b:10:200', 'b11': 'b:11:255'});
  });
}
