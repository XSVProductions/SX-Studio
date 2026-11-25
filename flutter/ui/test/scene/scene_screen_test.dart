import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/scene/scene_screen.dart';
import 'package:sx_studio/theme.dart';

import 'scene_fixture.dart';

void main() {
  late List<Sent> sent;
  late AppState app;

  // what the fake engine's status says, and how often the scenes were read
  var sxOpen = false, queueDone = '';
  var listReads = 0, sceneReads = 0;

  Map<String, Object? Function(Map<String, Object?>)> engine() => {
    '/api/sx': (_) => {
      'ok': true,
      'open': sxOpen,
      'q': {
        if (queueDone.isNotEmpty) 'done': {'at': queueDone},
      },
    },
    '/api/scenes': (_) => {
      'reads': ++listReads,
      'ok': true,
      'show': '/show',
      'scenes': [
        {'file': 'TEST SCENE.scex', 'name': 'TEST SCENE', 'steps': 3, 'heads': 2, 'used': [], 'trimmed': false, 'at': ''},
        {
          'file': 'OTHER.scex',
          'name': 'OTHER',
          'steps': 1,
          'heads': 1,
          'used': ['PAGE: OTHER'],
          'trimmed': true,
          'at': '',
        },
      ],
    },
    '/api/scene': (q) {
      sceneReads++;
      return sceneJson('${q['f']}');
    },
    '/api/scene/backups': (_) => {'ok': true, 'file': 'TEST SCENE.scex', 'backups': []},
    '/api/scene/save': (_) => {'ok': true, 'out': '  CHANGED  TEST SCENE: 1 value'},
    '/api/live/start': (_) => {'ok': true, 'test': true, 'iface': ''},
    '/api/live/out': (_) => {'ok': true},
    '/api/live/stop': (_) => {'ok': true},
  };

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sent = [];
    sxOpen = false;
    queueDone = '';
    listReads = sceneReads = 0;
    app = AppState(fakeEngine(sent, engine()), tab: 'scene');
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: sxTheme(),
          home: Scaffold(body: Builder(builder: (c) => SceneScreen(c))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  }

  Future<void> openScene(WidgetTester tester) async {
    await tester.tap(find.text('TEST SCENE'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the scenes and finds by button', (tester) async {
    await pumpScreen(tester);
    expect(find.text('2 scenes · tap one to open it'), findsOneWidget);
    expect(find.text('trimmed tonight'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'page: oth');
    await tester.pump();
    expect(find.text('TEST SCENE'), findsNothing);
    expect(find.text('OTHER'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an edit marks the tab dirty and the save sends only it, with the sha', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    expect(find.text('STEPS'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);

    // Spot 1 is picked when the scene opens; its dimmer in step 1 is 255.
    await tester.enterText(find.widgetWithText(TextField, '255').first, '10');
    await tester.pump();
    expect(app.dirtyTabs, contains('scene'));
    expect(find.text('1 value. Only that is changed in the file.'), findsOneWidget);
    expect(find.text('Not saved yet'), findsOneWidget);

    await tester.tap(find.text('Save scene'));
    await tester.pumpAndSettle();
    final save = sent.singleWhere((s) => s.path == '/api/scene/save').body;
    expect(save['scene'], 'TEST SCENE.scex');
    expect(save['sha'], 'abc123');
    expect((save['steps'] as List).first, {
      'src': 0,
      'set': [
        {'fx': '1', 'ix': 0, 'v': 10},
      ],
    });
    // The scene is read again after the save and matches the show.
    expect(app.dirtyTabs, isEmpty);
    await finish(tester);
  });

  testWidgets('undo puts the scene back', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await tester.tap(find.text('Copy step'));
    await tester.pump();
    expect(find.text('3 to 4 steps. Only that is changed in the file.'), findsOneWidget);
    await tester.tap(find.text('Undo changes'));
    await tester.pump();
    expect(find.text('Matches the show.'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    await finish(tester);
  });

  Future<void> startPreview(WidgetTester tester) async {
    await tester.tap(find.text('Show on the lights'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sent.where((s) => s.path == '/api/live/start'), hasLength(1));
    expect(find.text('TEST - no real output'), findsOneWidget);
  }

  int stops() => sent.where((s) => s.path == '/api/live/stop').length;

  testWidgets('leaving the tab stops the preview', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await startPreview(tester);
    expect(stops(), 0);
    app.go('home');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(stops(), 1);
    await finish(tester);
  });

  testWidgets('leaving the scene stops the preview', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await startPreview(tester);
    await tester.tap(find.text('All scenes'));
    await tester.pumpAndSettle();
    expect(stops(), 1);
    expect(find.text('TEST SCENE'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('leaving with unsaved edits asks first', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await tester.tap(find.text('Copy step'));
    await tester.pump();
    await tester.tap(find.text('All scenes'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this scene?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('STEPS'), findsOneWidget);
    expect(app.dirtyTabs, contains('scene'));
    await finish(tester);
  });

  testWidgets('another tab can ask for a scene', (tester) async {
    await pumpScreen(tester);
    app.openFile('scene', 'OTHER.scex');
    await tester.pumpAndSettle();
    expect(find.text('OTHER'), findsOneWidget);
    expect(find.text('STEPS'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('asked for another scene with unsaved edits, it asks first', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await tester.tap(find.text('Copy step'));
    await tester.pump();

    app.openFile('scene', 'OTHER.scex');
    await tester.pumpAndSettle();
    expect(find.text('Leave this scene?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('TEST SCENE'), findsOneWidget);
    expect(app.dirtyTabs, contains('scene'));

    app.openFile('scene', 'OTHER.scex');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave it'));
    await tester.pumpAndSettle();
    expect(find.text('OTHER'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    await finish(tester);
  });

  testWidgets('after the queue saved, the list and the open scene are read again', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await tester.tap(find.text('Copy step'));
    await tester.pump();
    expect((listReads, sceneReads), (1, 1));

    // ShowXpress closing alone leaves the Scene Editor as it is
    sxOpen = true;
    await app.refresh();
    sxOpen = false;
    await app.refresh();
    await tester.pumpAndSettle();
    expect((listReads, sceneReads), (1, 1));

    // the queue ran: its saves are in the show, the edits on screen are gone, no question asked
    queueDone = '2026-11-25T01:30:00';
    await app.refresh();
    await tester.pumpAndSettle();
    expect((listReads, sceneReads), (2, 2));
    expect(find.text('Leave this scene?'), findsNothing);
    expect(find.text('TEST SCENE'), findsOneWidget);
    expect(app.dirtyTabs, isEmpty);
    await finish(tester);
  });

  testWidgets('a save shows what changed in the result card', (tester) async {
    await pumpScreen(tester);
    await openScene(tester);
    await tester.enterText(find.widgetWithText(TextField, '255').first, '10');
    await tester.pump();
    await tester.tap(find.text('Save scene'));
    await tester.pumpAndSettle();
    expect(find.text('Scene saved'), findsOneWidget);
    expect(find.text('TEST SCENE: 1 value'), findsOneWidget);
    expect(find.text('Open ShowXpress to check it.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a look made on the Looks tab makes the list read again', (tester) async {
    await pumpScreen(tester);
    expect(listReads, 1);
    app.sceneMade('NEW LOOK.scex');
    await tester.pumpAndSettle();
    expect(listReads, 2);
    await finish(tester);
  });
}
