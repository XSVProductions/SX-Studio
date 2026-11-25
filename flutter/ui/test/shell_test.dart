import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/shell.dart';
import 'package:sx_studio/theme.dart';

/// A pretend engine with a tab layout, and a count of show reads.
class _Engine {
  var sxOpen = false;
  var speedReads = 0;
  final settings = const SxSettings(tabHidden: ['apc'], tabNames: {'speed': 'Tempo'}).toJson();

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: MockClient(_answer));

  Future<http.Response> _answer(http.Request r) async {
    final Object answer = switch (r.url.path) {
      '/api/sx' => {
        'ok': true,
        'open': sxOpen,
        'q': {'items': <Object>[], 'reopen': true},
      },
      '/api/settings' => {'ok': true, 'settings': settings, 'ver': '2.0.0', 'phone': true},
      '/api/speed' => () {
        speedReads++;
        return const SpeedPreview(show: '/show', faders: [], buttons: []).toJson();
      }(),
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

  /// Takes the app down inside the test, so its status timer is gone before
  /// the test ends.
  Future<void> end(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  }

  testWidgets('the tab bar and Home follow the names and hidden tabs in Settings', (tester) async {
    final app = await pump(tester, _Engine());
    // Home: the renamed tile, and no tile for the hidden tab
    expect(find.text('Tempo'), findsOneWidget);
    expect(find.text('APC mini'), findsNothing);
    expect(find.text("Tonight's Rig"), findsOneWidget);

    await tester.tap(find.text('Rig & Control'));
    await tester.pumpAndSettle();
    expect(find.text('Tempo'), findsNWidgets(2));
    expect(find.text('APC mini'), findsNothing);
    expect(find.text("Tonight's Rig"), findsNWidgets(2));
    await end(tester, app);
  });

  testWidgets('a screen reads the show again when ShowXpress closes', (tester) async {
    final engine = _Engine()..sxOpen = true;
    final app = await pump(tester, engine, tab: 'speed');
    expect(engine.speedReads, 1);

    await app.refresh();
    await tester.pump();
    expect(engine.speedReads, 1, reason: 'nothing changed');

    engine.sxOpen = false;
    await app.refresh();
    await tester.pump();
    await tester.pump();
    expect(engine.speedReads, 2);
    await end(tester, app);
  });
}
