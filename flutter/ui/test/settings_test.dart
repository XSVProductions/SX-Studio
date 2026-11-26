import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/pair/pair_screen.dart';
import 'package:sx_studio/screens/settings/settings_screen.dart';
import 'package:sx_studio/screens/settings/settings_model.dart';
import 'package:sx_studio/tabs.dart';
import 'package:sx_studio/theme.dart';

/// A pretend engine: answers each route, and keeps every POST body.
class _Engine {
  _Engine({this.phone = false});

  final bool phone;
  var settings = const SxSettings().toJson();
  var pin = '';
  final posts = <String, List<Json>>{};

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: MockClient(_answer));

  Future<http.Response> _answer(http.Request r) async {
    Json body = r.method == 'POST' && r.body.isNotEmpty ? (jsonDecode(r.body) as Map).cast<String, Object?>() : {};
    if (r.method == 'POST') posts.putIfAbsent(r.url.path, () => []).add(body);
    Json phoneInfo() => PhoneInfo(
      on: true,
      port: 47322,
      running: true,
      local: 'laptop.local',
      addrs: const [LanAddress(ip: '192.168.1.20', name: 'Wi-Fi', wifi: true)],
      pin: pin,
      pinLeft: pin.isEmpty ? 0 : 600,
    ).toJson();
    final Object answer = switch (r.url.path) {
      '/api/sx' => {
        'ok': true,
        'open': false,
        'q': {'items': <Object>[], 'reopen': true},
      },
      '/api/settings' => {'ok': true, 'settings': settings, 'ver': '2.0.0', 'phone': phone},
      '/api/settings/set' => () {
        settings = {...settings, ...body};
        return {'ok': true, 'settings': settings};
      }(),
      '/api/update' => const UpdateInfo(ok: true, current: '2.0.0', latest: '2.1.0', newer: true, asset: 'https://github.com/x/setup.exe').toJson(),
      '/api/update/install' => {'ok': false, 'error': 'Download failed: no network', 'out': ''},
      '/api/gdrive' => const DriveInfo(show: '/shows/Awaaz Lightshow', here: true, found: false, target: '').toJson(),
      '/api/phone' => phoneInfo(),
      '/api/phone/pin' => () {
        pin = '482913';
        return phoneInfo();
      }(),
      _ => {'ok': false, 'error': 'not in this test'},
    };
    return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
  }
}

