import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/apc/apc_screen.dart';

import '../health/fixture.dart';

final _apc = {
  'ok': true,
  'show': 'C:/Shows/Test',
  'pads': [
    {
      'sec': 'page1_button1',
      'page': 1,
      'pageName': 'COLORS',
      'title': 'RED',
      'scene': 'RED.scex',
      'sceneOk': true,
      'note': 0,
      'type': 0,
      'channel': 1,
      'device': 0,
      'outNote': 0,
      'on': 5,
      'off': 6,
      'color': -1,
      'key': '',
    },
  ],
  'faders': <Object>[],
  'buttons': 1,
};

int _reads(Canned c) => c.gets.where((g) => g == '/api/apc').length;

void main() {
  testWidgets('opening the tab again reads the pads again, unless there are unsaved moves', (t) async {
    final c = Canned({'/api/apc': _apc});
    final (app, end) = await pumpScreen(t, c, ApcScreen.new, tab: 'apc');
    expect(_reads(c), 1);

    app.go('home');
    await t.pumpAndSettle();
    app.go('apc');
    await t.pumpAndSettle();
    expect(_reads(c), 2);

    await t.tap(find.text('RED').first);
    await t.pump();
    await t.tap(find.text('free').first);
    await t.pump();
    expect(app.dirtyTabs, contains('apc'));
    app.go('home');
    await t.pumpAndSettle();
    app.go('apc');
    await t.pumpAndSettle();
    expect(_reads(c), 2);
    await end();
  });
}
