import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/lab/lab_live.dart';

import 'lab_fixture.dart';

TileState tileOf(WidgetTester t, String title) => t.widget<TileView>(find.ancestor(of: find.text(title), matching: find.byType(TileView))).state.value;

/// Presses [yes] in the dialog on top.
Future<void> confirm(WidgetTester t, String yes) async {
  await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, yes)));
  await t.pump();
}

void main() {
  testWidgets('the board shows the show pages in order, without empty pages', (t) async {
    final h = await pumpLab(t, Script());
    expect(find.text('COLORS'), findsOneWidget);
    expect(find.text('MOVEMENTS'), findsOneWidget);
    expect(find.text('EMPTY'), findsNothing);
    expect(find.text('[A] scene'), findsOneWidget);
    expect(find.text('8 steps · BPM flash'), findsOneWidget);
    expect(find.text('scene file missing'), findsOneWidget);
    expect(find.text('[H] movement'), findsOneWidget);
    expect(find.text('Start the player'), findsOneWidget);
    await h.end();
  });

  testWidgets('tapping a scene while stopped starts the player and plays it', (t) async {
    final s = Script();
    final h = await pumpLab(t, s);
    await t.tap(find.text('RED'));
    await t.pump();
    await t.pump();
    expect(s.posts.map((p) => p.$1), containsAllInOrder(['/api/lab/start', '/api/lab/cmd']));
    expect(s.cmds.single, {'cmd': 'press', 'sec': 'page1_button1'});
    expect(tileOf(t, 'RED').on, isTrue);
    expect(find.text('Playing on DMX USB. Tap a button to start or stop it.'), findsOneWidget);
    expect(find.text('Stop the player'), findsOneWidget);
    expect(find.text('TEMPO'), findsOneWidget);
    await h.end();
  });

  testWidgets('a tap shows at once, before the engine answers, and the status corrects it', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    s.cmdGate = Completer();
    await t.tap(find.text('RIG ID'));
    await t.pump();
    expect(tileOf(t, 'RIG ID').on, isTrue, reason: 'on before the engine answered');

    // A status from before the press doesn't undo it while the command is out.
    await h.poll();
    expect(tileOf(t, 'RIG ID').on, isTrue);

    s.cmdGate!.complete({'ok': true});
    await t.pump();
    // The engine never turned it on. The first status after the answer may be
    // older than the command, the second one wins.
    await t.pump(const Duration(milliseconds: 130));
    await t.pump();
    expect(tileOf(t, 'RIG ID').on, isTrue);
    await h.poll();
    expect(tileOf(t, 'RIG ID').on, isFalse);
    expect(tileOf(t, 'RIG ID').text, '2 steps');
    await h.end();
  });

  testWidgets('a playing button shows its step, and goes off when tapped', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus(
        on: [
          {'slot': 'page1_button2', 'step': 3, 'of': 8, 'bpm': true},
          {'slot': 'page2_button1', 'step': 5, 'of': 12, 'mv': true},
        ],
      );
    final h = await pumpLab(t, s);
    expect(tileOf(t, 'RAINBOW CHASE').text, 'step 3 of 8');
    expect(tileOf(t, 'CIRCLE').text, 'moving');
    await t.tap(find.text('RAINBOW CHASE'));
    await t.pump();
    expect(tileOf(t, 'RAINBOW CHASE').on, isFalse);
    expect(s.cmds.last, {'cmd': 'press', 'sec': 'page1_button2'});
    s.status = playerStatus(
      on: [
        {'slot': 'page2_button1', 'step': 6, 'of': 12, 'mv': true},
      ],
    );
    await h.poll();
    expect(tileOf(t, 'RAINBOW CHASE').on, isFalse);
    expect(tileOf(t, 'RAINBOW CHASE').text, '8 steps · BPM flash');
    await h.end();
  });

  testWidgets('on a one-at-a-time page a tap turns the others off at once', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus(
        on: [
          {'slot': 'page2_button1', 'step': 1, 'of': 12, 'mv': true},
        ],
      );
    final h = await pumpLab(t, s);
    s.cmdGate = Completer();
    await t.tap(find.text('FIGURE 8'));
    await t.pump();
    expect(tileOf(t, 'FIGURE 8').on, isTrue);
    expect(tileOf(t, 'CIRCLE').on, isFalse);
    s.cmdGate!.complete({'ok': true});
    await h.end();
  });

  testWidgets('a button whose file is missing says so and sends nothing', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    await t.tap(find.text('GONE'));
    await t.pump();
    expect(find.text('GONE: its file is missing.'), findsWidgets);
    expect(s.cmds, isEmpty);
    await h.end();
  });

  testWidgets('blackout shows at once and follows the status', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    await t.tap(find.text('Blackout'));
    await t.pump();
    expect(find.text('Blackout is ON'), findsOneWidget);
    expect(s.cmds.last, {'cmd': 'bo', 'on': true});
    s.status = playerStatus(bo: true);
    await h.poll();
    expect(find.text('Blackout is ON'), findsOneWidget);
    await h.end();
  });

  testWidgets('a speed fader sends its value, at most every 60 ms', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    expect(find.text('×1.00 (normal)'), findsNWidgets(3), reason: 'type 1 faders only');
    final slider = find.byType(Slider).at(1);
    await t.drag(slider, const Offset(400, 0));
    await t.pump(const Duration(milliseconds: 70));
    final f = s.cmds.where((c) => c['cmd'] == 'fader').toList();
    expect(f, hasLength(1));
    expect(f.single['k'], 1);
    expect(f.single['v'], 1.0);
    expect(find.text('×4.0'), findsOneWidget);
    await h.end();
  });

  testWidgets('a key on the keyboard plays the button with that trigger', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.pump();
    expect(s.cmds, [
      {'cmd': 'key', 'key': 'a'},
    ]);
    await h.end();
  });

  testWidgets('the interface unplugged and back', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus()
      ..event = {'n': 4, 'kind': 'restart', 'text': 'old news', 'at': ''};
    final h = await pumpLab(t, s);
    await h.poll();
    expect(find.text('old news'), findsNothing, reason: 'an event from before the screen opened is not shown');

    s.status = playerStatus(iface: 'lost');
    s.event = {'n': 5, 'kind': 'lost', 'text': 'The DMX interface was unplugged. Plug it back in - the player carries on by itself.', 'at': ''};
    await h.poll();
    expect(find.textContaining('The DMX interface is unplugged.'), findsOneWidget);
    expect(find.textContaining('The DMX interface was unplugged.'), findsOneWidget, reason: 'toast');

    s.status = playerStatus(reconn: 1);
    s.event = {'n': 6, 'kind': 'back', 'text': 'The DMX interface is back - the lights are playing again.', 'at': ''};
    await h.poll();
    expect(find.textContaining('The DMX interface is unplugged.'), findsNothing);
    expect(find.textContaining('The DMX interface is back'), findsOneWidget);
    await h.end();
  });

  testWidgets('the player restarting itself is said under the controls', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    await h.poll();
    s.event = {'n': 1, 'kind': 'restart', 'text': 'The SX Player stopped by itself and was started again.', 'at': ''};
    await h.poll();
    // The first event since the screen opened only sets the mark.
    expect(find.text('The SX Player stopped by itself and was started again.'), findsNothing);
    s.event = {'n': 2, 'kind': 'restart', 'text': 'Started again.', 'at': ''};
    await h.poll();
    expect(find.text('Started again.'), findsWidgets);
    await h.end();
  });

  testWidgets('the player stopping with no event says SX Studio lost it', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    s.running = false;
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();
    expect(find.text('The player stopped. SX Studio lost it.'), findsOneWidget);
    expect(find.text('Start the player'), findsOneWidget);
    await h.end();
  });

  testWidgets('a command the player is gone for stops the screen', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    s.cmdGate = Completer()..complete({'ok': false, 'gone': true, 'error': 'The SX Player stopped.'});
    await t.tap(find.text('RED'));
    await t.pump();
    await t.pump();
    expect(find.text('Start the player'), findsOneWidget);
    expect(find.text('The SX Player stopped.'), findsWidgets);
    await h.end();
  });

  testWidgets('hand over to ShowXpress', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus()
      ..handoff = {
        'ok': true,
        'error': '',
        'out': '',
        'titles': ['RED', 'CIRCLE'],
        'auto': false,
        'test': false,
      };
    final h = await pumpLab(t, s);
    await t.tap(find.text('Hand over to ShowXpress'));
    await t.pump();
    await confirm(t, 'Hand over');
    await t.pump();
    expect(s.posts.last.$1, '/api/lab/handoff');
    expect(find.text("Handed over: ShowXpress is starting. It will play RED, CIRCLE once it's ready."), findsOneWidget);
    expect(find.text('Start the player'), findsOneWidget);
    await h.end();
  });

  testWidgets('stopping asks first while something plays', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus(
        on: [
          {'slot': 'page1_button1', 'step': 1, 'of': 1},
        ],
      );
    final h = await pumpLab(t, s);
    await t.tap(find.text('Stop the player'));
    await t.pump();
    expect(find.text('Stop the player?'), findsOneWidget);
    await confirm(t, 'Stop the player');
    await t.pump();
    expect(s.posts.last.$1, '/api/lab/stop');
    expect(find.text('Stopped. The lights are out.'), findsOneWidget);
    expect(tileOf(t, 'RED').on, isFalse);
    await h.end();
  });

  testWidgets('stopping asks first while the Auto Show plays on the player, even with no button on', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus()
      ..auto = {'running': true, 'target': 'player'};
    final h = await pumpLab(t, s);
    await t.tap(find.text('Stop the player'));
    await t.pump();
    expect(find.text('Stop the player?'), findsOneWidget);
    expect(s.posts.where((p) => p.$1 == '/api/lab/stop'), isEmpty);
    await h.end();
  });

  testWidgets('starting closes ShowXpress first and carries on what it played', (t) async {
    final s = Script()
      ..sxOpen = true
      ..snapTitles = ['RED']
      ..start = {
        'ok': true,
        'iface': 'DMX USB',
        'out': '',
        'error': '',
        'test': false,
        'carried': ['RED'],
      };
    final h = await pumpLab(t, s);
    await t.tap(find.text('Start the player'));
    await t.pump();
    await t.pump();
    expect(find.textContaining('The player carries on with what ShowXpress is playing now: RED.'), findsOneWidget);
    await confirm(t, 'Close and start');
    await t.pump(const Duration(seconds: 1));
    await t.pump();
    expect(find.textContaining('Waiting for it to let go of the interface'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 2600));
    await t.pump();
    expect(s.posts.map((p) => p.$1), containsAllInOrder(['/api/lab/snap', '/api/sx/close', '/api/lab/start']));
    expect(s.posts.firstWhere((p) => p.$1 == '/api/sx/close').$2, {'force': false, 'live': true});
    expect(find.text('Playing on DMX USB. Tap a button to start or stop it. Carried on from ShowXpress: RED.'), findsOneWidget);
    await h.end();
  });

  testWidgets('the refusal when ShowXpress is open', (t) async {
    final s = Script()
      ..start = {
        'ok': false,
        'sxopen': true,
        'error': 'ShowXpress is open - it has to be closed while the SX Player plays (only one program can use the DMX interface).',
        'out': '',
      };
    final h = await pumpLab(t, s);
    await t.tap(find.text('Start the player'));
    await t.pump();
    await t.pump();
    expect(find.text("Didn't work"), findsOneWidget);
    expect(find.textContaining('ShowXpress is open - it has to be closed'), findsOneWidget);
    expect(find.text('Start the player'), findsOneWidget);
    await h.end();
  });

  testWidgets('starting is refused while another screen sends DMX, before ShowXpress is touched', (t) async {
    final s = Script()
      ..sxOpen = true
      ..live = true;
    final h = await pumpLab(t, s);
    await t.tap(find.text('Start the player'));
    await t.pump();
    await t.pump();
    expect(find.text('Aim live, the colour preview or an editor or Looks preview is using the DMX interface. Finish that first.'), findsOneWidget);
    expect(s.posts, isEmpty);
    await h.end();
  });

  testWidgets('right-click a scene: Edit scene opens it in the Scene Editor', (t) async {
    final h = await pumpLab(t, Script());
    await t.tap(find.text('RED'), buttons: kSecondaryButton);
    await t.pumpAndSettle();
    await t.tap(find.text('Edit scene'));
    await t.pumpAndSettle();
    expect(h.app.tab, 'scene');
    expect(h.app.takeFile('scene'), 'RED.scex');
    await h.end();
  });

  testWidgets('long-press a movement: Edit movement opens it in the Movement Editor', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus();
    final h = await pumpLab(t, s);
    await t.longPress(find.text('CIRCLE'));
    await t.pumpAndSettle();
    expect(s.cmds, isEmpty, reason: 'a long press is not a press');
    await t.tap(find.text('Edit movement'));
    await t.pumpAndSettle();
    expect(h.app.tab, 'move');
    expect(h.app.takeFile('move'), 'CIRCLE.gpj');
    await h.end();
  });

  testWidgets('a missing file can not be edited', (t) async {
    final h = await pumpLab(t, Script());
    await t.tap(find.text('GONE'), buttons: kSecondaryButton);
    await t.pumpAndSettle();
    await t.tap(find.text('Edit scene (file missing)'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(h.app.tab, 'lab');
    expect(h.app.takeFile('scene'), isNull);
    await h.end();
  });

  testWidgets('the "open ShowXpress again" box is on the laptop only', (t) async {
    for (final phone in [false, true]) {
      final s = Script()
        ..running = true
        ..phone = phone
        ..status = playerStatus();
      final h = await pumpLab(t, s);
      expect(find.text('Open ShowXpress again when I stop'), phone ? findsNothing : findsOneWidget);
      await h.end();
    }
  });

  testWidgets('works at 380 px wide', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus(warn: ['RED: 2 problems']);
    final h = await pumpLab(t, s, width: 380);
    expect(t.takeException(), isNull);
    expect(find.textContaining('Show check: 1 problem in the show'), findsOneWidget);
    // Two tiles side by side.
    final a = t.getTopLeft(find.text('RED'));
    final b = t.getTopLeft(find.text('RAINBOW CHASE'));
    expect(a.dy, b.dy);
    await h.end();
  });

  testWidgets('pages follow the saved layout, and hidden pages say how to get them back', (t) async {
    final s = Script()
      ..layout = {
        'pages': ['2', '1'],
        'order': {
          '1': ['page1_button2'],
        },
        'hidden': ['3'],
        'collapsed': [],
        'custom': [
          {
            'id': 'x1',
            'name': 'FIRST DANCE',
            'swap': false,
            'buttons': [
              {'id': 'x1_b1', 'title': 'BLUE', 'file': 'SPARE BLUE.scex', 'fader': 0, 'bpm': false, 'flash': false, 'beats': 1, 'color': -1},
              {'id': 'x1_b2', 'title': 'LOST', 'file': 'NOT THERE.scex', 'fader': 0, 'bpm': false, 'flash': false, 'beats': 1, 'color': -1},
            ],
          },
        ],
      };
    final h = await pumpLab(t, s);
    double y(String text) => t.getTopLeft(find.text(text)).dy;
    expect(y('MOVEMENTS'), lessThan(y('COLORS')));
    expect(y('COLORS'), lessThan(y('FIRST DANCE')));
    expect(find.text('SETUP'), findsNothing);
    expect(find.text('1 page is hidden. Press Arrange to show it again.'), findsOneWidget);
    expect(t.getTopLeft(find.text('RAINBOW CHASE')).dx, lessThan(t.getTopLeft(find.text('RED')).dx));
    expect(find.text('scene file missing'), findsNWidgets(2), reason: "a player page's button whose file is gone");
    await h.end();
  });

  testWidgets('collapsing a page saves the layout and counts what plays on it', (t) async {
    final s = Script()
      ..running = true
      ..status = playerStatus(
        on: [
          {'slot': 'page1_button1', 'step': 1, 'of': 1},
        ],
      );
    final h = await pumpLab(t, s);
    await t.tap(find.text('COLORS').last);
    await t.pump();
    await t.pump();
    expect(find.text('RED'), findsNothing);
    expect(find.text('1 PLAYING'), findsOneWidget);
    expect(s.posts.last.$1, '/api/settings/set');
    expect((s.layout['collapsed']! as List), ['1']);
    await h.end();
  });

  testWidgets('Arrange: hide a page, move a page, make a player page with copies', (t) async {
    final s = Script();
    final h = await pumpLab(t, s);
    await t.tap(find.text('Arrange'));
    await t.pump();

    // Hide SETUP. It stays on screen, marked, while arranging.
    await t.tap(find.widgetWithText(OutlinedButton, 'Hide').at(2));
    await t.pump();
    await t.pump();
    expect(s.layout['hidden'], ['3']);
    expect(find.text('HIDDEN'), findsOneWidget);

    // MOVEMENTS up above COLORS.
    await t.tap(find.byIcon(Icons.arrow_drop_up).at(1));
    await t.pump();
    await t.pump();
    expect(s.layout['pages'], ['2', '1', '3']);
    expect(s.layout['order'], {
      '2': ['page2_button1', 'page2_button2'],
      '1': ['page1_button1', 'page1_button2', 'page1_button3'],
      '3': ['page3_button1'],
    });

    // A new page, with a show button and a file no button plays.
    await t.tap(find.text('New page'));
    await t.pump();
    await t.enterText(find.byType(TextField).last, '  First <dance>  ');
    await confirm(t, 'Make the page');
    await t.pump();
    await t.pump();
    expect(find.text('Add buttons to First dance'), findsOneWidget);
    await t.tap(find.text('RAINBOW CHASE').last);
    await t.enterText(find.widgetWithText(TextField, 'Search'), 'spare');
    await t.pump();
    expect(find.text('RED'), findsOneWidget, reason: 'only the board behind the dialog');
    await t.tap(find.text('SPARE BLUE'));
    await t.pump();
    await confirm(t, 'Add');
    await t.pump();
    await t.pump();
    final custom = (s.layout['custom']! as List).single as Map;
    expect(custom['id'], 'x1');
    expect(custom['name'], 'First dance');
    expect(custom['buttons'], [
      {'id': 'x1_b1', 'title': 'RAINBOW CHASE', 'file': 'RAINBOW CHASE.scex', 'fader': 3, 'bpm': true, 'flash': true, 'beats': 0.25, 'color': -1},
      {'id': 'x1_b2', 'title': 'SPARE BLUE', 'file': 'SPARE BLUE.scex', 'fader': 0, 'bpm': false, 'flash': false, 'beats': 1.0, 'color': -1},
    ]);
    expect(s.layout['pages'], ['2', '1', '3', 'x1']);

    await t.tap(find.text('Done'));
    await t.pump();
    expect(find.text('SETUP'), findsNothing);
    expect(find.text('FIRST DANCE'), findsOneWidget);
    await h.end();
  });
}
