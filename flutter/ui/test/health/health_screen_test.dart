import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/health/health_screen.dart';

import 'fixture.dart';

const _applied = {
  'id': 'abcd1234',
  'title': 'WHEEL CHASE: colour wheel spins on loop',
  'label': 'Play it back and forth',
  'time': '2026-11-20 03:32',
  'what': '',
};
const _issue = {
  'level': 'error',
  'kind': 'speed',
  'title': 'CEILING: speed fader 9 doesn\'t exist',
  'detail': 'There are only 4 master faders.',
  'advice': 'Let it follow the first master fader.',
  'fix': {'key': 'speed|page1_button1', 'label': 'Use MOVEMENTS'},
};

Map<String, Object> _report({List<Object> applied = const [_applied]}) => {
  'ok': true,
  'show': 'C:/Shows/Test',
  'buttons': 10,
  'scenes': 9,
  'issues': [_issue],
  'applied': applied,
};

void main() {
  testWidgets('a fix asks first, then sends its key', (t) async {
    final c = Canned({
      '/api/health': _report(),
      '/api/health/fix': {'ok': true, 'out': 'Fixed.'},
    });
    final (_, end) = await pumpScreen(t, c, HealthScreen.new);
    await t.tap(find.text('Use MOVEMENTS'));
    await t.pumpAndSettle();
    expect(find.text('Apply this fix?'), findsOneWidget);
    await pressInDialog(t, 'Use MOVEMENTS');
    expect(c.posts.single.$1, '/api/health/fix');
    expect(c.posts.single.$2, {'key': 'speed|page1_button1'});
    await end();
  });

  testWidgets('a revert that meets later edits lists them and only forces after a second yes', (t) async {
    final c = Canned({
      '/api/health': [_report(), _report(applied: [])],
      '/api/health/revert': [
        {
          'ok': true,
          'out': '',
          'conflict': ['live.ini was changed after the fix.'],
        },
        {'ok': true, 'out': 'Put back live.ini.'},
      ],
    });
    final (_, end) = await pumpScreen(t, c, HealthScreen.new);
    await t.tap(find.text('Revert'));
    await t.pumpAndSettle();
    await pressInDialog(t, 'Revert');
    expect(c.posts.single.$2, {'id': 'abcd1234', 'force': false});
    expect(find.text('Changed since the fix'), findsOneWidget);
    expect(find.text('- live.ini was changed after the fix.'), findsOneWidget);

    await pressInDialog(t, 'Revert anyway');
    expect(c.posts.last.$2, {'id': 'abcd1234', 'force': true});
    expect(find.text('Reverted'), findsOneWidget);
    expect(find.text('Put back live.ini.'), findsOneWidget);
    await pressInDialog(t, 'OK');
    expect(find.text('Fixes you applied (1)'), findsNothing);
    await end();
  });

  testWidgets('cancelling the conflict leaves the fix in place', (t) async {
    final c = Canned({
      '/api/health': _report(),
      '/api/health/revert': {
        'ok': true,
        'out': '',
        'conflict': ['The scene was edited after the fix.'],
      },
    });
    final (_, end) = await pumpScreen(t, c, HealthScreen.new);
    await t.tap(find.text('Revert'));
    await t.pumpAndSettle();
    await pressInDialog(t, 'Revert');
    await pressInDialog(t, 'Cancel');
    expect(c.posts, hasLength(1));
    expect(find.text('Fixes you applied (1)'), findsOneWidget);
    await end();
  });

  testWidgets('reads the show again when ShowXpress closes', (t) async {
    final c = Canned({
      '/api/sx': [sxStatus(open: true), sxStatus()],
      '/api/health': _report(),
    });
    final (app, end) = await pumpScreen(t, c, HealthScreen.new, tab: 'health');
    expect(c.gets.where((g) => g == '/api/health'), hasLength(1));
    await poll(t, app);
    expect(c.gets.where((g) => g == '/api/health'), hasLength(2));
    await end();
  });
}
