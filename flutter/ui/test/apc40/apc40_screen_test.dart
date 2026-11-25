import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/apc40/apc40_screen.dart';

import '../health/fixture.dart';

Map<String, Object?> _button(String title, String page, {int on = 5, int off = 6}) => {
  'title': title,
  'page': 1,
  'pageName': page,
  'color': '#FF0000',
  'on': on,
  'off': off,
  'dup': false,
};

/// RED top left and BLUE next to it on Dancefloor, GREEN top left on Dinner.
Map<String, Object?> _info({bool windows = true, Map<String, Object?>? layout}) => {
  'ok': true,
  'show': 'Test',
  'file': 'apc40.json',
  'layout':
      layout ??
      {
        'pages': [
          {
            'name': 'Dancefloor',
            'pads': {'32': 'RED', '33': 'BLUE'},
          },
          {
            'name': 'Dinner',
            'pads': {'32': 'GREEN'},
          },
        ],
        'faders': <String, Object?>{},
      },
  'buttons': [_button('RED', 'COLORS'), _button('BLUE', 'COLORS'), _button('GREEN', 'COLORS'), _button('SPIN', 'MOVES')],
  'faders': [
    {'k': 0, 'caption': 'MOVEMENTS', 'type': 'speed'},
  ],
  'windows': windows,
  'status': null,
};

Canned _canned({Object? save}) => Canned({
  '/api/apc40': _info(),
  '/api/apc40/status': {'ok': true, 'status': null},
  '/api/apc40/save': ?save,
});

/// The pad showing [title] in the grid.
Finder _pad(String title) => find.descendant(of: find.byType(GridView), matching: find.text(title));

Map<String, Object?> _savedPads(Canned c, int page) {
  final layout = c.posts.lastWhere((p) => p.$1 == '/api/apc40/save').$2['layout']! as Map;
  return ((layout['pages']! as List)[page] as Map)['pads']! as Map<String, Object?>;
}

Future<void> _mouseDrag(WidgetTester t, Finder from, Finder to) async {
  final g = await t.startGesture(t.getCenter(from), kind: PointerDeviceKind.mouse);
  await g.moveBy(const Offset(20, 0));
  await t.pump();
  await g.moveTo(t.getCenter(to));
  await t.pump();
  await g.up();
  await t.pumpAndSettle();
}

