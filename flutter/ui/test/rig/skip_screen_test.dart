import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/skip/skip_screen.dart';

import 'harness.dart';

Map<String, Object?> _head(String id, int num, bool is140, bool on) => {'id': id, 'label': '${is140 ? 140 : 251} #$num', 'num': num, 'is140': is140, 'on': on};

void main() {
  testWidgets('SKIP FLASH needs two heads, and Save sends the picked ones', (tester) async {
    final e = FakeEngine({
      '/api/skip': {
        'ok': true,
        'show': 'Test',
        'scene': 'skip.scex',
        'stepCs': 10,
        'unknown': 0,
        'heads': [_head('1', 1, true, true), _head('2', 2, true, true), _head('3', 3, true, false), _head('9', 1, false, false)],
        'order': ['140 #1', '140 #2'],
        'order140': [1, 2, 3],
        'order251': [1],
      },
    });
    final app = await pumpScreen(tester, e, 'skip', SkipScreen.new);
    expect(find.text('2 of 3'), findsOneWidget);

    await tap(tester, find.text('#2'));
    expect(app.dirtyTabs, {'skip'});
    expect(find.text('Pick at least 2 heads.'), findsOneWidget);
    expect(barButton<FilledButton>(tester, 'Save').onPressed, isNull);

    await tap(tester, find.text('#3'));
    await tap(tester, find.text('#1').last); // the 251
    expect(find.textContaining('one loop 0.30 s', findRichText: true), findsOneWidget);

    await tap(tester, find.widgetWithText(FilledButton, 'Save'));
    expect(e.posts.single.path, '/api/skip/apply');
    expect(e.posts.single.body, {
      'heads': ['1', '3', '9'],
    });
    await finish(tester, app);
  });
}
