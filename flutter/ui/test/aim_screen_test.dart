import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/aim/aim_screen.dart';
import 'package:sx_studio/theme.dart';

Map<String, Object?> _tile(String label, {String warn = '', bool is140 = true}) => {
  'label': label,
  'is140': is140,
  'op': 300,
  'ot': -100,
  'sized': true,
  'copyFrom': '',
  'kp': 110,
  'kt': 95,
  'zp': 2,
  'zt': -1,
  'warn': warn,
};

Map<String, Object?> _preview({String mode = 'Floor', String warn = '', Map<String, bool>? install, int lastW = 120}) => {
  'ok': true,
  'show': 'Test Show',
  'lastW': lastW,
  'lastD': 90,
  'sceneExists': true,
  'heads': [_tile('140 #1'), _tile('140 #2', warn: warn), _tile('251 #1', is140: false)],
  'mode': mode,
  'aimTitle': mode == 'Room' ? 'ROOM AIM (ADJUST)' : 'DF AIM (ADJUST)',
  'checkTitle': 'DF CHECK',
  'install': install,
  'targets': ['AROUND ROOM', 'ROOM CHECK'],
};

const _applyOut = '  CHANGED  STAR.gpj  12 values changed\n  -> 9 movement scenes checked\n';

/// What the fake engine reports, changed by a test between polls.
class _Show {
  var sxOpen = false;
  var queueDone = '';
  var lastW = 120;
  var reads = 0;
}

