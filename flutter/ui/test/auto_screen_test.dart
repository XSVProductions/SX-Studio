import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/auto/auto_screen.dart';
import 'package:sx_studio/screens/remote/remote_row.dart';
import 'package:sx_studio/theme.dart';

/// A stand-in engine: answers by path and records every POST body.
class _Engine {
  _Engine({this.ready = true, this.remote = const RemoteState()});

  bool ready;
  AutoStatus status = const AutoStatus(running: false);
  RemoteState remote;
  final posts = <String, Json>{};

  final config = AutoConfig(
    bpm: 124,
    looks: [
      AutoLook(id: 'aaaaaaaa', name: 'Circles', bars: 16, on: true, titles: ['CIRCLE', 'RED']),
      AutoLook(id: 'bbbbbbbb', name: 'Eights', bars: 8, on: true, titles: ['FIGURE 8']),
    ],
  );

  static const buttons = [
    AutoButton(title: 'CIRCLE', page: 'MOVEMENTS', dup: false, reach: true, swap: true),
    AutoButton(title: 'FIGURE 8', page: 'MOVEMENTS', dup: false, reach: true, swap: true),
    AutoButton(title: 'RED', page: 'COLORS', dup: false, reach: true, swap: false),
  ];

  Json _answer(String path, Json body) => switch (path) {
    '/api/sx' => {'ok': true, 'open': true, 'auto': status.toJson()},
    '/api/auto' => AutoInfo(show: 'Test Show', config: config, buttons: buttons, ready: ready, open: true, setup: _setup, status: status).toJson(),
    '/api/auto/status' => {'ok': true, 'status': status.toJson()},
    '/api/auto/save' => {'ok': true, 'out': 'saved', 'error': '', 'config': body['config']},
    '/api/auto/start' => {'ok': true, 'status': (status = _playing).toJson()},
    '/api/auto/cmd' => {'ok': true, 'status': status.toJson()},
    '/api/remote' || '/api/remote/press' => remote.toJson(),
    _ => {'ok': false, 'error': 'unknown $path'},
  };

  late final client = SxClient(
    Uri.parse('http://laptop'),
    token: 't',
    client: MockClient((req) async {
      final body = req.body.isEmpty ? <String, Object?>{} : (jsonDecode(req.body) as Map).cast<String, Object?>();
      if (req.method == 'POST') posts[req.url.path] = body;
      return http.Response(jsonEncode(_answer(req.url.path, body)), 200);
    }),
  );
}

const _setup = RemoteSetup(appOn: true, allowed: true, password: true, pagesOff: []);

const _playing = AutoStatus(
  running: true,
  lookId: 'aaaaaaaa',
  name: 'Circles',
  next: 'Eights',
  nextId: 'bbbbbbbb',
  bars: 16,
  bar: 1,
  beat: 1,
  msLeft: 30000,
  bpm: 128,
  applied: true,
);

Future<AppState> _pump(WidgetTester tester, Widget Function(BuildContext) screen, _Engine e, {String tab = 'auto'}) async {
  tester.view.physicalSize = const Size(1300, 1400);
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

/// Takes the screen down so the app's status timer stops.
Future<void> _done(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(const SizedBox());
  app.dispose();
}

void main() {
  testWidgets('an edited look name marks the tab, and Save sends the edit and clears the mark', (tester) async {
    final e = _Engine();
    final app = await _pump(tester, AutoScreen.new, e);
    expect(find.text('2 of 2 looks in the show · one round ≈ 0:46 at 124 BPM'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Circles'), 'Big circles');
    await tester.pump();
    expect(app.dirtyTabs, contains('auto'));
    expect(find.text('Not saved yet.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final sent = (e.posts['/api/auto/save']!['config']! as Map)['looks']! as List;
    expect((sent.first as Map)['name'], 'Big circles');
    expect(app.dirtyTabs, isNot(contains('auto')));
    await _done(tester, app);
  });

  testWidgets('with the remote off it says so and Start stays off', (tester) async {
    final e = _Engine(ready: false);
    final app = await _pump(tester, AutoScreen.new, e);
    expect(find.text("The ShowXpress remote is off, so the Auto Show can't press anything yet."), findsOneWidget);
    final start = tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Start Auto Show'), matching: find.bySubtype<ButtonStyleButton>()));
    expect(start.onPressed, isNull);
    await _done(tester, app);
  });

  testWidgets('Start plays the chosen look, then Next look sends next', (tester) async {
    final e = _Engine();
    final app = await _pump(tester, AutoScreen.new, e);
    await tester.tap(find.text('Start Auto Show'));
    await tester.pumpAndSettle();
    expect(e.posts['/api/auto/start'], {'look': 'aaaaaaaa'});
    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.textContaining('next: Eights in'), findsOneWidget);

    await tester.tap(find.text('Next look'));
    await tester.pump();
    expect(e.posts['/api/auto/cmd'], {'cmd': 'next', 'v': ''});
    await _done(tester, app);
  });

  testWidgets('a look with two one-at-a-time buttons warns and offers a split', (tester) async {
    final e = _Engine();
    e.config.looks[1].titles = ['CIRCLE', 'FIGURE 8'];
    final app = await _pump(tester, AutoScreen.new, e);
    expect(find.textContaining('MOVEMENTS plays one button at a time, only FIGURE 8 of these 2 would play.', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Split into one look each'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split into 2 looks'));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 looks in the show · one round ≈ 1:02 at 124 BPM'), findsOneWidget);
    expect(app.dirtyTabs, contains('auto'));
    await _done(tester, app);
  });

  testWidgets('the remote row shows the set that is on, and a tap turns another on alone', (tester) async {
    final e = _Engine(
      remote: const RemoteState(
        ready: true,
        open: true,
        connected: true,
        titles: ['DF CHECK 140', 'DF CHECK 251', 'ROOM CHECK'],
        pressed: [PressedOnAir(title: 'ROOM CHECK', page: 'SETUP')],
      ),
    );
    final app = await _pump(
      tester,
      (_) => const RemoteRow(
        tab: 'home',
        sets: [
          RemoteSet('DF CHECK 140 + 251', ['DF CHECK 140', 'DF CHECK 251']),
          RemoteSet('ROOM CHECK', ['ROOM CHECK']),
        ],
      ),
      e,
      tab: 'other',
    );
    // the row reads ShowXpress when its tab comes on show
    app.go('home');
    await tester.pumpAndSettle();
    expect(find.textContaining('ROOM CHECK is on in ShowXpress.', findRichText: true), findsOneWidget);

    await tester.tap(find.text('DF CHECK 140 + 251'));
    await tester.pumpAndSettle();
    expect(e.posts['/api/remote/press'], {
      'titles': ['DF CHECK 140', 'DF CHECK 251'],
      'release': <Object>[],
      'solo': true,
      'idle': false,
    });
    await _done(tester, app);
  });
}
