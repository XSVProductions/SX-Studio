import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/pre/pre_screen.dart';
import 'package:sx_studio/widgets/sx_widgets.dart';

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

/// What `/api/gdrive` answers, with the last sync at [last].
Map<String, Object> _drive({bool found = true, String last = ''}) => {
  'ok': true,
  'show': 'C:/Shows/Test',
  'here': true,
  'found': found,
  'target': 'G:/My Drive/AWAAZ/Lighting/Test',
  'last': last,
};

DriveInfo _info({bool found = true, String last = ''}) => DriveInfo.fromJson(_drive(found: found, last: last));

void main() {
  group('the Google Drive line', () {
    final now = DateTime(2026, 11, 25, 18, 30);
    test('says when it was backed up today', () {
      final l = driveLine(_info(last: '2026-11-25T14:05:00'), now: now)!;
      expect((l.level, l.title, l.fix), ('ok', 'Backed up to Google Drive today at 2:05 PM', null));
    });
    test('asks for a sync when the last one was another day', () {
      final l = driveLine(_info(last: '2026-11-23T09:00:00'), now: now)!;
      expect((l.level, l.title, l.fix?.key), ('warn', 'Last backed up to Google Drive Mon, Nov 23 9:00 AM', 'gsync'));
    });
    test('asks for a first sync', () {
      expect(driveLine(_info(), now: now)!.title, 'Show not backed up to Google Drive yet');
    });
    test('says when Google Drive is not on the laptop, with nothing to press', () {
      final l = driveLine(_info(found: false), now: now)!;
      expect((l.level, l.title, l.fix), ('info', 'Google Drive not found on this laptop', null));
    });
  });

  testWidgets('the Health Check goes third in the list and its button opens the tab', (t) async {
    final (app, end) = await pumpScreen(t, Canned({'/api/pre': _pre, '/api/health': _health, '/api/gdrive': _drive(found: false)}), PreScreen.new);
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

  testWidgets('when the Health Check and Google Drive fail the rest still shows', (t) async {
    final (_, end) = await pumpScreen(
      t,
      Canned({
        '/api/pre': _pre,
        '/api/health': {'ok': false, 'error': 'boom'},
        '/api/gdrive': {'ok': false, 'error': 'boom'},
      }),
      PreScreen.new,
    );
    expect(find.text('Rig Test saved today'), findsOneWidget);
    expect(find.textContaining('Health Check'), findsNothing);
    expect(find.textContaining(RegExp('backed up to Google Drive', caseSensitive: false)), findsNothing);
    expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Sync to Google Drive')).onPressed, isNull);
    expect(find.text('All good, ready for the show'), findsOneWidget);
    await end();
  });

  testWidgets('the Google Drive line comes last in Show, and Sync now copies the show and checks again', (t) async {
    final c = Canned({
      '/api/pre': _pre,
      '/api/health': _health,
      '/api/gdrive': [_drive(), _drive(last: DateTime.now().toIso8601String().substring(0, 19))],
      '/api/gdrive/sync': {'ok': true, 'out': 'Copied.'},
    });
    final (_, end) = await pumpScreen(t, c, PreScreen.new);
    final y = ['Rig Test saved today', 'Show not backed up to Google Drive yet', 'Controller found'].map((s) => t.getTopLeft(find.text(s)).dy).toList();
    expect(y, [...y]..sort());

    await t.tap(find.text('Sync now'));
    await t.pumpAndSettle();
    expect(c.posts.single.$1, '/api/gdrive/sync');
    expect(find.textContaining('Backed up to Google Drive today at'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    await end();
  });

  testWidgets('Sync now waits for ShowXpress to close, the bar button does not', (t) async {
    final c = Canned({
      '/api/sx': {'ok': true, 'open': true},
      '/api/pre': _pre,
      '/api/health': _health,
      '/api/gdrive': _drive(),
    });
    final (_, end) = await pumpScreen(t, c, PreScreen.new);
    expect(t.widget<MiniButton>(find.widgetWithText(MiniButton, 'Sync now')).onPressed, isNull);
    await t.tap(find.text('Sync to Google Drive'));
    await t.pumpAndSettle();
    expect(c.posts.single.$1, '/api/gdrive/sync');
    await end();
  });

  testWidgets('opening the tab again checks again', (t) async {
    final c = Canned({'/api/pre': _pre, '/api/health': _health, '/api/gdrive': _drive()});
    final (app, end) = await pumpScreen(t, c, PreScreen.new, tab: 'pre');
    expect(c.gets.where((g) => g == '/api/pre'), hasLength(1));
    app.go('home');
    await t.pumpAndSettle();
    expect(c.gets.where((g) => g == '/api/pre'), hasLength(1));
    app.go('pre');
    await t.pumpAndSettle();
    expect(c.gets.where((g) => g == '/api/pre'), hasLength(2));
    await end();
  });
}