/// The screen on a laptop-sized window, against a fake engine. Returns the
/// POSTs it makes, by path, and the app state to dispose at the end.
///
/// With [sxOpen] the fake ShowXpress is open with its remote on, and every
/// press is added to [presses].
Future<(Map<String, Map<String, Object?>>, AppState)> _mount(
  WidgetTester tester, {
  String warn = '',
  Map<String, bool>? install,
  bool sxOpen = false,
  List<List<Object?>>? presses,
  _Show? show,
}) async {
  final sh = show ?? (_Show()..sxOpen = sxOpen);
  SharedPreferences.setMockInitialValues({});
  tester.view
    ..physicalSize = const Size(1300, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final posts = <String, Map<String, Object?>>{};
  final client = SxClient(
    Uri.parse('http://laptop'),
    token: 't',
    client: MockClient((req) async {
      final path = req.url.path;
      Object answer = {
        'ok': true,
        'open': sh.sxOpen,
        'q': {
          'items': <Object>[],
          'reopen': true,
          if (sh.queueDone.isNotEmpty) 'done': {'at': sh.queueDone},
        },
      };
      const titles = ['DF AIM (ADJUST)', 'DF CHECK 140', 'DF CHECK 251', 'ROOM AIM (ADJUST)', 'ROOM CHECK'];
      Map<String, Object?> remote(List<Object?> on) => {
        'ok': true,
        'ready': true,
        'open': true,
        'connected': true,
        'titles': titles,
        'pressed': [
          for (final t in on) {'title': t, 'page': 'SETUP'},
        ],
        'pressedNow': on,
      };
      if (path == '/api/remote') return http.Response(jsonEncode(remote(const [])), 200);
      if (path == '/api/remote/press') {
        final on = ((jsonDecode(req.body) as Map)['titles'] as List).cast<Object?>();
        presses?.add(on);
        return http.Response(jsonEncode(remote(on)), 200);
      }
      if (path == '/api/preview') {
        sh.reads++;
        answer = _preview(mode: req.url.queryParameters['mode'] == 'room' ? 'Room' : 'Floor', warn: warn, install: install, lastW: sh.lastW);
      }
      if (req.method == 'POST') {
        posts[path] = (jsonDecode(req.body) as Map).cast();
        answer = {'ok': true, 'out': _applyOut, 'error': ''};
      }
      return http.Response(jsonEncode(answer), 200);
    }),
  );
  final app = AppState(client, tab: 'aim');
  // the first status poll lands before the tab shows, as in the app
  await tester.pump();
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(body: Builder(builder: AimScreen.new)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (posts, app);
}

void main() {
  testWidgets('shows the heads and applies at the size last used on this show', (tester) async {
    final (posts, app) = await _mount(tester);
    expect(find.text('140 #2'), findsOneWidget);
    expect(find.text('251SR'), findsOneWidget);
    expect(find.widgetWithText(TextField, '120'), findsOneWidget);
    expect(find.widgetWithText(TextField, '90'), findsOneWidget);

    await tester.tap(find.text('Apply to show'));
    await tester.pumpAndSettle();
    expect(posts['/api/apply'], {'w': 120, 'd': 90, 'force': false, 'mode': 'floor'});
    expect(find.text('Applied to the show'), findsOneWidget);
    expect(find.text('CHANGED · STAR.gpj · 12 values changed'), findsOneWidget);
    expect(find.textContaining('9 movement scenes checked'), findsOneWidget);
    app.dispose();
  });

  testWidgets('a head that looks wrong asks first, then applies with force', (tester) async {
    final (posts, app) = await _mount(tester, warn: 'corner very close/far - size limited, check this head');
    expect(find.textContaining('1 look wrong'), findsOneWidget);
    await tester.tap(find.text('Apply to show'));
    await tester.pumpAndSettle();
    expect(find.text('1 head(s) look wrong'), findsOneWidget);
    expect(posts, isEmpty);
    await tester.tap(find.text('Apply anyway'));
    await tester.pumpAndSettle();
    expect(posts['/api/apply']!['force'], true);
    app.dispose();
  });

  testWidgets('Room offers to add its buttons when the SETUP page lacks them', (tester) async {
    final (posts, app) = await _mount(tester, install: {'aim': true, 'check': false});
    expect(find.text('Add them to the SETUP page'), findsNothing, reason: 'only in Room');
    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();
    expect(find.text('Height'), findsOneWidget);
    await tester.ensureVisible(find.text('Add them to the SETUP page'));
    await tester.tap(find.text('Add them to the SETUP page'));
    await tester.pumpAndSettle();
    expect(posts.keys, contains('/api/aim/install'));
    app.dispose();
  });

  testWidgets('with ShowXpress open, the remote row turns on the ADJUST scene of the mode on show', (tester) async {
    final presses = <List<Object?>>[];
    final (_, app) = await _mount(tester, sxOpen: true, presses: presses);
    expect(presses, [
      ['DF AIM (ADJUST)'],
    ]);
    expect(find.textContaining('DF AIM (ADJUST) is on in ShowXpress.', findRichText: true), findsOneWidget);
    expect(find.text('DF CHECK 140 + 251'), findsOneWidget);

    await tester.tap(find.text('Room'));
    await tester.pumpAndSettle();
    expect(presses.last, ['ROOM AIM (ADJUST)']);
    await tester.tap(find.text('ROOM CHECK').first);
    await tester.pumpAndSettle();
    expect(presses.last, ['ROOM CHECK']);
    app.dispose();
  });

  testWidgets('a ShowXpress close reads the show and keeps the typed size, a queue run takes the size from the show again', (tester) async {
    final show = _Show()..sxOpen = true;
    final (_, app) = await _mount(tester, show: show);
    final reads = show.reads;
    await tester.enterText(find.widgetWithText(TextField, '120'), '200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '200'), findsOneWidget);

    show
      ..sxOpen = false
      ..lastW = 150;
    await app.refresh();
    await tester.pumpAndSettle();
    expect(show.reads, reads + 1);
    expect(find.widgetWithText(TextField, '200'), findsOneWidget, reason: 'the old `load()` keeps the sizes once taken');

    show.queueDone = '2026-11-25T01:00:00';
    await app.refresh();
    await tester.pumpAndSettle();
    expect(show.reads, reads + 2);
    expect(find.widgetWithText(TextField, '150'), findsOneWidget, reason: '`reloadAll` clears `LD`');
    app.dispose();
  });
}
