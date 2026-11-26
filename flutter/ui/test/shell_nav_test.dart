import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/shell.dart';
import 'package:sx_studio/theme.dart';
import 'package:sx_studio/widgets/sx_widgets.dart';

/// A pretend engine for the header, the tab bar and the queue bar.
class _Engine {
  var sxOpen = false;
  var down = false;
  var already = false;
  var queued = <Object>[];
  List<String> hidden = const [];
  final posts = <(String, Map<String, Object?>)>[];

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: MockClient(_answer));

  List<Map<String, Object?>> postsTo(String path) => [
    for (final p in posts)
      if (p.$1 == path) p.$2,
  ];

  Future<http.Response> _answer(http.Request r) async {
    if (down) throw http.ClientException('refused');
    if (r.method == 'POST') posts.add((r.url.path, r.body.isEmpty ? {} : (jsonDecode(r.body) as Map).cast<String, Object?>()));
    final Object answer = switch (r.url.path) {
      '/api/sx' => {
        'ok': true,
        'open': sxOpen,
        'q': {'items': queued, 'reopen': true},
      },
      '/api/settings' => {'ok': true, 'settings': SxSettings(tabHidden: hidden).toJson(), 'ver': '2.0.0', 'phone': false},
      '/api/sx/launch' => () {
        final was = already;
        already = false;
        return {'ok': true, 'out': '', if (was) 'already': true};
      }(),
      '/api/sx/close' => {'ok': true, 'out': ''},
      _ => {'ok': false, 'error': 'not in this test'},
    };
    return http.Response(jsonEncode(answer), 200);
  }
}

void main() {
  Future<AppState> pump(WidgetTester tester, _Engine engine, {String tab = 'home'}) async {
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(engine.client(), tab: tab);
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(theme: sxTheme(), home: const Shell()),
      ),
    );
    await tester.pump();
    await tester.pump();
    return app;
  }

  Future<void> end(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  }

  Future<void> press(WidgetTester tester, String text) async {
    await tester.tap(find.widgetWithText(FilledButton, text));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an unknown tab id opens Home, as the old setTab did', (tester) async {
    final app = await pump(tester, _Engine(), tab: 'nope');
    expect(app.tab, 'home');
    app.go('_todo');
    expect(app.tab, 'home');
    await end(tester, app);
  });

  testWidgets('a group with one tab left is a plain button that opens it', (tester) async {
    final app = await pump(tester, _Engine()..hidden = ['auto']);
    await tester.tap(find.widgetWithText(SegButton, 'SX Player'));
    await tester.pump();
    expect(app.tab, 'lab');
    expect(find.text('Auto Show'), findsNothing);
    await end(tester, app);
  });

  testWidgets('the tab menu has no "(unsaved)" labels', (tester) async {
    final app = await pump(tester, _Engine());
    app.setDirty('rig', true);
    await tester.tap(find.text('Rig & Control'));
    await tester.pumpAndSettle();
    expect(find.textContaining('unsaved'), findsNothing);
    await end(tester, app);
  });

  testWidgets('on the laptop, losing the engine shows the closed screen', (tester) async {
    final engine = _Engine();
    final app = await pump(tester, engine);
    engine.down = true;
    await app.refresh();
    await tester.pump();
    expect(find.text('SX Studio has closed'), findsOneWidget);
    expect(find.text('Open it again from its icon.'), findsOneWidget);
    await end(tester, app);
  });

  testWidgets('Close ShowXpress asks first, and later offers Force close', (tester) async {
    final engine = _Engine()..sxOpen = true;
    final app = await pump(tester, engine);
    await tester.tap(find.text('Close ShowXpress'));
    await tester.pump();
    expect(find.text('Close ShowXpress?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.postsTo('/api/sx/close'), isEmpty);

    await tester.tap(find.text('Close ShowXpress'));
    await tester.pump();
    await press(tester, 'Close ShowXpress');
    expect(engine.postsTo('/api/sx/close'), [
      {'force': false, 'live': false},
    ]);

    // still open more than 8 s later: the second press offers Force close
    app.sxCloseAsked = DateTime.now().subtract(const Duration(seconds: 9));
    await tester.tap(find.text('Close ShowXpress'));
    await tester.pump();
    expect(find.text("ShowXpress didn't close"), findsOneWidget);
    await press(tester, 'Force close');
    expect(engine.postsTo('/api/sx/close').last, {'force': true, 'live': false});
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump();
    await end(tester, app);
  });

  testWidgets('a ShowXpress stuck while closing offers Force close and open', (tester) async {
    final engine = _Engine()..already = true;
    final app = await pump(tester, engine);
    await tester.tap(find.text('Launch ShowXpress'));
    await tester.pump();
    await tester.pump();
    expect(find.text('ShowXpress is still running'), findsOneWidget);
    await press(tester, 'Force close and open');
    expect(engine.postsTo('/api/sx/close').single, {'force': true, 'live': false});
    expect(engine.postsTo('/api/sx/launch'), hasLength(1), reason: 'waits for it to let go first');
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump();
    expect(engine.postsTo('/api/sx/launch'), hasLength(2));
    expect(find.text('Starting ShowXpress.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Starting ShowXpress.'), findsNothing);
    await end(tester, app);
  });

  testWidgets("the queue bar's Close ShowXpress now asks first too", (tester) async {
    final engine = _Engine()
      ..sxOpen = true
      ..queued = [
        {'key': 'speed', 'label': 'Speed faders'},
      ];
    final app = await pump(tester, engine);
    await tester.tap(find.text('Close ShowXpress now'));
    await tester.pump();
    expect(find.text('Close ShowXpress?'), findsOneWidget);
    await press(tester, 'Close ShowXpress');
    expect(engine.postsTo('/api/sx/close'), hasLength(1));
    await end(tester, app);
  });

  testWidgets('a status poll that brings nothing new rebuilds nothing, and still ticks', (tester) async {
    final engine = _Engine();
    final app = await pump(tester, engine);
    var changes = 0, ticks = 0;
    app.addListener(() => changes++);
    app.polled.addListener(() => ticks++);
    await tester.runAsync(app.refresh);
    expect((changes, ticks), (0, 1));
    engine.sxOpen = true;
    await tester.runAsync(app.refresh);
    expect((changes, ticks), (1, 2));
    await end(tester, app);
  });

  testWidgets('a hidden tab is left alone when the state changes, and catches up when it is shown again', (tester) async {
    const open = 'ShowXpress is open. A fix waits until it closes.';
    final engine = _Engine();
    final app = await pump(tester, engine, tab: 'health');
    expect(find.text(open), findsNothing);
    app.go('home');
    await tester.pump();
    engine.sxOpen = true;
    await tester.runAsync(app.refresh);
    await tester.pump();
    expect(app.sxOpen, isTrue);
    expect(find.text(open, skipOffstage: false), findsNothing);
    app.go('health');
    await tester.pump();
    expect(find.text(open), findsOneWidget);
    await end(tester, app);
  });
}
