import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/settings/config_card.dart';
import 'package:sx_studio/theme.dart';

/// A pretend engine for the card. Keeps every POST body by path.
class _Engine {
  final posts = <String, List<Object?>>{};
  var settingsReads = 0;
  Json exportAnswer = const ConfigExportResult(
    path: '/home/me/Downloads/SX Studio settings 2026-11-25.json',
    name: 'SX Studio settings 2026-11-25.json',
    folder: '/home/me/Downloads',
  ).toJson();
  Json importAnswer = {
    'ok': true,
    'done': ['the tabs and the SX Player pages', 'the speed faders (already the same)'],
    'warn': ["The Auto Show in the file couldn't be read, so it was kept as it was."],
    'settings': const SxSettings(tabNames: {'rt': 'Rig Check'}).toJson(),
    'backup': '/cfg/backups/settings before import 2026-11-25 120000',
  };

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: MockClient(_answer));

  Future<http.Response> _answer(http.Request r) async {
    if (r.method == 'POST') posts.putIfAbsent(r.url.path, () => []).add(jsonDecode(r.body));
    final Object answer = switch (r.url.path) {
      '/api/settings' => () {
        settingsReads++;
        return const SettingsInfo(settings: SxSettings(), ver: '2.0.0').toJson();
      }(),
      '/api/config/export' => exportAnswer,
      '/api/config/import' => importAnswer,
      _ => {'ok': true, 'out': '', 'error': ''},
    };
    return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json'});
  }
}

final _apps = <AppState>[];

Future<AppState> _pump(WidgetTester tester, _Engine engine, {Future<PickedFile?> Function()? pick, double width = 1200}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(engine.client(), tab: 'settings');
  _apps.add(app);
  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: ConfigCard(pick: pick ?? () async => null)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

/// A card test. The app state comes down at the end, so its poll timer
/// stops before the test checks for timers left running.
void _test(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
  await body(tester);
  await tester.pumpWidget(const SizedBox());
  _apps.removeLast().dispose();
});

Finder _rich(String text) => find.textContaining(text, findRichText: true);

PickedFile _file(Json d) => (name: 'SX Studio settings 2026-11-20.json', text: jsonEncode(d));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _test("export sends this computer's own choices the port knows, never the phone key", (tester) async {
    SharedPreferences.setMockInitialValues({
      'sxh_theme': 'light',
      'sxh_flip_12': '{"x":true,"y":false}',
      'sxh_phone_key': 'secret',
      'sxh_something_new': 'x',
      'other': 'y',
    });
    final engine = _Engine();
    await _pump(tester, engine);
    await tester.tap(find.text('Export settings'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/config/export'], [
      {
        'device': {'sxh_theme': 'light', 'sxh_flip_12': '{"x":true,"y":false}'},
      },
    ]);
    expect(_rich('Saved SX Studio settings 2026-11-25.json in /home/me/Downloads'), findsOneWidget);
    await tester.tap(find.text('Show the file'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/open'], [
      {'what': 'export'},
    ]);
  });

  _test('an export that fails says why', (tester) async {
    final engine = _Engine()..exportAnswer = {'ok': false, 'error': "The settings couldn't be saved: Permission denied"};
    await _pump(tester, engine);
    await tester.tap(find.text('Export settings'));
    await tester.pumpAndSettle();
    expect(find.text("The settings couldn't be saved: Permission denied"), findsOneWidget);
  });

  _test('a file that is not a settings file, or has nothing in it, is not sent', (tester) async {
    final engine = _Engine();
    var picked = (name: 'notes.json', text: 'not json');
    await _pump(tester, engine, pick: () async => picked);
    await tester.tap(find.text('Import settings'));
    await tester.pumpAndSettle();
    expect(find.text("That file isn't an SX Studio settings file."), findsOneWidget);

    picked = _file({'app': 'SX Studio', 'kind': 'settings', 'format': 1});
    await tester.tap(find.text('Import settings'));
    await tester.pumpAndSettle();
    expect(find.text('That file has no settings in it.'), findsOneWidget);
    expect(engine.posts['/api/config/import'], isNull);
  });

  _test('import asks first, then takes up the tabs, the theme and the other choices at once', (tester) async {
    final engine = _Engine();
    final d = {
      'app': 'SX Studio',
      'kind': 'settings',
      'format': 1,
      'version': '1.9.15',
      'saved': '2026-11-20T10:00:00',
      'settings': {'tabOrder': <String>[]},
      'speedFaders': {'buttons': <Object>[]},
      'device': {'sxh_theme': 'light', 'sxh_lvspd': '2', 'sxh_phone_key': 'no', 'sxh_unknown': 'x'},
    };
    final app = await _pump(tester, engine, pick: () async => _file(d));
    final reads = engine.settingsReads;
    final edits = app.sxCloses;

    await tester.tap(find.text('Import settings'));
    await tester.pumpAndSettle();
    expect(find.text('Import these settings?'), findsOneWidget);
    expect(
      find.text(
        "SX Studio settings 2026-11-20.json (saved 2026-11-20 by version 1.9.15) replaces the tabs and the SX Player pages, the speed faders and this computer's own choices. "
        'What you have now is backed up first.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/config/import'], isNull);

    await tester.tap(find.text('Import settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(engine.posts['/api/config/import'], [
      {'data': d},
    ]);
    expect(
      _rich(
        "Imported the tabs and the SX Player pages, the speed faders (already the same) and this computer's own choices. "
        "The Auto Show in the file couldn't be read, so it was kept as it was.",
      ),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sxh_theme'), 'light');
    expect(prefs.getString('sxh_lvspd'), '2');
    expect(prefs.containsKey('sxh_phone_key'), isFalse);
    expect(prefs.containsKey('sxh_unknown'), isFalse);
    expect(app.themeMode, ThemeMode.light);
    expect(engine.settingsReads, greaterThan(reads));
    expect(app.sxCloses, edits + 1);
  });

  _test('an import the engine refuses says why', (tester) async {
    final engine = _Engine()..importAnswer = {'ok': false, 'error': 'That file is from a newer SX Studio - update SX Studio first. Nothing was changed.'};
    await _pump(
      tester,
      engine,
      pick: () async => _file({
        'app': 'SX Studio',
        'kind': 'settings',
        'format': 2,
        'phone': {'on': true},
      }),
    );
    await tester.tap(find.text('Import settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(find.text('That file is from a newer SX Studio - update SX Studio first. Nothing was changed.'), findsOneWidget);
  });

  _test('fits a phone-sized window', (tester) async {
    final engine = _Engine();
    await _pump(tester, engine, width: 380);
    await tester.tap(find.text('Export settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Show the file'), findsOneWidget);
  });
}
