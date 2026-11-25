import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/pre/pre_screen.dart';

import '../health/fixture.dart';

Map<String, Object?> _item(String title, {String level = 'ok', String group = 'Show'}) => {
  'group': group,
  'level': level,
  'title': title,
  'detail': '',
  'advice': '',
  'fix': null,
};

final _pre = {
  'ok': true,
  'show': 'C:/Shows/Test',
  'items': [_item('ShowXpress is open'), _item('DMX output is on in Live'), _item('Rig Test saved today'), _item('Controller found', group: 'Gear')],
};

final _health = {
  'ok': true,
  'show': 'C:/Shows/Test',
  'buttons': 10,
  'scenes': 9,
  'issues': [
    {'level': 'error', 'kind': 'scene', 'title': 'X', 'detail': '', 'advice': '', 'fix': null},
    {'level': 'warn', 'kind': 'key', 'title': 'Y', 'detail': '', 'advice': '', 'fix': null},
  ],
  'applied': <Object>[],
};

void main() {
  testWidgets('the Health Check goes third in the list and its button opens the tab', (t) async {
    final (app, end) = await pumpScreen(t, Canned({'/api/pre': _pre, '/api/health': _health}), PreScreen.new);
    final y = [
      'ShowXpress is open',
      'DMX output is on in Live',
      'Health Check: 1 problem(s) in the show',
      'Rig Test saved today',
    ].map((s) => t.getTopLeft(find.text(s)).dy).toList();
    expect(y, [...y]..sort());
    expect(find.text('1 thing(s) to fix before the show · 0 to check', findRichText: true), findsOneWidget);

    await t.tap(find.text('Open Health Check'));
    await t.pump();
    expect(app.tab, 'health');
    await end();
  });

  testWidgets('when the Health Check fails the rest still shows', (t) async {
    final (_, end) = await pumpScreen(
      t,
      Canned({
        '/api/pre': _pre,
        '/api/health': {'ok': false, 'error': 'boom'},
      }),
      PreScreen.new,
    );
    expect(find.text('Rig Test saved today'), findsOneWidget);
    expect(find.textContaining('Health Check'), findsNothing);
    expect(find.text('All good, ready for the show'), findsOneWidget);
    await end();
  });
}