Future<AppState> _pump(WidgetTester tester, _Engine engine, {double width = 1200}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(engine.client(), tab: 'settings');
  _apps.add(app);
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: const Scaffold(body: SettingsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

/// A Settings test. The screen and the app state come down at the end, so
/// their poll timers stop before the test checks for timers left running.
void _test(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  _apps.removeLast().dispose();
});

final _apps = <AppState>[];

void main() {
  _test('the laptop sees every section, a phone only the shared ones', (tester) async {
    await _pump(tester, _Engine());
    for (final t in ['Tabs', 'Google Drive', 'Phone & iPad', 'ShowXpress', 'Updates']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });

  _test('on a phone the laptop-only sections are gone', (tester) async {
    await _pump(tester, _Engine(phone: true), width: 380);
    expect(find.text('Tabs'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Phone & iPad'), findsNothing);
    expect(find.text('Updates'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _test('an update asks first, then says why it failed', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    await tester.ensureVisible(find.text('Check now'));
    await tester.pump();
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update to 2.1.0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SX Studio closes and opens again by itself'), findsOneWidget);
    expect(engine.posts['/api/update/install'], isNull);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/update/install'], hasLength(1));
    expect(find.text('Download failed: no network'), findsOneWidget);
    expect(find.text('Downloading the update...'), findsNothing);
  });

  _test('unticking a tab hides it everywhere', (tester) async {
    final engine = _Engine();
    final app = await _pump(tester, engine);
    final rig = tabs.firstWhere((t) => t.id == 'rig');
    await tester.tap(find.byType(Checkbox).at(tabs.indexOf(rig)));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/settings/set']!.last['tabHidden'], ['rig']);
    expect(SettingsModel.of(app).visible().map((t) => t.id), isNot(contains('rig')));
  });

  _test('a tab moves inside its menu only', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    // the first tab can't go up, and the last of a menu can't go down
    await tester.tap(find.byIcon(Icons.arrow_drop_up).first);
    await tester.pumpAndSettle();
    expect(engine.posts['/api/settings/set'], isNull);
    await tester.tap(find.byIcon(Icons.arrow_drop_down).first);
    await tester.pumpAndSettle();
    final order = (engine.posts['/api/settings/set']!.last['tabOrder'] as List).cast<String>();
    expect(order.take(2), ['aim', 'rt']);
  });

  _test('a new name is saved, and an empty one gives the tab its own name back', (tester) async {
    final engine = _Engine();
    final app = await _pump(tester, engine);
    await tester.enterText(find.widgetWithText(TextField, 'Rig Test'), 'Hang check');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(engine.posts['/api/settings/set']!.last['tabNames'], {'rt': 'Hang check'});
    expect(SettingsModel.of(app).nameOf(tabs.first), 'Hang check');

    await tester.enterText(find.widgetWithText(TextField, 'Hang check'), '');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(engine.posts['/api/settings/set']!.last['tabNames'], <String, String>{});
  });

  _test('a name being typed survives its row scrolling away and back', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextField, 'Rig Test').first);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Rig Test'), 'Hang check');
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Updates'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Hang check'), findsNothing, reason: 'the row is off screen, so it is gone');
    await tester.scrollUntilVisible(find.widgetWithText(TextField, 'Hang check'), -300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Hang check'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(engine.posts['/api/settings/set']!.last['tabNames'], {'rt': 'Hang check'});
  });

  _test('Pair a phone shows the code', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    expect(find.textContaining('http://laptop.local:47322', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Pair a phone'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/phone/pin'], hasLength(1));
    expect(find.text('482913'), findsOneWidget);
  });

  _test('the settings fit a phone screen', (tester) async {
    await _pump(tester, _Engine(), width: 380);
    expect(tester.takeException(), isNull);
  });

  group('pairing screen', () {
    Future<List<String>> pumpPair(WidgetTester tester, Future<http.Response> Function(http.Request) answer) async {
      final paired = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: sxTheme(),
          home: PairScreen(
            client: SxClient(Uri.parse('http://laptop:47322'), token: '', client: MockClient(answer)),
            onPaired: paired.add,
          ),
        ),
      );
      return paired;
    }

    testWidgets('with phone access turned off the pair screen says so, until a code is tried', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: sxTheme(),
          home: PairScreen(
            client: SxClient(
              Uri.parse('http://laptop:47322'),
              token: '',
              client: MockClient((r) async => http.Response(jsonEncode({'ok': false, 'error': 'That code is not right.'}), 200)),
            ),
            onPaired: (_) {},
            off: true,
          ),
        ),
      );
      const off = 'Phone access is turned off on the laptop (Settings, Phone & iPad).';
      expect(find.text(off), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(find.text(off), findsNothing);
      expect(find.text('That code is not right.'), findsOneWidget);
    });

    testWidgets('six digits pair the phone', (tester) async {
      String? sent;
      final paired = await pumpPair(tester, (r) async {
        sent = (jsonDecode(r.body) as Map)['pin'] as String;
        return http.Response(jsonEncode({'ok': true, 'key': 'the-key'}), 200);
      });
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      expect(sent, '123456');
      expect(paired, ['the-key']);
    });

    testWidgets("a wrong code says why, and nothing is paired", (tester) async {
      final paired = await pumpPair(
        tester,
        (r) async => http.Response(jsonEncode({'ok': false, 'error': 'That code is not right. Check the 6 digits on the laptop.'}), 200),
      );
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pumpAndSettle();
      expect(find.text('That code is not right. Check the 6 digits on the laptop.'), findsOneWidget);
      expect(paired, isEmpty);
    });
  });
}
