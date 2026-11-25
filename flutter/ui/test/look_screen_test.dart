import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
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
  late AppState app;

  Future<void> open(WidgetTester tester) async {
    sent = [];
    final client = SxClient(
      Uri.parse('http://engine'),
      token: 't',
      client: MockClient((req) async {
        if (req.url.path == '/api/looks') return http.Response(jsonEncode(_rig().toJson()), 200);
        if (req.url.path == '/api/looks/make') {
          sent.add(jsonDecode(req.body));
          return http.Response(jsonEncode({'ok': true, 'out': '', 'error': ''}), 200);
        }
        return http.Response(jsonEncode({'open': false}), 200);
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
}
