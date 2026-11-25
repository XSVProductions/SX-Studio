import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/screens/lab/lab_screen.dart';
import 'package:sx_studio/theme.dart';

/// A small board in exactly the shape `player.ps1 -List` prints (key order,
/// types, `beats` 0.0 where live.ini has no key), with made-up names. The
/// real output is checked against the wire types in lab_wire_test.dart.
const boardJson =
    '{"ok":true,"show":"C:/Shows/Test Show","pages":['
    '{"n":1,"name":"COLORS","swap":false,"buttons":['
    '{"sec":"page1_button1","title":"RED","file":"RED.scex","path":"C:/Shows/Test Show/scenes/RED.scex","kind":"scex","steps":1,"line":1,"col":1,"color":16711680,"bpm":false,"fader":1,"key":"a","flash":false,"beats":0.0,"pad":56},'
    '{"sec":"page1_button2","title":"RAINBOW CHASE","file":"RAINBOW CHASE.scex","path":"C:/Shows/Test Show/scenes/RAINBOW CHASE.scex","kind":"scex","steps":8,"line":1,"col":2,"color":-1,"bpm":true,"fader":3,"key":"","flash":true,"beats":0.25,"pad":-1},'
    '{"sec":"page1_button3","title":"GONE","file":"GONE.scex","path":"","kind":"missing","steps":0,"line":1,"col":3,"color":-1,"bpm":false,"fader":0,"key":"","flash":false,"beats":0.0,"pad":-1}]},'
    '{"n":2,"name":"MOVEMENTS","swap":true,"buttons":['
    '{"sec":"page2_button1","title":"CIRCLE","file":"CIRCLE.gpj","path":"C:/Shows/Test Show/Editor/Generator/projects/CIRCLE.gpj","kind":"gpj","steps":0,"line":1,"col":1,"color":-1,"bpm":false,"fader":0,"key":"h","flash":false,"beats":0.0,"pad":61},'
    '{"sec":"page2_button2","title":"FIGURE 8","file":"FIGURE 8.gpj","path":"C:/Shows/Test Show/Editor/Generator/projects/FIGURE 8.gpj","kind":"gpj","steps":0,"line":1,"col":2,"color":-1,"bpm":true,"fader":0,"key":"","flash":false,"beats":0.0,"pad":62}]},'
    '{"n":3,"name":"SETUP","swap":false,"buttons":['
    '{"sec":"page3_button1","title":"RIG ID","file":"RIG ID.scex","path":"C:/Shows/Test Show/scenes/RIG ID.scex","kind":"scex","steps":2,"line":1,"col":1,"color":-1,"bpm":false,"fader":0,"key":"","flash":false,"beats":0.0,"pad":-1}]},'
    '{"n":4,"name":"EMPTY","swap":false,"buttons":[]}],'
    '"faders":[{"k":0,"caption":"MOVEMENTS","type":"1"},{"k":1,"caption":"COLORS","type":"1"},{"k":2,"caption":"","type":"0"},{"k":3,"caption":"","type":"1"}],'
    '"files":["CIRCLE.gpj","FIGURE 8.gpj","RAINBOW CHASE.scex","RED.scex","RIG ID.scex","SPARE BLUE.scex"]}';

Json decode(String s) => (jsonDecode(s) as Map).cast<String, Object?>();

