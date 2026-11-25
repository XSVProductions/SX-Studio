import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/rig/rig_screen.dart';
import 'package:sx_studio/widgets/sx_widgets.dart';

import 'harness.dart';

Map<String, Object?> _head(String id, int num, bool is140, {bool on = true, bool rp = false}) => {
  'id': id,
  'label': '${is140 ? 140 : 251} #$num',
  'num': num,
  'is140': is140,
  'on': on,
  'rp': rp,
  'rt': false,
};

/// Three 140s (#3 not hung, #2 pan reversed) and one 251, and a chase that
/// lights #1 then #3.
FakeEngine _engine() => FakeEngine({
  '/api/rig': {
    'ok': true,
    'show': 'Test',
    'heads': [_head('1', 1, true), _head('2', 2, true, rp: true), _head('3', 3, true, on: false), _head('9', 1, false)],
    'scenes': [
      {
        'file': 'chase.scex',
        'name': 'CHASE',
        'titles': ['CHASE'],
        'trimmed': false,
        'edited': false,
        'groups': [
          [0],
          [1],
        ],
        'steps': [
          {
            'cs': 50,
            'lit': ['1'],
            'other': false,
          },
          {
            'cs': 50,
            'lit': ['3'],
            'other': false,
          },
        ],
      },
    ],
  },
});

void main() {
  testWidgets('ticking a head and reversing one saves both together', (tester) async {
    final e = _engine();
    final app = await pumpScreen(tester, e, 'rig', RigScreen.new);
    expect(app.dirtyTabs, isEmpty);
    expect(barButton<FilledButton>(tester, 'Save').onPressed, isNull);
    // #3 is not hung, so the chase loses its second step
    expect(find.text('1 of 2 steps', findRichText: true), findsOneWidget);

    await tap(tester, find.text('#3').first);
    expect(app.dirtyTabs, {'rig'});
    expect(find.text('all 2 steps', findRichText: true), findsOneWidget);

    // pan on #1 (the first "pan" is in the 140 group)
    await tap(tester, find.text('pan').first);
    await tap(tester, find.widgetWithText(FilledButton, 'Save'));

    expect(e.posts.single.path, '/api/rig/apply');
    expect(e.posts.single.body, {
      'heads': ['1', '2', '3', '9'],
      'flip': {
        '1': {'pan': true, 'tilt': false},
        '2': {'pan': true, 'tilt': false},
      },
    });
    // the save reloads what the engine has, which matches again
    expect(app.dirtyTabs, isEmpty);
    // and the tabs that show the rig read the show again (old `S=null;H=null`)
    expect(app.sxCloses, 1);
    await finish(tester, app);
  });

  testWidgets('Undo puts the saved rig back; no heads ticked means no save', (tester) async {
    final e = _engine();
    final app = await pumpScreen(tester, e, 'rig', RigScreen.new);

    await tap(tester, find.widgetWithText(MiniButton, 'None').first);
    await tap(tester, find.widgetWithText(MiniButton, 'None').last);
    expect(find.text('0 of 3 hung'), findsOneWidget);
    expect(barButton<FilledButton>(tester, 'Save').onPressed, isNull);
    expect(find.text('Tick at least one head.'), findsOneWidget);

    await tap(tester, find.widgetWithText(TextButton, 'Undo'));
    expect(find.text('2 of 3 hung'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    expect(e.posts, isEmpty);
    await finish(tester, app);
  });

  testWidgets('reads the show again when ShowXpress closes or the queue saves', (tester) async {
    final e = _engine()..sxOpen = true;
    final app = await pumpScreen(tester, e, 'rig', RigScreen.new);
    await checkReloads(tester, e, app, 'rig', '/api/rig', () => tap(tester, find.text('#3').first));
    expect(find.text('2 of 3 hung'), findsOneWidget);
    await finish(tester, app);
  });
}
