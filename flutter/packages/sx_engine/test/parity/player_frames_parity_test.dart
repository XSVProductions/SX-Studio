/// The SX Player's frame maths against the old C# player.
///
/// The old player only compiles under Windows PowerShell 5.1 as shipped. This
/// test copies `player.ps1`, adds the assembly references PowerShell 7 needs,
/// and loads it with `-DefineOnly`, so its `[SxPlayer]` class is there but
/// never started. `player_key.ps1` then replays a list of operations at
/// chosen clock values on it, and the same list runs on [PlayerCore]. Every
/// frame (all 8192 channels) and every status must match.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:sx_engine/src/player/player_core.dart';
import 'package:sx_engine/src/player/player_files.dart';
import 'package:sx_engine/src/player/player_show.dart';
import 'package:test/test.dart';

import 'parity.dart';

typedef Op = List<Object>;

const _refs =
    'System.Xml, System.Xml.ReaderWriter, System.Core, System.Collections.Concurrent, System.Collections, System.Net.Primitives, '
    'System.Net.Sockets, System.IO.Pipes, System.Console, System.Threading, System.Threading.Thread, System.Runtime.InteropServices, '
    'System.Diagnostics.Process, System.Text.Encoding.Extensions, System.Linq, System.ComponentModel.Primitives';

/// A copy of the old player that compiles under PowerShell 7. Its compiled
/// class is cached under [_keyDir], keyed by the source, like the old app does.
final _keyDir = p.join(Directory.systemTemp.path, 'sx_player_key');

String _scratchPlayer() {
  Directory(_keyDir).createSync(recursive: true);
  final src = File(p.join(oldSrcPath!, 'player.ps1')).readAsStringSync();
  final fixed = src.replaceAll('-ReferencedAssemblies System.Xml, System.Core ', '-ReferencedAssemblies $_refs ');
  if (fixed == src) throw StateError('player.ps1 changed: the Add-Type call was not found');
  final out = p.join(_keyDir, 'player.ps1');
  File(out).writeAsStringSync(fixed);
  File(p.join(oldSrcPath!, 'show_common.ps1')).copySync(p.join(_keyDir, 'show_common.ps1'));
  return out;
}

String _num(num t) => t == t.truncate() ? '${t.toInt()}' : '$t';

String _sparse(Uint8List f) {
  final b = StringBuffer();
  for (var i = 0; i < f.length; i++) {
    if (f[i] != 0) b.write(' ${i + 1}=${f[i]}');
  }
  return b.toString();
}