/// A status file as the player writes it, through the server.
Json playerStatus({List<Json> on = const [], bool bo = false, String iface = 'ok', int reconn = 0, String err = '', List<String> warn = const []}) => {
  'ok': true,
  'bo': bo,
  'on': on,
  'err': err,
  'fd': [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
  'midi': 'APC mini mk2',
  'led': {'56': 1},
  'bpm': 124,
  'beat': 37.25,
  'src': 'manual',
  'os2l': '',
  'os2lPort': 7350,
  'os2lErr': '',
  'os2lBeats': 0,
  'iface': iface,
  'reconn': reconn,
  'warn': warn,
};

/// The engine as the tests script it: answers each route from these fields
/// and records every POST. Not an engine, a list of canned answers.
class Script {
  var sxOpen = false;
  var running = false;

  /// Live aim, the colour preview or an editor preview holds the DMX output.
  var live = false;

  /// `/api/settings` says a phone asked.
  var phone = false;

  /// The Auto Show's status in `/api/sx`, null when it never ran.
  Json? auto;
  Json? status;
  Json? event;
  Json layout = {'pages': [], 'order': {}, 'hidden': [], 'collapsed': [], 'custom': []};

  /// What `/api/lab/start` answers. Null: a plain success.
  Json? start;
  Json handoff = {'ok': true, 'error': '', 'out': '', 'titles': <String>[], 'auto': false, 'test': false};
  List<String> snapTitles = const [];

  /// When set, `/api/lab/cmd` waits for it before answering.
  Completer<Json>? cmdGate;

  /// Every POST, as (path, body).
  final posts = <(String, Json)>[];

  List<Json> get cmds => [
    for (final (p, b) in posts)
      if (p == '/api/lab/cmd') b,
  ];

  Future<http.Response> answer(http.Request r) async {
    final body = r.method == 'POST' && r.body.isNotEmpty ? decode(r.body) : <String, Object?>{};
    if (r.method == 'POST') posts.add((r.url.path, body));
    Json j;
    switch (r.url.path) {
      case '/api/sx':
        j = {
          'open': sxOpen,
          'q': {'items': [], 'reopen': true, 'done': null},
          'live': live,
          'play': running,
          'pend': false,
          'auto': auto,
          'rem': null,
        };
      case '/api/lab':
        j = decode(boardJson);
      case '/api/settings':
        j = {
          'ok': true,
          'settings': {'playerLayout': layout},
          'ver': '2.0.0',
          'phone': phone,
        };
      case '/api/settings/set':
        layout = (body['playerLayout']! as Map).cast<String, Object?>();
        j = {
          'ok': true,
          'settings': {'playerLayout': layout},
        };
      case '/api/lab/status':
        j = {'ok': true, 'running': running, 'status': running ? status : null, 'event': event};
      case '/api/lab/snap':
        j = {'ok': true, 'titles': snapTitles.length == 1 ? snapTitles.first : snapTitles};
      case '/api/sx/close':
        sxOpen = false;
        j = {'ok': true, 'out': '', 'error': ''};
      case '/api/lab/start':
        j = start ?? {'ok': true, 'iface': 'DMX USB', 'out': '', 'error': '', 'test': false, 'carried': <String>[]};
        if (j['ok'] == true) {
          running = true;
          status ??= playerStatus();
        }
      case '/api/lab/cmd':
        j = await (cmdGate?.future ?? Future.value(<String, Object?>{'ok': true}));
      case '/api/lab/handoff':
        running = false;
        j = handoff;
      case '/api/lab/stop':
        running = false;
        j = {'ok': true};
      default:
        j = {'ok': false, 'error': 'Unknown action'};
    }
    return http.Response(jsonEncode(j), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

/// Pumps the SX Player screen against [s] at [width] px. Call [Harness.end] last.
Future<Harness> pumpLab(WidgetTester t, Script s, {double width = 1200}) async {
  t.view.physicalSize = Size(width, 2400);
  t.view.devicePixelRatio = 1;
  final app = AppState(
    SxClient(Uri.parse('http://engine'), token: 'dev', client: MockClient(s.answer)),
    tab: 'lab',
  );
  await t.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        theme: sxTheme(),
        home: Scaffold(body: Builder(builder: (c) => LabScreen(c))),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return Harness(t, app);
}

class Harness {
  Harness(this.t, this.app);

  final WidgetTester t;
  final AppState app;

  /// Lets the screen's next status poll run and land (400 ms while the player runs).
  Future<void> poll() async {
    await t.pump(const Duration(milliseconds: 450));
    await t.pump();
  }

  Future<void> end() async {
    await t.pumpWidget(const SizedBox());
    app.dispose();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  }
}
