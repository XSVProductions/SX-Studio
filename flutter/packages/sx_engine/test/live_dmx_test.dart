import 'dart:io';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

void main() {
  test('live output sets bytes, glides 16-bit values, and goes dark on stop', () async {
    final tmp = Directory.systemTemp.createTempSync('sx_dmx_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final log = File('${tmp.path}/frame.txt');
    Map<int, int> frame() => {for (final l in log.readAsLinesSync().where((l) => l.contains('='))) int.parse(l.split('=')[0]): int.parse(l.split('=')[1])};
    Future<void> frames(int n) => Future<void>.delayed(Duration(milliseconds: 25 * n + 40));

    final live = await LiveDmx.start(FakeDmxSpec(log.path));
    expect(live.iface, 'test interface');

    live.send('b:7:200 s:1:2:513 bogus b:9999:1 b:0:5');
    await frames(2);
    expect(frame(), {1: 2, 2: 1, 7: 200}, reason: '513 = coarse 2, fine 1. Bad tokens are skipped');

    live.send('p:1:2:65535');
    await frames(1);
    final mid = frame()[1]!;
    expect(mid, allOf(greaterThan(2), lessThan(255)), reason: 'a glide is on its way after one frame');
    await frames(30);
    expect(frame(), {1: 255, 2: 255, 7: 200});

    live.send('z');
    await frames(2);
    expect(frame(), isEmpty);

    live.send('b:3:9');
    await frames(2);
    await live.stop();
    expect(live.running, isFalse);
    expect(log.readAsStringSync(), '', reason: 'lights out on stop');
  });
}
