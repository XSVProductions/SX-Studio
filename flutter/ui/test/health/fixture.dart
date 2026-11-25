import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/theme.dart';

/// Canned engine answers by path for the Health, Pre-show and APC screen
/// tests. Records every POST with its body. A path missing from [answers]
/// answers with [sxStatus]. Records every GET path in [gets].
class Canned {
  Canned(this.answers);

  /// Answer per path. A list is used up one entry per call, the last one repeats.
  final Map<String, Object> answers;
  final posts = <(String, Json)>[];
  final gets = <String>[];

  Future<http.Response> answer(http.Request r) async {
    final path = r.url.path;
    if (r.method == 'POST') posts.add((path, (jsonDecode(r.body) as Map).cast<String, Object?>()));
    if (r.method == 'GET') gets.add(path);
    final a = answers[path];
    final Object j = switch (a) {
      final List<Object> l when l.length > 1 => l.removeAt(0),
      final List<Object> l => l.single,
      final Object o => o,
      null => sxStatus(),
    };
    return http.Response(jsonEncode(j), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

/// What `/api/sx` answers: ShowXpress [open] or not, and the time the queue
/// last ran ([done]), if it has.
Map<String, Object?> sxStatus({bool open = false, String? done}) => {
  'ok': true,
  'open': open,
  'q': {
    'items': <Object>[],
    'reopen': true,
    'done': done == null ? null : {'at': done},
  },
};

/// Reads the status again, as the 2 s poll does, and lets the screen react.
Future<void> poll(WidgetTester t, AppState app) async {
  await app.refresh();
  await t.pumpAndSettle();
}

/// Pumps [screen] at [width] px against [c], with [tab] on show. Call the returned function last.
Future<(AppState, Future<void> Function())> pumpScreen(
  WidgetTester t,
  Canned c,
  Widget Function(BuildContext) screen, {
  double width = 1200,
  String tab = 'home',
}) async {
  t.view.physicalSize = Size(width, 2400);
  t.view.devicePixelRatio = 1;
  final app = AppState(
    SxClient(Uri.parse('http://engine'), token: 'dev', client: MockClient(c.answer)),
    tab: tab,
  );
  await t.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(body: Builder(builder: screen)),
      ),
    ),
  );
  await t.pumpAndSettle();
  return (
    app,
    () async {
      await t.pumpWidget(const SizedBox());
      app.dispose();
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    },
  );
}

/// Presses [label] in the dialog on top.
Future<void> pressInDialog(WidgetTester t, String label) async {
  await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)));
  await t.pumpAndSettle();
}
