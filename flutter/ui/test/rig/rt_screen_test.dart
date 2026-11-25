import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/rt/rt_screen.dart';

import 'harness.dart';

const _towers = {'tl': 'Top left', 'tm': 'Top middle', 'tr': 'Top right', 'bl': 'Bottom left', 'bm': 'Bottom middle', 'br': 'Bottom right'};

/// Four 140s, two solid and two flashing, nothing placed yet.
FakeEngine _engine() => FakeEngine({
  '/api/rt': {
    'ok': true,
    'show': 'Test',
    'saved': null,
    'extra': false,
    'install': {'scene': true, 'old': false, 'button': true, 'setupPage': 1, 'where': ''},
    'heads': [
      for (final (i, look) in ['Red', 'Blue', 'White', 'Green'].indexed)
        {'id': '${i + 1}', 'num': i + 1, 'label': '140 #${i + 1}', 'look': look, 'hex': 'ff0000', 'flash': i >= 2},
    ],
    'slots': [
      for (final t in _towers.entries)
        for (final side in ['Left', 'Right'])
          {'key': '${t.key}-${side[0].toLowerCase()}', 'tower': t.key, 'towerName': t.value, 'side': side, 'x': 0, 'y': 0, 'extra': t.key.endsWith('m')},
    ],
    'assign': <String, Object?>{},
  },
});

/// Taps an empty spot (in tree order: tl-l, tl-r, tm-l, tm-r, tr-l, ...)
/// and picks head #[num] in the dialog.
Future<void> _place(WidgetTester tester, int spot, int num) async {
  await tap(tester, find.text('tap to set').at(spot));
  await tap(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('#$num')));
}

void main() {
  testWidgets('placing heads and saving sends the spots', (tester) async {
    final e = _engine();
    final app = await pumpScreen(tester, e, 'rt', RtScreen.new);
    expect(barButton<FilledButton>(tester, 'Save to 2D view').onPressed, isNull);

    await _place(tester, 0, 3);
    expect(app.dirtyTabs, {'rt'});
    // #3 moved from the spare heads onto the truss
    expect(find.text('White flashing'), findsNWidgets(2));

    // the same head on another spot leaves the first one
    await _place(tester, 0, 3); // tl-r is now the first empty spot
    await _place(tester, 3, 1); // tr-l: tl-l, tm-l, tm-r come first
    await tap(tester, find.widgetWithText(FilledButton, 'Save to 2D view'));

    expect(e.posts.single.path, '/api/rt/apply');
    expect(e.posts.single.body, {
      'assign': {'tl-r': '3', 'tr-l': '1'},
      'extra': false,
      'rig': true,
    });
    await finish(tester, app);
  });

  testWidgets('middle towers count only for a bigger event', (tester) async {
    final e = _engine();
    final app = await pumpScreen(tester, e, 'rt', RtScreen.new);

    await tap(tester, find.textContaining('Bigger event'));
    await _place(tester, 2, 2); // tm-l
    await tap(tester, find.textContaining('Also update'));
    await tap(tester, find.widgetWithText(FilledButton, 'Save to 2D view'));
    expect(e.posts.single.body, {
      'assign': {'tm-l': '2'},
      'extra': true,
      'rig': false,
    });

    // with the middle towers off again, nothing is on a truss
    await tap(tester, find.textContaining('Bigger event'));
    await _place(tester, 2, 2);
    await tap(tester, find.textContaining('Bigger event'));
    expect(find.text('Put at least one mover on a truss.'), findsOneWidget);
    expect(barButton<FilledButton>(tester, 'Save to 2D view').onPressed, isNull);
    await finish(tester, app);
  });
}