void main() {
  testWidgets('pick a pad, pick a button: it goes on the pad, the next pad is picked, and Save sends the layout', (t) async {
    final c = _canned(save: _info());
    final (app, end) = await pumpScreen(t, c, Apc40Screen.new, tab: 'apc40');
    expect(c.gets, contains('/api/apc40/status'));

    await t.tap(_pad('BLUE'));
    await t.pump();
    expect(find.text('Pad: row 1, column 2'), findsOneWidget);
    await t.tap(find.text('SPIN'));
    await t.pump();
    expect(find.text('Pad: row 1, column 3'), findsOneWidget);
    expect(_pad('SPIN'), findsOneWidget);
    expect(app.dirtyTabs, contains('apc40'));

    await t.tap(find.text('Save APC40 pages'));
    await t.pumpAndSettle();
    expect(_savedPads(c, 0), {'32': 'RED', '33': 'SPIN'});
    expect(find.text('Saved. The APC40 uses it straight away.'), findsOneWidget);
    await end();
  });

  testWidgets('a refused save says why in the bar and keeps the edits', (t) async {
    final c = _canned(save: {'ok': false, 'error': 'Nothing to save.'});
    final (app, end) = await pumpScreen(t, c, Apc40Screen.new, tab: 'apc40');
    await t.tap(_pad('RED'));
    await t.pump();
    await t.tap(find.text('Clear this pad'));
    await t.pump();
    await t.tap(find.text('Save APC40 pages'));
    await t.pumpAndSettle();
    expect(find.text('Not saved: Nothing to save.'), findsOneWidget);
    expect(app.dirtyTabs, contains('apc40'));
    await end();
  });

  testWidgets('a press outside the grid and panel, or Esc, lets go of the pad', (t) async {
    final (_, end) = await pumpScreen(t, _canned(), Apc40Screen.new, tab: 'apc40');
    await t.tap(_pad('RED'));
    await t.pump();
    expect(find.text('Pad: row 1, column 1'), findsOneWidget);
    await t.tap(find.text('Search ShowXpress buttons…'));
    await t.pump();
    expect(find.text('Pad: row 1, column 1'), findsOneWidget, reason: 'the side panel keeps it');

    await t.tap(find.text('APC40 faders'));
    await t.pump();
    expect(find.text('Page 1'), findsOneWidget);

    await t.tap(_pad('RED'));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.text('Page 1'), findsOneWidget);
    await end();
  });

  testWidgets('right-click a pad, Clear this pad', (t) async {
    final (app, end) = await pumpScreen(t, _canned(), Apc40Screen.new, tab: 'apc40');
    await t.tap(_pad('RED'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(find.text('RED - row 1, column 1'), findsOneWidget);
    await t.tap(find.text('Clear this pad'));
    await t.pumpAndSettle();
    expect(_pad('RED'), findsNothing);
    expect(app.dirtyTabs, contains('apc40'));
    await end();
  });

  testWidgets('drag a pad onto another to swap them, or onto a page tab to send it there', (t) async {
    final (_, end) = await pumpScreen(t, _canned(), Apc40Screen.new, tab: 'apc40');
    await _mouseDrag(t, _pad('RED'), _pad('BLUE'));
    expect(t.getCenter(_pad('BLUE')).dx, lessThan(t.getCenter(_pad('RED')).dx));

    await _mouseDrag(t, _pad('RED'), find.text('2 · Dinner'));
    expect(find.text('RED moved to Dinner (same spot).'), findsOneWidget);
    expect(_pad('RED'), findsNothing);
    await t.tap(find.text('2 · Dinner'));
    await t.pump();
    expect(_pad('RED'), findsOneWidget);
    await end();
  });

  testWidgets('a finger moves a pad only after a long press, so a swipe over the grid scrolls', (t) async {
    final (_, end) = await pumpScreen(t, _canned(), Apc40Screen.new, tab: 'apc40', width: 390);
    final red = t.getCenter(_pad('RED'));
    await t.dragFrom(red, t.getCenter(_pad('BLUE')) - red);
    await t.pumpAndSettle();
    expect(t.getCenter(_pad('RED')).dx, lessThan(t.getCenter(_pad('BLUE')).dx));

    final g = await t.startGesture(t.getCenter(_pad('RED')));
    await t.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveTo(t.getCenter(_pad('BLUE')));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    expect(t.getCenter(_pad('BLUE')).dx, lessThan(t.getCenter(_pad('RED')).dx));
    await end();
  });

  testWidgets('pages: add one, name it, and it can be deleted after asking', (t) async {
    final (_, end) = await pumpScreen(t, _canned(), Apc40Screen.new, tab: 'apc40');
    await t.tap(find.text('Add a page'));
    await t.pumpAndSettle();
    expect(find.text('3 · Page 3'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Late');
    await t.pump();
    expect(find.text('3 · Late'), findsOneWidget);
    await t.tap(find.text('Delete this page'));
    await t.pumpAndSettle();
    expect(find.text('Delete page 3 (Late)?'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.text('3 · Late'), findsNothing);
    expect(find.text('Page 2'), findsOneWidget);
    await end();
  });

  testWidgets('on a Mac the status line says the APC40 works on Windows', (t) async {
    final c = Canned({
      '/api/apc40': _info(windows: false),
      '/api/apc40/status': {'ok': true, 'status': null},
    });
    final (_, end) = await pumpScreen(t, c, Apc40Screen.new, tab: 'apc40');
    expect(find.textContaining('The APC40 works with SX Studio on Windows.', findRichText: true), findsOneWidget);
    await end();
  });
}
