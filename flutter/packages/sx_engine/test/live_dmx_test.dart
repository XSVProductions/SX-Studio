import 'dart:io';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

void main() {
  test('live output sets bytes, glides 16-bit values, and goes dark on stop', () async {
    final tmp = Directory.systemTemp.createTempSync('sx_dmx_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final log = File('${tmp.path}/frame.txt');
    // The sender rewrites the file every 25 ms, so a read can land mid-write
    // (empty, or locked on Windows). Keep reading until the frame shows up.
    Map<int, int>? read() {
      try {
        return {for (final l in log.readAsLinesSync().where((l) => l.contains('='))) int.parse(l.split('=')[0]): int.parse(l.split('=')[1])};
      } on FileSystemException {
        return null;
      } on FormatException {
        return null;
      }
    }

    Future<void> shows(Matcher want, {String? reason}) async {
      final giveUp = DateTime.now().add(const Duration(seconds: 3));
      Map<int, int>? got;
      while (DateTime.now().isBefore(giveUp)) {
        got = read();
        if (got != null && want.matches(got, {})) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(got, want, reason: reason);
    }

    final live = await LiveDmx.start(FakeDmxSpec(log.path));
    expect(live.iface, 'test interface');

    live.send('b:7:200 s:1:2:513 bogus b:9999:1 b:0:5');
    await shows(equals({1: 2, 2: 1, 7: 200}), reason: '513 = coarse 2, fine 1. Bad tokens are skipped');

    live.send('p:1:2:65535');
    await shows(containsPair(1, allOf(greaterThan(2), lessThan(255))), reason: 'a glide passes through the values in between');
    await shows(equals({1: 255, 2: 255, 7: 200}));

    live.send('z');
    await shows(isEmpty);

    live.send('b:3:9');
    await shows(equals({3: 9}));
    await live.stop();
    expect(live.running, isFalse);
    expect(log.readAsStringSync(), '', reason: 'lights out on stop');
  });
}
