// A fake engine for the rig, skip and rt screen tests: canned GET answers,
// and every POST body kept so a test can check what Save sent.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/theme.dart';

/// The engine side of a test. [gets] answers GETs by path. Any other path is
/// a 404, which the screens show as an error (the status poll, the remote).
class FakeEngine {
  FakeEngine(this.gets);

  final Map<String, Json> gets;

  /// POSTs in the order they came, with their decoded bodies.
  final posts = <({String path, Json body})>[];

  late final client = SxClient(
    Uri.parse('http://engine'),
    token: 't',
    client: MockClient((r) async {
      if (r.method == 'POST') {
        posts.add((path: r.url.path, body: (jsonDecode(r.body) as Map).cast<String, Object?>()));
        return _json({'ok': true, 'out': '  saved', 'error': ''});
      }
      final j = gets[r.url.path];
      return j == null ? _json({'ok': false, 'error': 'Not found'}, 404) : _json(j);
    }),
  );

  static http.Response _json(Json j, [int code = 200]) => http.Response(jsonEncode(j), code, headers: {'content-type': 'application/json'});
}

/// Shows [screen] on a laptop-sized surface as the tab [tab], and returns the
/// app state so a test can look at the dirty tabs. End with [finish].
Future<AppState> pumpScreen(WidgetTester tester, FakeEngine e, String tab, Widget Function(BuildContext) screen) async {
  tester.view.physicalSize = const Size(1300, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(e.client, tab: tab);
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(body: Builder(builder: screen)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

/// Takes the screen down and stops the app's status poll.
Future<void> finish(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(const SizedBox());
  app.dispose();
}

/// Taps and lets the screen rebuild.
Future<void> tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The bar button with [text], for checking whether it is enabled.
ButtonStyleButton barButton<T extends ButtonStyleButton>(WidgetTester tester, String text) => tester.widget<T>(find.widgetWithText(T, text));
