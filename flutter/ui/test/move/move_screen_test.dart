import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/move/move_canvas.dart';
import 'package:sx_studio/screens/move/move_screen.dart';
import 'package:sx_studio/theme.dart';

/// A movement with the shape, one value graph and two heads, one of them not patched.
Json doc() => {
  'ok': true,
  'file': 'CIRCLE.gpj',
  'name': 'CIRCLE',
  'sha': 'abc',
  'readonly': '',
  'aim': '',
  'used': ['MOVES: CIRCLE'],
  'params': {},
  'heads': [
    {
      'k': 0,
      'id': 'h1',
      'name': 'Beam 1',
      'label': 'B1',
      'model': 'Beam',
      'addr': 1,
      'chans': ['Pan', 'Tilt', 'Dimmer'],
      'rp': 0,
      'rt': 0,
      'op': 0,
      'ot': 0,
      'zp': 0,
      'zt': 0,
      'has': ['OffsetPan', 'OffsetTilt', 'ZoomPan', 'ZoomTilt'],
    },
    {
      'k': 1,
      'id': 'h2',
      'name': 'Beam 2',
      'label': 'B2',
      'model': 'Beam',
      'addr': 0,
      'chans': ['Pan', 'Tilt'],
      'rp': 1,
      'rt': 0,
      'op': 100,
      'ot': 0,
      'zp': 0,
      'zt': 0,
      'has': ['OffsetPan', 'OffsetTilt', 'ZoomPan', 'ZoomTilt'],
    },
  ],
  'secs': [
    {
      'name': movePtSection,
      'sel': 1,
      'tr': 2,
      'dur': 50,
      'shift': 10,
      'curve': '',
      'pts': [
        [20000, 20000],
        [40000, 20000],
        [40000, 40000],
        [20000, 40000],
      ],
      'locked': false,
      'has': ['Selected', 'Transition', 'Duration', 'Shift'],
    },
    {
      'name': 'Dimmer',
      'sel': 0,
      'tr': 1,
      'dur': 20,
      'shift': 0,
      'curve': '',
      'pts': [
        [0, 0],
        [65535, 65280],
      ],
      'locked': false,
      'has': ['Selected', 'Transition', 'Duration', 'Shift'],
    },
  ],
};

/// The engine's side: canned answers, and every POST it got.
class Engine {
  final posts = <(String, Json)>[];
  final gets = <String>[];
  var sxOpen = false;
  Json revert = {'ok': true, 'out': 'CHANGED'};
  List<Json> backups = [
    {'id': '20261124-101500-000', 'at': '2026-11-24T10:15:00', 'what': 'Pan / Tilt: shape'},
  ];

  Future<http.Response> answer(http.Request r) async {
    Json body = const {};
    if (r.method == 'POST') {
      body = (jsonDecode(r.body) as Map).cast<String, Object?>();
      posts.add((r.url.path, body));
    } else {
      gets.add(r.url.path);
    }
    final Json out = switch (r.url.path) {
      '/api/sx' => {'open': sxOpen},
      '/api/sx/close' => (() {
        sxOpen = false;
        return <String, Object?>{'ok': true};
      })(),
      '/api/moves' => {
        'ok': true,
        'show': 'show',
        'moves': [
          {
            'file': 'CIRCLE.gpj',
            'name': 'CIRCLE',
            'heads': 2,
            'points': 4,
            'moves': true,
            'cycle': 5,
            'on': [],
            'used': ['MOVES: CIRCLE'],
            'aim': '',
            'readonly': '',
          },
          {'file': 'ROOM.gpj', 'name': 'ROOM', 'heads': 8, 'points': 6, 'moves': true, 'cycle': 20, 'on': [], 'used': [], 'aim': 'room', 'readonly': ''},
        ],
      },
      '/api/move' => doc(),
      '/api/move/backups' => {'ok': true, 'file': 'CIRCLE.gpj', 'backups': backups},
      '/api/move/save' => {'ok': true, 'out': 'CHANGED'},
      '/api/move/revert' => revert,
      '/api/scenes' => {
        'ok': true,
        'scenes': [
          {'file': 'RED.scex', 'name': 'RED'},
        ],
      },
      '/api/live/start' => {'ok': true, 'iface': 'DMX USB', 'test': false},
      _ => {'ok': true},
    };
    return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json'});
  }

  List<Json> postsTo(String path) => [
    for (final p in posts)
      if (p.$1 == path) p.$2,
  ];
}

Future<AppState> pumpMove(WidgetTester t, Engine e, {double width = 1200}) async {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = Size(width, 2600);
  t.view.devicePixelRatio = 1;
  final app = AppState(
    SxClient(Uri.parse('http://engine'), token: 'dev', client: MockClient(e.answer)),
    tab: 'move',
  );
  await t.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(body: Builder(builder: (c) => MoveScreen(c))),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return app;
}

Future<void> end(WidgetTester t, AppState app) async {
  await t.pumpWidget(const SizedBox());
  app.dispose();
  t.view.resetPhysicalSize();
  t.view.resetDevicePixelRatio();
}

