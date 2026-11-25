import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/settings/phone_card.dart';
import 'package:sx_studio/theme.dart';

/// A pretend engine for the Phone & iPad card. Keeps every POST body.
class _Engine {
  var pin = '';
  var mac = false;
  final posts = <String, List<Object?>>{};

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: MockClient(_answer));

  Future<http.Response> _answer(http.Request r) async {
    if (r.method == 'POST') posts.putIfAbsent(r.url.path, () => []).add(jsonDecode(r.body));
    if (r.url.path == '/api/phone/pin') pin = '482913';
    if (r.url.path == '/api/phone/unpair') pin = '';
    final info = PhoneInfo(
      on: true,
      port: 47322,
      running: true,
      local: 'laptop.local',
      mac: mac,
      addrs: const [LanAddress(ip: '192.168.1.20', name: 'Wi-Fi', wifi: true)],
      pin: pin,
      pinLeft: pin.isEmpty ? 0 : 541,
      lastSeen: '2026-11-25T20:15:00',
      lastIp: '192.168.1.31',
    );
    return http.Response(jsonEncode(info.toJson()), 200, headers: {'content-type': 'application/json'});
  }
}

Future<void> _pump(WidgetTester tester, _Engine engine, {double width = 1200}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(engine.client(), tab: 'settings');
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: const Scaffold(body: SingleChildScrollView(child: PhoneCard())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  _apps.add(app);
}

/// A card test. The card and the app state come down at the end, so their
/// poll timers stop before the test checks for timers left running.
void _test(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  _apps.removeLast().dispose();
});

final _apps = <AppState>[];

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  _test('a code is good for any number of phones, with the minutes left', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    expect(find.text('Each phone or iPad is paired once, with a 6-digit code.'), findsOneWidget);
    await tester.tap(find.text('Pair a phone'));
    await tester.pumpAndSettle();
    expect(find.text('482913'), findsOneWidget);
    expect(find.text('Type this on the phone. Good for 10 more min.'), findsOneWidget);
    expect(_rich('One phone per code'), findsNothing);
  });

  _test('Unpair all phones is always there, asks first, and sends no id', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    expect(find.text('Unpair'), findsNothing, reason: 'no list of phones');
    await tester.tap(find.text('Unpair all phones'));
    await tester.pumpAndSettle();
    expect(find.text('Every paired phone and iPad has to be paired again with a new code.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/phone/unpair'], isNull);

    await tester.tap(find.text('Unpair all phones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpair'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/phone/unpair'], [<String, Object?>{}]);
  });

  _test('the last phone and the firewall note, as the old card had them', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine);
    expect(_rich('Last phone: 192.168.1.31,'), findsOneWidget);
    expect(_rich('The first time, Windows may ask whether SX Studio may use the network. Tick Private networks and press Allow.'), findsOneWidget);
  });

  _test('on a Mac, the macOS note', (tester) async {
    await _pump(tester, _Engine()..mac = true);
    expect(_rich('If macOS asks whether SX Studio may accept incoming connections, press Allow.'), findsOneWidget);
  });

  _test('fits a phone screen', (tester) async {
    await _pump(tester, _Engine()..pin = '482913', width: 380);
    expect(tester.takeException(), isNull);
  });
}
