import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/color/color_screen.dart';
import 'package:sx_studio/screens/color/color_wheel.dart';
import 'package:sx_studio/theme.dart';

const _preview = {
  'ok': true,
  'show': '/show',
  'hex': 'f4a6b8',
  'name': 'Blush',
  'saved': '2026-11-23T07:11:29',
  'wheel140': [
    {'name': 'White', 'value': 1, 'hex': 'ffffff'},
    {'name': 'Red', 'value': 5, 'hex': 'ff0000'},
  ],
  'wheel251': [
    {'name': 'Red', 'value': 5, 'hex': 'ff0000'},
    {'name': 'CTO (warm)', 'value': 26, 'hex': 'ffc27a'},
  ],
  'washes': ['UPLIGHT'],
  'buttons': [
    {'page': 'MOVER COLORS', 'scene': 'TONIGHTS COLOR MOVERS', 'there': true},
    {'page': 'UPLIGHTS', 'scene': 'TONIGHTS COLOR UPLIGHT', 'there': false},
  ],
  'washFix': [],
};

void main() {
  testWidgets('picking a quick color shows the wheel slots, then saves it with its name', (tester) async {
    final sent = <Object?>[];
    final client = SxClient(
      Uri.parse('http://engine'),
      token: 't',
      client: MockClient((req) async {
        if (req.url.path == '/api/color') return http.Response(jsonEncode(_preview), 200);
        if (req.url.path == '/api/color/apply') {
          sent.add(jsonDecode(req.body));
          return http.Response(jsonEncode({'ok': true, 'out': '', 'error': ''}), 200);
        }
        return http.Response(jsonEncode({'open': false}), 200);
      }),
    );
    final app = AppState(client, tab: 'color');
    await tester.binding.setSurfaceSize(const Size(1300, 1200));
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: sxTheme(),
          home: Scaffold(body: Builder(builder: ColorScreen.new)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("This is tonight's colour already."), findsOneWidget);
    expect(find.textContaining('Nov 23 7:11 AM'), findsOneWidget);

    await tester.tap(find.text('Red').first);
    await tester.pumpAndSettle();
    expect(app.dirtyTabs, contains('color'));
    expect(find.text('Writes the two TONIGHTS COLOR scenes and adds the button to the UPLIGHTS page.'), findsOneWidget);
    expect(find.text('#ff0000'), findsWidgets);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(sent, [
      {'hex': 'ff0000', 'name': 'Red'},
    ]);

    // Undo goes back to the saved color (once the "Saved." snackbar is out of the way)
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text("This is tonight's colour already."), findsOneWidget);
    expect(app.dirtyTabs, isNot(contains('color')));
    app.dispose();
  });

  test('wheel maths match the old page', () {
    expect(hsvToHex(0, 1, 1), 'ff0000');
    expect(hsvToHex(240, 1, .5), '000080');
    final (h, s, v) = hexToHsv('f4a6b8');
    expect((h.round(), (s * 100).round(), (v * 100).round()), (346, 32, 96));
    expect(savedWhen('2026-11-23T19:05:00', DateTime(2026, 11, 23, 22)), 'today at 7:05 PM');
  });
}
