import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/settings/drive_card.dart';
import 'package:sx_studio/theme.dart';
import 'package:sx_studio/widgets/sx_widgets.dart';

void main() {
  group('resultOf, as the old showResult', () {
    test('lists the changed lines, without CHANGED and the routine ones', () {
      final r = resultOf(
        const ToolResult(ok: true, out: 'Speed faders\n  CHANGED  BEAT 1: fader 3 -> 5\n  same     BEAT 2\n  live.ini saved\nnot indented'),
        'speed',
      );
      expect(r.tone, ResultTone.ok);
      expect(r.title, 'Speed faders saved');
      expect(r.items, ['BEAT 1: fader 3 -> 5']);
      expect(r.after, 'Open ShowXpress to use it.');
      expect(r.log, contains('not indented'));
    });

    test('nothing to change says so', () {
      final r = resultOf(const ToolResult(ok: true, out: '  nothing to change'), 'rig');
      expect(r.title, 'Nothing needed changing');
      expect(r.items, isEmpty);
    });

    test('SKIP FLASH lists the heads and the loop', () {
      final r = resultOf(const ToolResult(ok: true, out: 'x\n  heads: 140 #1, 140 #2\n  loop: 4 steps\n'), 'skip');
      expect(r.title, 'Saved to SKIP FLASH');
      expect(r.items, ['heads: 140 #1, 140 #2', 'loop: 4 steps']);
      expect(r.after, 'Open ShowXpress and press *SKIP FLASH* to check it.');
      expect(resultOf(const ToolResult(ok: true, out: '  nothing to change'), 'skip').title, 'SKIP FLASH already uses these heads');
    });

    test('a failure says why and that nothing changed', () {
      final r = resultOf(const ToolResult(ok: false, error: 'No show.'), 'gimport');
      expect(r.title, 'Not imported');
      expect(r.lead, 'No show.');
      expect(r.text, ['Nothing was changed.']);
      expect(failedTitle('scene'), 'Not saved');
      expect(failedTitle('clprev'), "Preview didn't start");
      expect(failedTitle('lab'), "Didn't work");
    });

    test('a queued save says what waits and that ShowXpress opens again', () {
      final r = resultOf(const ToolResult(ok: true, extra: {'queued': true, 'label': 'Speed faders', 'replaced': true}), 'speed');
      expect(r.tone, ResultTone.queued);
      expect(r.title, 'Queued: Speed faders');
      expect(r.text.single, startsWith('Replaces what was queued for it before. Nothing is changed yet.'));
      expect(r.text.single, endsWith('and opens ShowXpress again.'));
    });
  });

  testWidgets('a save shows the result card under the screen; Full details opens the report; a new tab hides it', (tester) async {
    final client = SxClient(
      Uri.parse('http://laptop'),
      token: 't',
      client: MockClient((r) async {
        final Object answer = switch (r.url.path) {
          '/api/sx' => {
            'ok': true,
            'open': false,
            'q': {'items': <Object>[], 'reopen': true},
          },
          '/api/apc/apply' => {'ok': true, 'out': 'APC\n  CHANGED  PAD 1: note 3\nend of report'},
          _ => {'ok': false, 'error': 'not in this test'},
        };
        return http.Response(jsonEncode(answer), 200);
      }),
    );
    final app = AppState(client, tab: 'apc');
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: sxTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ScreenBody(
                children: [
                  FilledButton(
                    onPressed: () => runSave(context, () => client.run('/api/apc/apply'), what: 'apc'),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('APC pads saved'), findsOneWidget);
    expect(find.text('PAD 1: note 3'), findsOneWidget);
    expect(find.text('Open ShowXpress to use it.'), findsOneWidget);
    expect(find.text('end of report'), findsNothing);
    expect(find.text('Saved.'), findsNothing);
    await tester.tap(find.text('Full details'));
    await tester.pumpAndSettle();
    expect(find.text('APC\n  CHANGED  PAD 1: note 3\nend of report'), findsOneWidget);

    app.go('speed');
    await tester.pump();
    expect(find.text('APC pads saved'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('a Drive import reads every tab again and says so', (tester) async {
    final posts = <String>[];
    final client = SxClient(
      Uri.parse('http://laptop'),
      token: 't',
      client: MockClient((r) async {
        if (r.method == 'POST') posts.add(r.url.path);
        final Object answer = switch (r.url.path) {
          '/api/sx' => {
            'ok': true,
            'open': false,
            'q': {'items': <Object>[], 'reopen': true},
          },
          '/api/settings' => {'ok': true, 'settings': const SxSettings().toJson(), 'ver': '2.0.0', 'phone': false},
          '/api/gdrive' => const DriveInfo(show: '/show', here: true, found: true, target: '/drive', srcFound: true).toJson(),
          '/api/gdrive/import' => {'ok': true, 'out': 'Imported\n  copied 12 files'},
          _ => {'ok': false, 'error': 'not in this test'},
        };
        return http.Response(jsonEncode(answer), 200);
      }),
    );
    tester.view.physicalSize = const Size(1300, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState(client, tab: 'settings');
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: MaterialApp(
          theme: sxTheme(),
          home: const Scaffold(body: ScreenBody(children: [DriveCard()])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('deleted here'), findsNothing);
    expect(find.textContaining('nothing is deleted'), findsOneWidget);
    final runs = app.queueRuns;
    await tester.tap(find.text('Import from Google Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(posts, ['/api/gdrive/import']);
    expect(app.queueRuns, runs + 1, reason: 'the old reloadAll');
    expect(find.text('Imported from Google Drive'), findsOneWidget);
    expect(find.text('copied 12 files'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
