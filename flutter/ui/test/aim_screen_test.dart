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

Map<String, Object?> _preview({String mode = 'Floor', String warn = '', Map<String, bool>? install}) => {
  'ok': true,
  'show': 'Test Show',
  'lastW': 120,
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

/// The screen on a laptop-sized window, against a fake engine. Returns the
/// POSTs it makes, by path, and the app state to dispose at the end.
Future<(Map<String, Map<String, Object?>>, AppState)> _mount(WidgetTester tester, {String warn = '', Map<String, bool>? install}) async {
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
        'open': false,
        'q': {'items': <Object>[], 'reopen': true},
      };
      if (path == '/api/preview') answer = _preview(mode: req.url.queryParameters['mode'] == 'room' ? 'Room' : 'Floor', warn: warn, install: install);
      if (req.method == 'POST') {
        posts[path] = (jsonDecode(req.body) as Map).cast();
        answer = {'ok': true, 'out': _applyOut, 'error': ''};
      }
      return http.Response(jsonEncode(answer), 200);
    }),
  );
  final app = AppState(client);
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
    expect(find.text('·  CHANGED · STAR.gpj · 12 values changed'), findsOneWidget);
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
}