Future<void> open(WidgetTester t) async {
  await t.tap(find.text('CIRCLE'));
  for (var i = 0; i < 4; i++) {
    await t.pump();
  }
}

/// Types [v] into the number box on the row labelled [label], and leaves it.
Future<void> typeIn(WidgetTester t, String label, String v) async {
  final box = find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
    matching: find.byType(TextField),
  );
  await t.enterText(box, v);
  await t.testTextInput.receiveAction(TextInputAction.done);
  await t.pump();
}

void main() {
  testWidgets('the list filters by name or button, and a movement opens with its warnings', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    expect(find.text('2 movements · tap one to open it'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'moves:');
    await t.pump();
    expect(find.text('ROOM'), findsNothing);
    expect(find.text('2 movements · 1 found · tap one to open it'), findsOneWidget);

    await open(t);
    expect(find.text('On MOVES: CIRCLE · 2 heads'), findsOneWidget);
    expect(find.textContaining("1 head isn't patched in the show"), findsOneWidget);
    expect(find.text('Matches the show'), findsOneWidget);
    expect(find.text('Earlier versions'), findsOneWidget);
    expect(find.text('reverse pan'), findsOneWidget);
    expect(find.text('Save movement'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save movement')).onPressed, isNull);
    await end(t, app);
  });

  testWidgets('a changed cycle is the only thing saved, and the tab is marked until then', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    await typeIn(t, 'Once round in', '7,5');
    expect(app.dirtyTabs, contains('move'));
    expect(find.text('Not saved yet'), findsOneWidget);
    expect(find.text('Pan / Tilt: cycle. Only that is changed in the file.'), findsOneWidget);

    await t.tap(find.text('Save movement'));
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect(e.postsTo('/api/move/save').single, {
      'move': 'CIRCLE.gpj',
      'sha': 'abc',
      'secs': [
        {'name': movePtSection, 'dur': 75},
      ],
      'heads': [],
    });
    // Reopened from the file after the save.
    expect(e.gets.where((g) => g == '/api/move').length, 2);
    expect(app.dirtyTabs, isNot(contains('move')));
    await t.pump(const Duration(seconds: 5));
    await end(t, app);
  });

  testWidgets('Bigger changes the shape, Step back takes it back', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    await t.tap(find.text('Bigger'));
    await t.pump();
    expect(find.text('Pan / Tilt: shape. Only that is changed in the file.'), findsOneWidget);
    await t.tap(find.text('Step back'));
    await t.pump();
    expect(find.text('Matches the show'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    await end(t, app);
  });

  testWidgets('leaving with unsaved changes asks first, and Cancel keeps them', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    await typeIn(t, 'Each next head behind by', '25');
    await t.tap(find.text('All movements'));
    await t.pump();
    expect(find.text('Leave this movement?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(find.text('Pan / Tilt: shift. Only that is changed in the file.'), findsOneWidget);

    await t.tap(find.text('All movements'));
    await t.pump();
    await t.tap(find.text('Leave it'));
    await t.pump();
    await t.pump();
    expect(find.text('2 movements · tap one to open it'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    await end(t, app);
  });

  testWidgets('a head aim typed past the limit is held to it and goes out as a whole number', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    final aim = find.byKey(const ValueKey('h0op'));
    await t.enterText(find.descendant(of: aim, matching: find.byType(TextField)), '99999.4');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(find.text('1 head aimed or sized. Only that is changed in the file.'), findsOneWidget);
    await t.tap(find.text('Save movement'));
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect(e.postsTo('/api/move/save').single['heads'], [
      {'k': 0, 'op': 65535},
    ]);
    await t.pump(const Duration(seconds: 5));
    await end(t, app);
  });

  testWidgets('a revert that finds the movement changed asks, then forces', (t) async {
    final e = Engine()..revert = {'ok': true, 'conflict': true, 'out': ''};
    final app = await pumpMove(t, e);
    await open(t);
    await t.tap(find.text('Revert to this'));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Revert'));
    await t.pump();
    await t.pump();
    expect(find.text('The movement changed since'), findsOneWidget);
    e.revert = {'ok': true, 'out': 'CHANGED'};
    await t.tap(find.text('Revert anyway'));
    for (var i = 0; i < 6; i++) {
      await t.pump();
    }
    expect([for (final b in e.postsTo('/api/move/revert')) b['force']], [false, true]);
    expect(find.text('Movement reverted'), findsOneWidget);
    expect(find.text('Open ShowXpress to check it.'), findsOneWidget);
    await end(t, app);
  });

  testWidgets('the lights get the movement as raw DMX and stop when the tab changes', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    await t.tap(find.text('Show on the lights'));
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(e.postsTo('/api/live/start').single, {'mode': 'floor', 'raw': true});
    await t.pump(const Duration(milliseconds: 100));
    final first = '${e.postsTo('/api/live/out').first['l']}';
    // Clears the interface first, then the patched head's pan and tilt. The dimmer graph is off.
    expect(first, matches(RegExp(r'^z b:1:\d+ b:2:\d+$')));
    expect(find.text('Output: DMX USB'), findsOneWidget);

    app.go('home');
    await t.pump();
    await t.pump();
    expect(e.postsTo('/api/live/stop'), hasLength(1));
    expect(e.postsTo('/api/sx/launch'), isEmpty);
    await t.pump(const Duration(seconds: 1));
    await end(t, app);
  });

  testWidgets('with ShowXpress open the preview asks, closes it for the lights, and opens it again on Stop', (t) async {
    final e = Engine()..sxOpen = true;
    final app = await pumpMove(t, e);
    await open(t);
    await t.tap(find.text('Show on the lights'));
    await t.pump();
    await t.pump();
    expect(find.text('Close ShowXpress to see the movement on the lights?'), findsOneWidget);
    await t.tap(find.text('Close and preview'));
    await t.pump();
    await t.pump();
    expect(e.postsTo('/api/sx/close').single, {'force': false, 'live': true});
    expect(e.postsTo('/api/live/start'), isEmpty, reason: 'waits for ShowXpress to let go first');
    // One status poll a second, then 2.5 s for the interface.
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    await t.pump(const Duration(milliseconds: 2600));
    await t.pump();
    expect(e.postsTo('/api/live/start'), hasLength(1));
    expect(find.text('Open ShowXpress again when I stop'), findsOneWidget);

    await t.tap(find.text('Stop'));
    await t.pump();
    await t.pump();
    expect(e.postsTo('/api/live/stop'), hasLength(1));
    expect(e.postsTo('/api/sx/launch'), hasLength(1));
    expect(AppScope.read(t.element(find.byType(MoveScreen))).busy, 'Starting ShowXpress.');
    // it stays up 3 s after a good start, as the old page's did
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(app.busy, '');
    await end(t, app);
  });

  testWidgets('another tab can open a movement here', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    app.openFile('move', 'CIRCLE.gpj');
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(find.text('On MOVES: CIRCLE · 2 heads'), findsOneWidget);
    await end(t, app);
  });

  testWidgets('another tab asking to open a movement over unsaved edits asks first', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e);
    await open(t);
    await typeIn(t, 'Each next head behind by', '25');
    app.openFile('move', 'ROOM.gpj');
    await t.pump();
    await t.pump();
    expect(find.text('Leave this movement?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(find.text('Pan / Tilt: shift. Only that is changed in the file.'), findsOneWidget);
    expect(e.gets.where((g) => g == '/api/move'), hasLength(1));
    expect(app.takeFile('move'), isNull, reason: 'the request was used up');
    await end(t, app);
  });

  testWidgets('fits a phone: 380 px wide, the editor lays out without overflow', (t) async {
    final e = Engine();
    final app = await pumpMove(t, e, width: 380);
    await open(t);
    expect(find.text('Pan / Tilt'), findsWidgets);
    expect(find.byType(MoveCanvas), findsOneWidget);
    expect(t.takeException(), isNull);
    await end(t, app);
  });

  group('canvas', () {
    MoveCanvasModel model() {
      final d = MoveDoc.fromJson(doc());
      return MoveCanvasModel(doc: d, state: MoveState.of(d), sec: 0, point: -1, view: wholeRange, at: 0);
    }

    Future<void> pumpCanvas(WidgetTester t, MoveCanvasModel m, {ValueChanged<List<MovePt>>? onDrag, void Function(Offset, Size)? onAdd}) async {
      await t.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: MoveCanvas(model: m, onSelect: (_) {}, onDrag: onDrag ?? (_) {}, onDragEnd: (_) {}, onAdd: onAdd ?? (_, _) {}),
            ),
          ),
        ),
      );
    }

    testWidgets('dragging a point moves only that point', (t) async {
      final m = model();
      List<MovePt>? got;
      await pumpCanvas(t, m, onDrag: (p) => got = p);
      final at = toPx(m, m.state.secs[0].pts[1], const Size(300, 300));
      await t.dragFrom(at, const Offset(0, 30), kind: PointerDeviceKind.touch);
      expect(got![0], (20000, 20000));
      expect(got![1].$1, 40000);
      expect(got![1].$2, closeTo(20000 + 30 / 300 * moveMax, 1));
    });

    testWidgets('dragging empty space moves the whole shape, kept inside the range', (t) async {
      final m = model();
      List<MovePt>? got;
      await pumpCanvas(t, m, onDrag: (p) => got = p);
      await t.dragFrom(const Offset(150, 150), const Offset(-200, 0), kind: PointerDeviceKind.touch);
      expect(got!.map((p) => p.$1).reduce((a, b) => a < b ? a : b), 0);
      expect(got![1].$1 - got![0].$1, 20000);
    });

    testWidgets('a double tap on empty space adds a point there', (t) async {
      Offset? added;
      await pumpCanvas(t, model(), onAdd: (at, _) => added = at);
      await t.tapAt(const Offset(150, 150));
      await t.pump(const Duration(milliseconds: 100));
      await t.tapAt(const Offset(150, 150));
      expect(added, const Offset(150, 150));
    });
  });
}
