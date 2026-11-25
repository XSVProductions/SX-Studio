import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/color/color_screen.dart';
import 'package:sx_studio/screens/color/color_wheel.dart';
import 'package:sx_studio/screens/color/on_the_lights.dart';
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

  testWidgets('shows the color on the lights, follows a new pick, and stops before saving', (tester) async {
    final calls = <(String, Object?)>[];
    final preview = {
      ..._preview,
      'washFix': [
        {
          'name': 'UPLIGHT',
          'addr': 100,
          'chs': ['dimmer', 'red', 'green', 'blue', 'white', 'strobe'],
        },
      ],
    };
    final client = SxClient(
      Uri.parse('http://engine'),
      token: 't',
      client: MockClient((req) async {
        final body = req.body.isEmpty ? null : jsonDecode(req.body);
        if (req.url.path != '/api/sx') calls.add((req.url.path, body));
        return http.Response(
          jsonEncode(switch (req.url.path) {
            '/api/color' => preview,
            '/api/live/start' => {
              'ok': true,
              'iface': 'FAKE',
              'test': true,
              'info': {
                'heads': [
                  {
                    'id': '7',
                    'is140': true,
                    'addr': 10,
                    'c': [30000, 20000],
                    'look': [
                      [5, 0],
                      [6, 255],
                      [7, 200],
                    ],
                    'dimI': 6,
                    'shutI': 7,
                  },
                ],
              },
            },
            '/api/live/out' || '/api/live/stop' || '/api/color/apply' => {'ok': true, 'out': '', 'error': ''},
            _ => {'open': false},
          }),
          200,
        );
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

    await tester.tap(find.text('Show it on the lights'));
    await tester.pumpAndSettle();
    expect(calls.firstWhere((c) => c.$1 == '/api/live/start').$2, {'mode': 'floor', 'raw': false});
    expect(find.text('Live on the lights'), findsOneWidget);
    String out() => calls.where((c) => c.$1 == '/api/live/out').map((c) => (c.$2! as Map)['l'] as String).join(' ');
    // the saved blush: White on the 140's wheel, the uplight mixed with its white LED, strobe at 0
    expect(out().split(' '), containsAll(['z', 's:10:11:30000', 's:12:13:20000', 'b:15:1', 'b:16:255', 'b:17:200']));
    expect(out().split(' '), containsAll(['b:100:244', 'b:101:255', 'b:102:0', 'b:103:137', 'b:104:222', 'b:105:0']));

    calls.clear();
    await tester.tap(find.text('Red').first);
    await tester.pumpAndSettle();
    expect(out().split(' '), containsAll(['b:15:5', 'b:100:255', 'b:103:0', 'b:104:0']));
    expect(out(), isNot(contains('s:10'))); // only what changed goes out

    calls.clear();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect([for (final c in calls) c.$1].where((p) => p != '/api/color').toList(), ['/api/live/stop', '/api/color/apply']);
    expect(find.text('Show it on the lights'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    app.dispose();
  });

  testWidgets('reads the color again after the queue runs, and when ShowXpress closes unless a pick is unsaved', (tester) async {
    var open = true, reads = 0;
    Object? done;
    final client = SxClient(
      Uri.parse('http://engine'),
      token: 't',
      client: MockClient((req) async {
        final Object answer = switch (req.url.path) {
          '/api/color' => () {
            reads++;
            return _preview;
          }(),
          _ => {
            'ok': true,
            'open': open,
            'q': {'items': <Object>[], 'reopen': true, 'done': ?done},
          },
        };
        return http.Response(jsonEncode(answer), 200);
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
    await app.refresh();
    expect(reads, 1);

    // a pick waiting to be saved holds the screen back when ShowXpress closes
    await tester.tap(find.text('Red').first);
    await tester.pumpAndSettle();
    open = false;
    await app.refresh();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('Not saved yet'), findsOneWidget);

    // the queue saved it: read again
    done = {'at': '2026-11-25T20:00:00', 'ok': true};
    await app.refresh();
    await tester.pumpAndSettle();
    expect(reads, 2);

    // nothing unsaved: a close reads again
    open = true;
    await app.refresh();
    open = false;
    await app.refresh();
    await tester.pumpAndSettle();
    expect(reads, 3);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  test('the uplight mix for the lights matches the saved scene on the pinned colors', () {
    const chs = ['dimmer', 'red', 'green', 'blue', 'white'];
    expect(uplightValues('f4a6b8', chs), [(0, 244), (1, 255), (2, 0), (3, 137), (4, 222)]);
    expect(uplightValues('f4a6b8', const ['red', 'green', 'blue', 'amber']), [(0, 255), (1, 173), (2, 192), (3, 0)]);
    expect(OnTheLights.reopenNote, contains('Launch ShowXpress'));
  });

  test('wheel maths match the old page', () {
    expect(hsvToHex(0, 1, 1), 'ff0000');
    expect(hsvToHex(240, 1, .5), '000080');
    final (h, s, v) = hexToHsv('f4a6b8');
    expect((h.round(), (s * 100).round(), (v * 100).round()), (346, 32, 96));
    expect(savedWhen('2026-11-23T19:05:00', DateTime(2026, 11, 23, 22)), 'today at 7:05 PM');
  });
}
