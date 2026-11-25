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

/// The engine side of a test. [gets] answers GETs by path, and `/api/sx`
/// answers with [sxOpen] and [queueRan]. Any other path is a 404, which the
/// screens show as an error (the remote row).
class FakeEngine {
  FakeEngine(this.gets);

  final Map<String, Json> gets;

  /// ShowXpress open, for the status poll.
  var sxOpen = false;

  /// When the queue last saved into the show, for the status poll.
  String? queueRan;

  /// How often each path was read.
  final reads = <String, int>{};

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
      reads.update(r.url.path, (n) => n + 1, ifAbsent: () => 1);
      if (r.url.path == '/api/sx') {
        return _json({
          'ok': true,
          'open': sxOpen,
          'q': {
            'items': <Object>[],
            'reopen': true,
            if (queueRan != null) 'done': {'at': queueRan},
          },
        });
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

/// Polls the status now, as the app's timer would, and lets screens react.
Future<void> poll(WidgetTester tester, AppState app) async {
  await app.refresh();
  await tester.pumpAndSettle();
}

/// The old poll's reload rules for a rig tab that reads [path]: ShowXpress
/// closing reads the show again unless [edit] left unsaved edits, and the
/// queue saving into the show reads it again regardless. Starts with
/// ShowXpress open.
Future<void> checkReloads(WidgetTester tester, FakeEngine e, AppState app, String tab, String path, Future<void> Function() edit) async {
  final n = e.reads[path]!;
  e.sxOpen = false;
  await poll(tester, app);
  expect(e.reads[path], n + 1, reason: 'closed with nothing unsaved');

  e.sxOpen = true;
  await poll(tester, app);
  await edit();
  expect(app.dirtyTabs, {tab});
  e.sxOpen = false;
  await poll(tester, app);
  expect(e.reads[path], n + 1, reason: 'closed with unsaved edits');
  expect(app.dirtyTabs, {tab});

  e.queueRan = '2026-11-25T01:00:00';
  await poll(tester, app);
  expect(e.reads[path], n + 2, reason: 'the queue saved into the show');
  expect(app.dirtyTabs, isEmpty);
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
