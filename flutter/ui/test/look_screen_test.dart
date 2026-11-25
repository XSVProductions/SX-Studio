import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_studio/screens/look/look_screen.dart';
import 'package:sx_studio/theme.dart';

/// Two RGB pars and nothing else.
LookRig _rig() => LookRig(
  show: '/show',
  sxOpen: false,
  heads: const [
    LookHead(id: '1', name: 'PAR 1', model: 'RGB PAR', addr: 1),
    LookHead(id: '2', name: 'PAR 2', model: 'RGB PAR', addr: 5),
  ],
  skipped: const [],
  models: const {
    'RGB PAR': ModelCaps(
      chans: [LookChannel(0, 'Red'), LookChannel(1, 'Green'), LookChannel(2, 'Blue'), LookChannel(3, 'Dimmer')],
      pan: false,
      slots: [],
      wheel: -1,
      rgb: {
        'red': [0],
        'green': [1],
        'blue': [2],
      },
      dim: 3,
      shut: null,
      kill: [],
      prisms: [],
      grot: null,
      gobos: [],
      zoom: -1,
      focus: -1,
      frost: -1,
      gobo: -1,
    ),
  },
  scenes: ['OLD LOOK.scex'],
);

void main() {
  late List<Object?> sent;
  late List<(String, Object?)> calls;
  late AppState app;
  const ok = {'ok': true, 'out': '', 'error': ''};

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(WidgetTester tester) async {
    sent = [];
    calls = [];
    var layout = <String, Object?>{
      'pages': ['1'],
      'custom': <Object?>[],
    };
    final client = SxClient(
      Uri.parse('http://engine'),
      token: 't',
      client: MockClient((req) async {
        final body = req.body.isEmpty ? null : jsonDecode(req.body);
        if (req.url.path != '/api/sx') calls.add((req.url.path, body));
        if (req.url.path == '/api/settings/set') layout = ((body! as Map)['playerLayout'] as Map).cast();
        return http.Response(
          jsonEncode(switch (req.url.path) {
            '/api/looks' => _rig().toJson(),
            '/api/looks/make' => () {
              sent.add(body);
              return ok;
            }(),
            '/api/settings' || '/api/settings/set' => {
              'ok': true,
              'settings': {'playerLayout': layout},
            },
            '/api/live/start' => {'ok': true, 'iface': 'FAKE', 'test': true, 'info': <String, Object?>{}},
            '/api/live/out' || '/api/live/stop' => ok,
            _ => {'open': false},
          }),
          200,
        );
      }),
    );
    app = AppState(client, tab: 'look');
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: sxTheme(),
          home: Scaffold(body: Builder(builder: LookScreen.new)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('makes the look under its automatic name, then offers the next free one', (tester) async {
    await open(tester);
    final auto = lookAutoName(LookTemplate.contrast, LookOptions(), _rig().scenes);
    expect(find.text(auto), findsOneWidget);
    expect(find.text('a new file: scenes/$auto.scex'), findsOneWidget);

    await tester.tap(find.text('Make the scene'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final draft = LookDraft.fromJson((sent.single! as Map).cast<String, Object?>());
    expect(draft.name, '$auto.scex');
    expect(draft.steps, isNotEmpty);
    expect(draft.steps.first.f.keys, unorderedEquals(['1', '2']));
    expect(find.text('Made: $auto'), findsOneWidget);

    // the name it just used is taken now, so the box moves on to a free one
    expect(find.text(auto), findsNothing);
    await tester.pump(const Duration(seconds: 5)); // let the "Saved." snackbar go
    app.dispose();
  });

  testWidgets('a name the show already has can not be made', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('look-name')), 'old look');
    await tester.pumpAndSettle();
    expect(find.text("There's already a scene called that. Pick another name."), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Make the scene')).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('look-name')), 'Wedding contrast');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make the scene'));
    await tester.pumpAndSettle();
    expect((sent.single! as Map)['name'], 'Wedding contrast.scex');
    await tester.pump(const Duration(seconds: 5));
    app.dispose();
  });

  testWidgets('puts the look made on a new SX Player page, and opens it in the Scene Editor', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('look-name')), 'Wedding contrast');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make the scene'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('+ a new page: LOOKS'), findsOneWidget);

    await tester.tap(find.text('Put it on this SX Player page'));
    await tester.pumpAndSettle();
    final saved = (calls.lastWhere((c) => c.$1 == '/api/settings/set').$2! as Map)['playerLayout'] as Map;
    expect(saved['pages'], ['1', 'x1']);
    expect(saved['custom'], [
      {
        'id': 'x1',
        'name': 'LOOKS',
        'swap': false,
        'buttons': [
          {'id': 'x1_b1', 'title': 'Wedding contrast', 'file': 'Wedding contrast.scex', 'fader': 0, 'bpm': false, 'flash': false, 'beats': 1, 'color': -1},
        ],
      },
    ]);
    expect(find.text('LOOKS'), findsWidgets);
    expect(find.text('Open the SX Player'), findsOneWidget);

    await tester.tap(find.text('Change it in the Scene Editor'));
    await tester.pumpAndSettle();
    expect(app.tab, 'scene');
    app.dispose();
  });

  testWidgets('keeps its settings for next time', (tester) async {
    SharedPreferences.setMockInitialValues({
      lookPrefsKey: jsonEncode({
        'contrast': {
          'pairs': [
            ['Red', 'Green'],
          ],
        },
      }),
    });
    await open(tester);
    expect(find.text('CONTRAST RED GREEN'), findsOneWidget);

    await tester.tap(find.text('Fade between steps (LED lights)'));
    await tester.pumpAndSettle();
    final kept = jsonDecode((await SharedPreferences.getInstance()).getString(lookPrefsKey)!) as Map;
    expect((kept['contrast'] as Map)['fade'], true);
    expect((kept['contrast'] as Map)['pairs'], [
      ['Red', 'Green'],
    ]);
    app.dispose();
  });

  testWidgets('plays the look on the lights through the raw output, and stops', (tester) async {
    await open(tester);
    await tester.tap(find.text('Show on the lights'));
    await tester.pumpAndSettle();
    expect(calls.firstWhere((c) => c.$1 == '/api/live/start').$2, {'mode': 'floor', 'raw': true});
    expect(find.text('TEST - no real output'), findsOneWidget);
    final first = (calls.firstWhere((c) => c.$1 == '/api/live/out').$2! as Map)['l'] as String;
    // both pars lit: red, green, blue and dimmer at addresses 1 and 5
    expect(first.split(' '), containsAll(['z', 'b:1:255', 'b:4:255', 'b:5:0', 'b:8:255']));

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, '/api/live/stop');
    expect(find.text('Show on the lights'), findsOneWidget);
    app.dispose();
  });
}