Future<List<String>> _old(String show, List<Op> ops) async {
  final dir = Directory.systemTemp.createTempSync('sx_key_');
  try {
    final opsFile = File(p.join(dir.path, 'ops.json'))..writeAsStringSync(jsonEncode(ops));
    final r = await Process.run(
      pwshPath!,
      [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        p.join(_package, 'test', 'parity', 'player_key.ps1'),
        '-KeyPlayer',
        _scratchPlayer(),
        '-KeyShow',
        show,
        '-KeyOps',
        opsFile.path,
      ],
      environment: {'LOCALAPPDATA': p.join(_keyDir, 'cache')},
    );
    final outFile = File('${opsFile.path}.out');
    if (r.exitCode != 0 || !outFile.existsSync()) fail('the old player did not run: ${r.stderr}\n${r.stdout}');
    return outFile.readAsLinesSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

final String _package = () {
  var d = Directory.current.absolute;
  while (p.basename(d.path) != 'sx_engine' && d.parent.path != d.path) {
    d = d.parent;
  }
  return d.path;
}();

List<String> _dart(String show, List<Op> ops) {
  final core = PlayerCore(PlayerFiles(readPlayerPatch(p.join(show, 'fixtures.ini'))));
  loadPlayerBoard(core, ShowEnv(show));
  core.setBpm(playerStartBpm(show), 0, 'manual');
  final out = <String>[];
  double d(Object o) => (o as num).toDouble();
  for (final a in ops) {
    try {
      switch (a[0]) {
        case 'frame':
          out.add('F ${_num(a[1] as num)}${_sparse(core.frame(d(a[1])))}');
        case 'status':
          out.add('S ${jsonEncode(core.status())}');
        case 'on':
          core.on(a[1] as String, a[2] as String, d(a[3]));
        case 'off':
          core.off(a[1] as String);
        case 'alloff':
          core.allOff();
        case 'bo':
          core.blackout(a[1] as bool);
        case 'press':
          core.press(a[1] as String, d(a[2]));
        case 'seton':
          core.setOn(a[1] as String, d(a[2]));
        case 'ton':
          core.setOn(core.secOf(a[1] as String), d(a[2]));
        case 'key':
          core.keyPress(a[1] as String, d(a[2]));
        case 'midi':
          core.midi(a[1] as int, d(a[2]));
        case 'leds':
          core.syncLeds(a[1] as bool, null);
        case 'fader':
          core.setFader(a[1] as int, d(a[2]));
        case 'bpm':
          core.setBpm(d(a[1]), d(a[2]), 'manual');
        case 'tap':
          core.tap(d(a[1]));
        case 'ext':
          core.extBeat(d(a[1]), d(a[2]));
        case 'sync':
          core.syncBeat(d(a[1]));
        case 'check':
          core.checkShow();
        case 'addb':
          core.addButton(a[1] as String, a[2] as String, a[3] as String, a[4] as int, a[5] as bool, a[6] as int, '', 1, -1, 1, -1, 0, 0);
          if (a[7] as bool) core.setBeat(a[1] as String, a[8] as bool, d(a[9]));
        case 'delb':
          core.removeButton(a[1] as String);
        case 'jstr':
          final r = jsonStr(a[1] as String, a[2] as String);
          out.add(r == null ? 'J <null>' : 'J ${r.replaceAll('\n', r'\n').replaceAll('\t', r'\t')}');
        default:
          throw StateError('unknown op ${a[0]}');
      }
    } on PlayerError catch (e) {
      out.add('E ${e.message}');
    }
  }
  return out;
}

/// Runs [ops] on both players and fails at the first line that differs.
Future<void> _compare(String show, List<Op> ops) async {
  final old = await _old(show, ops);
  final now = _dart(show, ops);
  for (var i = 0; i < old.length && i < now.length; i++) {
    if (old[i] == now[i]) continue;
    if (old[i].startsWith('S ') && now[i].startsWith('S ')) {
      final a = jsonDecode(old[i].substring(2)), b = jsonDecode(now[i].substring(2));
      if (const DeepCollectionEquality().equals(a, b)) continue;
    }
    fail('line ${i + 1} differs\n  old: ${old[i]}\n  new: ${now[i]}');
  }
  expect(now.length, old.length, reason: 'number of answers');
  // the frames must not all be dark, or the comparison proved nothing
  expect(now.where((l) => l.startsWith('F ') && l.contains('=')), isNotEmpty);
}

/// Frames from [from] to [to] ms, every [step] ms.
List<Op> _frames(num from, num to, [num step = 25]) => [
  for (var t = from; t <= to; t += step) ['frame', t],
];

void main() {
  if (paritySkip != null) {
    test('player frames', () {}, skip: paritySkip);
    return;
  }
  final show = realShowPath!;
  final list = playerList(ShowEnv(show));
  final buttons = [
    for (final pg in list['pages']! as List)
      for (final b in (pg as Map)['buttons'] as List) (b as Map).cast<String, Object?>()..['page'] = pg['n'],
  ];
  final playable = buttons.where((b) => b['kind'] != 'missing').toList();
  Map<String, Object?> first(bool Function(Map<String, Object?> b) test) => playable.firstWhere(test);

  test('every button of the show, alone, for two seconds', () async {
    final ops = <Op>[];
    var t = 0;
    for (final b in playable) {
      ops
        ..add(['alloff'])
        ..add(['press', b['sec']!, t])
        ..addAll(_frames(t, t + 2000, 37))
        ..add(['status']);
      t += 2100;
    }
    await _compare(show, ops);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('layers, swap pages, toggles and blackout', () async {
    final scenes = playable.where((b) => b['kind'] == 'scex').toList();
    final moves = playable.where((b) => b['kind'] == 'gpj').toList();
    final swapPage = (list['pages']! as List).cast<Map>().firstWhere((pg) => pg['swap'] == true && (pg['buttons'] as List).length >= 2);
    final swapButtons = (swapPage['buttons'] as List).cast<Map>().where((b) => b['kind'] != 'missing').toList();
    await _compare(show, [
      ['press', scenes[0]['sec']!, 0],
      ..._frames(0, 600),
      ['press', moves[0]['sec']!, 610],
      ..._frames(625, 1500),
      ['press', swapButtons[0]['sec']!, 1510],
      ..._frames(1525, 2000),
      ['status'],
      ['press', swapButtons[1]['sec']!, 2010],
      ..._frames(2025, 2600),
      ['status'],
      ['press', scenes[1]['sec']!, 2610],
      ..._frames(2625, 3500, 30),
      ['press', scenes[0]['sec']!, 3510],
      ..._frames(3525, 4000),
      ['bo', true],
      ..._frames(4025, 4100),
      ['status'],
      ['bo', false],
      ..._frames(4125, 4300),
      ['seton', scenes[1]['sec']!, 4310],
      ['ton', swapButtons[0]['title']!, 4320],
      ..._frames(4325, 5000),
      ['status'],
      ['off', scenes[1]['sec']!],
      ..._frames(5025, 5100),
      ['alloff'],
      ..._frames(5125, 5150),
    ]);
  });

  test('speed faders scale a button clock', () async {
    final faders = (list['faders']! as List).cast<Map>();
    final speedK = {
      for (final f in faders)
        if (f['type'] == '1') f['k'],
    };
    final scene = first((b) => b['kind'] == 'scex' && b['bpm'] == false && speedK.contains(b['fader']) && (b['steps']! as int) > 1);
    final move = first((b) => b['kind'] == 'gpj' && speedK.contains(b['fader']));
    final k = scene['fader']! as int, km = move['fader']! as int;
    await _compare(show, [
      ['press', scene['sec']!, 0],
      ['press', move['sec']!, 0],
      ..._frames(0, 1000),
      ['fader', k, 0.83],
      ['fader', km, 1.4],
      ..._frames(1025, 3000),
      ['fader', k, 0.12],
      ['fader', km, 0.0],
      ..._frames(3025, 6000, 41),
      ['fader', k, 0.5],
      ..._frames(6025, 7000),
      ['status'],
    ]);
  });

  test('the beat: BPM buttons, bpm, tap, VirtualDJ, sync, beat faders', () async {
    final beatButtons = playable.where((b) => b['kind'] == 'scex' && b['bpm'] == true).toList();
    expect(beatButtons, isNotEmpty, reason: 'the show has BPM buttons');
    final faders = (list['faders']! as List).cast<Map>();
    final speedK = [
      for (final f in faders)
        if (f['type'] == '1') f['k']! as int,
    ];
    final ops = <Op>[
      for (final b in beatButtons.take(4)) ['press', b['sec']!, 0],
      ..._frames(0, 1500, 23),
      ['bpm', 90, 1510],
      ..._frames(1525, 3000, 23),
      for (final k in speedK) ['fader', k, 0.9],
      ..._frames(3025, 4000, 23),
      for (final k in speedK) ['fader', k, 0.2],
      ..._frames(4025, 5000, 23),
      for (final k in speedK) ['fader', k, 0.5],
      ['tap', 5010],
      ..._frames(5025, 5400),
      ['tap', 5480],
      ['tap', 5950],
      ['tap', 6440],
      ..._frames(6450, 8000, 29),
      ['status'],
      for (var i = 0; i < 12; i++) ...[
        ['ext', 8000 + i * 476.19, 126],
        ..._frames(8010 + i * 476.19, 8470 + i * 476.19, 50),
      ],
      ['status'],
      // VirtualDJ goes quiet: the clock carries on by itself
      ..._frames(13800, 17000, 33),
      ['sync', 17010],
      ..._frames(17025, 18500, 27),
      ['ext', 18600, 300],
      ..._frames(18625, 19000, 27),
      ['bpm', 251, 19010],
      ['bpm', 39, 19020],
      ['tap', 22100],
      ..._frames(22125, 22500, 27),
      ['status'],
    ];
    await _compare(show, ops);
  });

  test('pads, pad lights, fader CCs and keys', () async {
    final padded = playable.where((b) => (b['pad']! as int) >= 0).take(6).toList();
    final keyed = playable.where((b) => (b['key']! as String).isNotEmpty).take(3).toList();
    final ops = <Op>[
      ['leds', false],
      ['status'],
      for (final (i, b) in padded.indexed) ...[
        ['midi', 0x90 | (b['pad']! as int) << 8 | 127 << 16, i * 300],
        ..._frames(i * 300 + 5, i * 300 + 290, 35),
        ['leds', false],
        ['status'],
      ],
      ['midi', 0x90 | (padded.isEmpty ? 0 : padded[0]['pad']! as int) << 8, 2000],
      for (var cc = 48; cc < 57; cc++) ['midi', 0xB0 | cc << 8 | 100 << 16, 2010],
      for (final (i, b) in keyed.indexed) ...[
        ['key', (b['key']! as String).toUpperCase(), 2100 + i * 200],
        ..._frames(2105 + i * 200, 2290 + i * 200, 35),
      ],
      ['leds', true],
      ['status'],
    ];
    await _compare(show, ops);
  });

  test('a pad and a fader on another controller do nothing', () async {
    // Device 1 is another controller (the APC40). The player only listens to the APC mini, device 0.
    final copy = Directory.systemTemp.createTempSync('sx_device1_');
    addTearDown(() => copy.deleteSync(recursive: true));
    for (final f in Directory(show).listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(copy.path, p.relative(f.path, from: show)));
      to.parent.createSync(recursive: true);
      f.copySync(to.path);
    }
    final env = ShowEnv(copy.path);
    final padded = playable.where((b) => (b['pad']! as int) >= 0).take(2).toList();
    final ini = LiveIni.read(env);
    final cc = iniInt(ini.keys('live')['fader1_midi_note']);
    ini
      ..setKey(padded[0]['sec']! as String, 'trigger_midi_device', '1')
      ..setKey(padded[0]['sec']! as String, 'trigger_midiout_device', '1')
      ..setKey('live', 'fader1_midi_device', '1')
      ..save();
    await _compare(copy.path, [
      ['leds', false],
      ['status'],
      for (final (i, b) in padded.indexed) ...[
        ['midi', 0x90 | (b['pad']! as int) << 8 | 127 << 16, i * 300],
        ..._frames(i * 300 + 5, i * 300 + 290, 35),
        ['leds', false],
        ['status'],
      ],
      ['midi', 0xB0 | cc << 8 | 30 << 16, 700],
      ['midi', 0xB0 | (cc + 1) << 8 | 30 << 16, 710],
      ['status'],
    ]);
  });

  test('refusals and the show check', () async {
    await _compare(show, [
      ['check'],
      ['status'],
      ['press', 'page999_button1', 0],
      ['ton', '  NO SUCH BUTTON  ', 0],
      ['on', 'x', p.join(show, 'scenes', 'NOT THERE.scex'), 0],
      ['press', playable.first['sec']!, 0],
      ..._frames(0, 100),
    ]);
  });

  test('JStr reads VirtualDJ messages the same way', () async {
    const msgs = [
      '{"evt":"beat","change":false,"pos":12,"bpm":126.04,"strength":10}',
      '{"evt":"btn","name":"WHITE WASH","state":"on"}',
      '{"evt" : "btn", "name" : "A \\"Q\\" \\u0041\\n\\tB\\\\", "state" : "off" }',
      '{"evt":"beat","bpm": }',
      '{"evt":"beat"}',
      '{"bpm":"x"',
    ];
    await _compare(show, [
      for (final m in msgs)
        for (final k in ['evt', 'bpm', 'name', 'state']) ['jstr', m, k],
      ['press', playable.first['sec']!, 0],
      ['frame', 10],
    ]);
  });

  group('a made-up show', () {
    late Directory dir;
    setUpAll(() => dir = _madeUpShow());
    tearDownAll(() => dir.deleteSync(recursive: true));

    test('movements: transitions, zoom, reverse, offsets, shift, value graphs', () async {
      final ops = <Op>[
        ['check'],
        ['status'],
      ];
      var t = 0;
      for (final sec in ['page1_button1', 'page1_button2', 'page1_button3', 'page1_button4', 'page1_button5', 'page1_button6']) {
        ops
          ..add(['alloff'])
          ..add(['press', sec, t])
          ..addAll(_frames(t, t + 5000, 47))
          ..add(['status']);
        t += 5100;
      }
      await _compare(dir.path, ops);
    });

    test('scenes: one step, missing channels, odd lengths, fades from what was on', () async {
      final ops = <Op>[
        ['press', 'page2_button1', 0],
        ..._frames(0, 700),
        ['press', 'page2_button2', 710],
        ..._frames(725, 3000, 31),
        ['press', 'page2_button3', 3010],
        ..._frames(3025, 6000, 31),
        ['status'],
        ['press', 'page2_button4', 6010],
        ['press', 'page2_button5', 6010],
        ['press', 'page2_button6', 6010],
        ['press', 'page2_button7', 6010],
        ['status'],
        ['addb', 'x1_b1', p.join(dir.path, 'scenes', 'FADE.scex'), 'FADE COPY', 1001, true, 0, true, true, 0.5],
        ['addb', 'x1_b2', p.join(dir.path, 'scenes', 'CHASE.scex'), 'CHASE COPY', 1001, true, 0, true, false, 0.25],
        ['press', 'x1_b1', 6100],
        ..._frames(6125, 8000, 31),
        ['press', 'x1_b2', 8010],
        ..._frames(8025, 10000, 31),
        ['status'],
        ['delb', 'x1_b2'],
        ..._frames(10025, 10100),
        ['status'],
      ];
      await _compare(dir.path, ops);
    });
  });
}

/// A small show with what the real one doesn't have.
Directory _madeUpShow() {
  final d = Directory.systemTemp.createTempSync('sx_player_madeup_');
  void put(String rel, String text) {
    File(p.join(d.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  put(
    'fixtures.ini',
    '﻿\r\n[Fixture1]\r\naddress = 1\r\nid = 100\r\n[Fixture2]\r\naddress = 21\r\nid = 200\r\n[Fixture3]\r\naddress = 0\r\nid = 300\r\n[Fixture4]\r\nid = 400\r\naddress = 60\r\n',
  );
  const ch = 'pan,upan,tilt,utilt,color,gobo,dimmer,Zoom,pan';
  String head(int n, int id, String extra) => '[Fixture_$n]\nID = $id\nChannels = $ch\n$extra';
  String pt(int tr, String pts, {String dur = '30', String shift = '0.0'}) =>
      '[Pan/Tilt/uPan/uTilt]\nSelected = 1\nTransition = $tr\nDuration = $dur\nShift = $shift\n$pts';
  put(
    'Editor/Generator/projects/LINES.gpj',
    '[Params]\nSelected = 1\nPoint_0 = 1,1\n'
        '${head(0, 100, 'ZoomPan = 50\nZoomTilt = -20\nOffsetPan = 1000\n')}'
        '${head(1, 200, 'ReversePan = 1\nReverseTilt = 1\nOffsetTilt = -70000\n')}'
        '${pt(1, 'Point_2 = 60000,1000\nPoint_0 = 1000,1000\nPoint_1 = 30000,64000\nPoint_x = 5,5\nPoint_3 = 1,2,3\n', shift: '12.5')}'
        '[color]\nSelected = 1\nTransition = 1\nDuration = 7\nPoint_0 = 65535,0\nPoint_1 = 0,65535\nPoint_2 = 30000,20000\n'
        '[dimmer]\nSelected = 1\nTransition = 2\nDuration = 11\nShift = 25\nPoint_0 = 0,0\nPoint_1 = 20000,65535\nPoint_2 = 40000,10000\nPoint_3 = 65535,40000\n'
        '[gobo]\nSelected = 1\nTransition = 0\nDuration = 5\nPoint_0 = 0,1000\nPoint_1 = 32000,50000\n'
        '[zoom]\nSelected = 0\nPoint_0 = 0,65535\n',
  );
  put(
    'Editor/Generator/projects/JUMP.gpj',
    '${head(0, 100, '')}${head(1, 200, '')}${pt(0, 'Point_0 = 0,0\nPoint_1 = 65535,65535\nPoint_2 = 30000,10\n', dur: '9.5')}',
  );
  put(
    'Editor/Generator/projects/ONE.gpj',
    '${head(3, 100, '')}[Fixture_x]\nID = 400\nChannels = dimmer,ZOOM\n${pt(2, 'Point_0 = 1234.5,6789.25\n')}[Zoom]\nSelected = 1\nPoint_0 = 0,40000\n',
  );
  put(
    'Editor/Generator/projects/CURVE.gpj',
    '${head(0, 100, '')}${head(1, 999, '')}${pt(2, 'Point_0 = 0,0\nPoint_1 = 65535,0\nPoint_2 = 65535,65535\nPoint_3 = 0,65535\nPoint_4 = 32768,32768\n', dur: '0.5')}',
  );
  put('Editor/Generator/projects/NOHEADS.gpj', '${head(0, 999, '')}${pt(2, 'Point_0 = 0,0\n')}');
  put('Editor/Generator/projects/NOTHING.gpj', '${head(0, 100, '')}[dimmer]\nSelected = 0\nPoint_0 = 0,0\n');

  String step(String len, String body) => '<Step length="$len">$body</Step>';
  String fx(String id, String chans) => '<Fixture id="$id">$chans</Fixture>';
  String c(int ix, int v, [bool fade = false]) => '<Channel index="$ix" value="$v"${fade ? ' fade="1"' : ''}/>';
  String scene(List<String> steps) => '<?xml version="1.0" encoding="UTF-8"?>\n<Scene><Steps>${steps.join()}</Steps></Scene>';
  put('scenes/HOLD.scex', scene([step('50', fx('100', c(7, 255) + c(5, 40, true)))]));
  put(
    'scenes/CHASE.scex',
    scene([
      step('20', fx('100', c(5, 255, true) + c(7, 10)) + fx('200', c(5, 7))),
      step('abc', fx('100', c(5, 0, true))),
      step(' 35 ', fx('100', c(5, 128, true) + c(7, 300, true) + c(0, 9) + c(-3, 9)) + fx('999', c(1, 1))),
      step('0', fx('200', c(5, 200, true) + c(7, -5))),
    ]),
  );
  put('scenes/FADE.scex', scene([step('100', fx('100', c(1, 255, true) + c(7, 255, true))), step('60', fx('100', c(1, 0, true) + c(7, 100, true)))]));
  put('scenes/EMPTY.scex', scene([]));
  put('scenes/LIGHTS ONLY UNPATCHED.scex', scene([step('10', fx('999', c(1, 1)))]));

  final live = StringBuffer(
    '[live]\r\nmaster_faders = 1\r\n\r\n[master_faders]\r\ncaption_fader0 = SPEED\r\ntype_fader0 = 1\r\n\r\n[page1]\r\nname = MOVES\r\nswap = no\r\n',
  );
  void button(int pg, int n, String file, [String extra = '']) =>
      live.write('\r\n[page${pg}_button$n]\r\nline = 1\r\ncolumn = $n\r\nname = $file\r\ntitle = ${file.split('.').first}\r\n$extra');
  for (final (i, f) in ['LINES.gpj', 'JUMP.gpj', 'ONE.gpj', 'CURVE.gpj', 'NOHEADS.gpj', 'NOTHING.gpj'].indexed) {
    button(1, i + 1, f);
  }
  live.write('\r\n[page2]\r\nname = SCENES\r\nswap = no\r\n');
  for (final (i, f) in ['HOLD.scex', 'CHASE.scex', 'FADE.scex', 'EMPTY.scex', 'LIGHTS ONLY UNPATCHED.scex', 'GONE.scex', 'CHASE.scex'].indexed) {
    button(2, i + 1, f, i == 1 ? 'masterspeedfader = 0\r\n' : '');
  }
  put('Live/live.ini', live.toString());
  return d;
}
