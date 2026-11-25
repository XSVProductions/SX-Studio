@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';

import 'lab_fixture.dart';

/// Walks up from here to the workspace and returns [rel] when it exists.
String? _above(String rel) {
  for (var d = Directory.current.absolute; d.parent.path != d.path; d = d.parent) {
    final p = '${d.path}/$rel';
    if (FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) return p;
  }
  return null;
}

/// Numbers compare by value: PowerShell writes 1 where Dart writes 1.0.
bool same(Object? a, Object? b) => switch ((a, b)) {
  (final num x, final num y) => x == y,
  (final Map<String, Object?> x, final Map<String, Object?> y) =>
    x.length == y.length && [...x.keys].join('|') == [...y.keys].join('|') && x.keys.every((k) => same(x[k], y[k])),
  (final List<Object?> x, final List<Object?> y) => x.length == y.length && [for (var i = 0; i < x.length; i++) i].every((i) => same(x[i], y[i])),
  _ => a == b,
};

Object? roundTrip(Object? v) => jsonDecode(jsonEncode(v));

void main() {
  // SX_PWSH, SX_OLD_SRC and SX_SHOW name them, as for the engine's parity tests. Otherwise they are looked for above
  // this folder: the old app cloned next to the port (`repo/`), or the port inside the SX-Studio repository (`src/`).
  final env = Platform.environment;
  final pwsh = env['SX_PWSH'] ?? _above('tools/pwsh/pwsh');
  final player = env['SX_OLD_SRC'] == null ? _above('repo/src/player.ps1') ?? _above('src/player.ps1') : '${env['SX_OLD_SRC']}/player.ps1';
  final show = env['SX_SHOW'] ?? _above('real-show/Awaaz Lightshow');

  test(
    'the board from player.ps1 -List on the real show reads and writes back key for key',
    () async {
      final tmp = Directory.systemTemp.createTempSync('sx_lab_wire');
      try {
        final copy = '${tmp.path}/show';
        final cp = await Process.run('cp', ['-r', show!, copy]);
        expect(cp.exitCode, 0);
        final r = await Process.run(pwsh!, ['-NoProfile', '-File', player!, '-List', '-TestRoot', copy]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final raw = jsonDecode((r.stdout as String).trim().split('\n').last);
        final j = (raw as Map).cast<String, Object?>();
        expect(same(roundTrip(LabBoard.fromJson(j).toJson()), j), isTrue);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
    skip: pwsh == null || player == null || show == null ? 'PowerShell, the old source or the show is missing' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('the test board reads and writes back key for key', () {
    final j = decode(boardJson);
    expect(same(roundTrip(LabBoard.fromJson(j).toJson()), j), isTrue);
  });

  test('a status as the player writes it reads and writes back key for key', () {
    // [SxPlayer]::Status(): mv and bpm only when true.
    const raw =
        '{"ok":true,"bo":false,"on":[{"slot":"page2_button1","step":5,"of":12,"mv":true},{"slot":"x1_b1","step":1,"of":4,"bpm":true}],"err":"",'
        '"fd":[0.5,0.723,0.5],"midi":"","led":{"56":1,"61":3},"bpm":124.5,"beat":37.25,"src":"tap","os2l":"","os2lPort":0,"os2lErr":"Port 7350 is in use",'
        '"os2lBeats":0,"iface":"lost","reconn":2,"warn":["RED: no steps"]}';
    final j = decode(raw);
    final s = LabPlayerStatus.fromJson(j);
    expect(s.lost, isTrue);
    expect(s.on.first.mv, isTrue);
    expect(same(roundTrip(s.toJson()), j), isTrue);
  });

  test('the status route with the player stopped', () {
    final j = decode('{"ok":true,"running":false,"status":null,"event":{"n":3,"kind":"gone","text":"x","at":"2026-11-25T01:02:03.0000000+01:00"}}');
    final s = LabStatus.fromJson(j);
    expect(s.status, isNull);
    expect(s.event!.kind, LabEventKind.gone);
    expect(same(roundTrip(s.toJson()), j), isTrue);
  });

  test("snap titles come back as a bare string or null from the old server's \$( ) and still read as a list", () {
    expect(decode('{"ok":true,"titles":"RED"}').strList('titles'), ['RED']);
    expect(decode('{"ok":true,"titles":null}').strList('titles'), isEmpty);
    expect(decode('{"ok":true,"titles":["A","B"]}').strList('titles'), ['A', 'B']);
  });

  test('start answers', () {
    final ok = LabStart.fromJson(decode('{"ok":true,"iface":"DMX USB PRO","out":"","error":"","test":false,"carried":["RED"],"list":$boardJson}'));
    expect(ok.list!.pages, hasLength(4));
    expect(ok.carried, ['RED']);
    final refused = LabStart.fromJson(decode('{"ok":false,"sxopen":true,"error":"ShowXpress is open","out":""}'));
    expect(refused.sxopen, isTrue);
    expect(refused.list, isNull);
  });

  test('commands send the bodies the old page sent', () {
    expect(LabCmd.press('page1_button1').toJson(), {'cmd': 'press', 'sec': 'page1_button1'});
    expect(LabCmd.fader(3, .5).toJson(), {'cmd': 'fader', 'k': 3, 'v': .5});
    expect(LabCmd.blackout(true).toJson(), {'cmd': 'bo', 'on': true});
    expect(LabCmd.allOff.toJson(), {'cmd': 'alloff'});
    expect(LabCmd.key('a').toJson(), {'cmd': 'key', 'key': 'a'});
  });

  test('the player layout reads and writes back key for key', () {
    final j = decode(
      '{"pages":["2","x1"],"order":{"2":["page2_button2"]},"hidden":[],"collapsed":["1"],'
      '"custom":[{"id":"x1","name":"FIRST DANCE","swap":true,"buttons":[{"id":"x1_b1","title":"BLUE","file":"BLUE.scex","fader":2,"bpm":true,"flash":false,"beats":0.5,"color":255}]}]}',
    );
    expect(same(roundTrip(PlayerLayout.fromJson(j).toJson()), j), isTrue);
  });
}
