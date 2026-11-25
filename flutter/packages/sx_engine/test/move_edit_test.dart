// The old tool's own test suite (`repo/tools/test_move_edit.ps1`), check for
// check, on the same small synthetic show. Runs anywhere, no PowerShell needed.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/src/tools/move_edit/gpj.dart';
import 'package:sx_engine/src/tools/move_edit/ps_json.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

const pt = movePtSection;
const model = 'Intimidator Hybrid 140SR (19ch)';
const chs = 'pan,upan,tilt,utilt,dimmer';

List<String> head(int k, String id, String nm, int dmx) => [
  '[Fixture_$k]',
  'ID = $id',
  'Name = $nm',
  'DMX = $dmx',
  'Channels = $chs',
  'ReversePan = 0',
  'ReverseTilt = 0',
  'OffsetPan = 0',
  'OffsetTilt = 0',
  'ZoomPan = 0',
  'ZoomTilt = 0',
  'ExplodeIndex = 0',
];

List<String> sec(String nm, int sel, int tr, int dur, List<String> pts) => [
  '[$nm]',
  'Selected = $sel',
  'CurveName = Default Curve',
  'Transition = $tr',
  'Duration = $dur',
  'Shift = 0.0',
  for (var i = 0; i < pts.length; i++) 'Point_$i = ${pts[i]}',
];

final lines = [
  '',
  '[Params]',
  'PanTiltShift = 0.0',
  'ExplodePanTilt = 0',
  'GroupRGB = 0',
  'FanPanOffset = 0',
  'FanTiltOffset = 0',
  ...head(0, '11', model, 0),
  ...head(1, '12', '$model #2', 19),
  ...sec(pt, 1, 2, 100, ['20000,50000', '25000,45000', '25000,50000', '20000,45000']),
  ...sec('dimmer', 0, 0, 50, ['0,65535', '65535,65535']),
];

/// ShowXpress's own way: BOM, LF, a blank first line.
final fig = '${lines.join('\n')}\n';

/// Saved again by ShowXpress: CRLF, and no line ending at the very end.
final crlf = lines.join('\r\n');

/// Mixed line endings and things the editor doesn't know (an unknown key, an unknown section, a key with no " = ").
const odd =
    '\n[Params]\r\nPanTiltShift = 0.0\n[Fixture_0]\nID = 11\nName = $model\nChannels = $chs\nOffsetPan = 5\r\nSomething = keep me\nZoomPan = 0\n'
    '[$pt]\nSelected = 1\nTransition = 1\nDuration = 30\nShift = 0.0\nWeird line\nPoint_0 = 1,2\r\nPoint_1 = 3,4\n[Extra]\nA = b\n';

/// The small test show of the old suite, in a fresh temp folder.
class TestShow {
  TestShow() {
    g.createSync(recursive: true);
    Directory(p.join(root, 'Live')).createSync();
    Directory(p.join(root, 'scenes')).createSync();
    File(p.join(root, 'fixtures.ini')).writeAsStringSync(
      '[Fixture1]\r\nname = 140 #1\r\nmodel = $model\r\naddress = 1\r\nid = 11\r\n\r\n[Fixture2]\r\nname = 140 #2\r\nmodel = $model\r\naddress = 20\r\nid = 12\r\n',
    );
    File(p.join(root, 'Live', 'live.ini')).writeAsBytesSync([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(
        '[live]\r\nmaster_faders = 0\r\n\r\n[page1]\r\nname = MOVEMENTS\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = FIG.gpj\r\ntitle = FIG\r\n',
      ),
    ]);
    w('FIG.gpj', fig);
    w('CRLF.gpj', crlf);
    w('ODD.gpj', odd, bom: false);
    // Points not in one block: read-only points, the rest can still be changed.
    w(
      'GAP.gpj',
      '\n[Fixture_0]\nID = 11\nName = $model\n[$pt]\nSelected = 1\nTransition = 2\nDuration = 10\nShift = 0.0\nPoint_0 = 1,1\nCurveName = x\nPoint_1 = 2,2\n',
    );
    w('NOHEADS.gpj', '\n[Params]\nPanTiltShift = 0.0\n[$pt]\nSelected = 1\nPoint_0 = 1,1\n');
    File(p.join(g.path, 'BAD.gpj')).writeAsBytesSync([0xEF, 0xBB, 0xBF, 0x0A, 0xC3, 0x28, 0x0A]);
    // Aim Movers' record of FIG (Dance Floor), at size 1.2.
    File(p.join(root, 'df_aim_state.json')).writeAsStringSync(
      '{"sx":1.2,"sy":1.2,"files":{"FIG.gpj":{"base":"x","written":"20000,50000;25000,45000;25000,50000;20000,45000","sx":1.2,"sy":1.2}},"copied":{}}',
    );
  }

  final tmp = Directory.systemTemp.createTempSync('sxm_test_');
  late final root = p.join(tmp.path, 'Test Show');
  late final g = Directory(p.join(root, 'Editor', 'Generator', 'projects'));
  late final backups = p.join(tmp.path, 'move_backups');

  // A clock that moves on a second per call, so every backup gets its own id.
  var _t = DateTime(2026, 11, 24, 21, 0, 0, 123);
  late final env = ShowEnv(root, now: () => _t = _t.add(const Duration(seconds: 1)));

  void w(String f, String text, {bool bom = true}) => File(p.join(g.path, f)).writeAsBytesSync([
    if (bom) ...[0xEF, 0xBB, 0xBF],
    ...utf8.encode(text),
  ]);
  List<int> bytes(String f) => File(p.join(g.path, f)).readAsBytesSync();
  String txt(String f) => utf8.decode(bytes(f)).replaceFirst('﻿', '');
  String sha(String f) => sha256.convert(bytes(f)).toString();
  MoveDoc open(String f) => moveOpen(env, f);

  /// Saves and returns (ok, report or error).
  (bool, String) save(Map<String, Object?> ch) {
    try {
      return (true, moveSave(env, ch, backups: backups));
    } on ToolError catch (e) {
      return (false, e.message);
    }
  }

  void dispose() => tmp.deleteSync(recursive: true);
}

void main() {
  late TestShow t;
  setUpAll(() => t = TestShow());
  tearDownAll(() => t.dispose());

  // The checks share one show and run in order, like the old suite.
  group('reading', () {
    test('Check: every movement it can edit comes out byte for byte the same', () {
      final c = moveCheck(t.env);
      expect(c.ok, isTrue, reason: [for (final m in c.moves.where((m) => !m.ok)) '${m.file}: ${m.why}'].join('; '));
    });

    test('Check: a file with no heads / not UTF-8 is skipped, not broken', () {
      expect(moveCheck(t.env).moves.where((m) => m.skipped.isNotEmpty).length, 2);
    });

    test('List: heads, points, cycle, buttons, Aim owner', () {
      final f = moveList(t.env).moves.firstWhere((m) => m.file == 'FIG.gpj');
      expect((f.heads, f.points, f.cycle, f.moves, f.used.join(), f.aim), (2, 4, 10, true, 'MOVEMENTS: FIG', 'floor'));
    });

    test('List: an unreadable file is read-only', () {
      expect(moveList(t.env).moves.firstWhere((m) => m.file == 'BAD.gpj').readonly, isNotEmpty);
    });

    test('Open: heads with DMX addresses from fixtures.ini', () {
      final o = t.open('FIG.gpj');
      expect((o.heads.length, o.heads[0].addr, o.heads[1].addr, o.aim), (2, 1, 20, 'floor'));
    });

    test('Open: the pan/tilt points', () {
      final s = t.open('FIG.gpj').secs.firstWhere((s) => s.name == pt);
      expect((s.pts.length, s.pts[1], s.dur, s.tr), (4, (25000, 45000), 100, 2));
    });

    test('Open: points that are not one block are locked', () {
      expect(t.open('GAP.gpj').secs.first.locked, isTrue);
    });
  });

  group('saving', () {
    late String s0, want;
    setUpAll(() {
      s0 = t.sha('CRLF.gpj');
      want = crlf
          .replaceAll(
            'Duration = 100\r\nShift = 0.0\r\nPoint_0 = 20000,50000\r\nPoint_1 = 25000,45000\r\nPoint_2 = 25000,50000\r\nPoint_3 = 20000,45000',
            'Duration = 45\r\nShift = 6.25\r\nPoint_0 = 1,2\r\nPoint_1 = 3,4\r\nPoint_2 = 5,6\r\nPoint_3 = 7,8\r\nPoint_4 = 9,10',
          )
          .replaceAll('Transition = 2\r\nDuration = 45', 'Transition = 1\r\nDuration = 45')
          .replaceAll('[dimmer]\r\nSelected = 0', '[dimmer]\r\nSelected = 1');
      final i1 = want.indexOf('[Fixture_1]');
      want = want.substring(0, i1) + want.substring(i1).replaceFirst('OffsetPan = 0', 'OffsetPan = -300').replaceFirst('ZoomTilt = 0', 'ZoomTilt = 25');
    });
    final five = [
      [1, 2],
      [3, 4],
      [5, 6],
      [7, 8],
      [9, 10],
    ];

    test('Save (CRLF file): only the edited lines change, CRLF kept, no ending added at the end', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'secs': [
          {'name': pt, 'pts': five, 'dur': 45, 'shift': 6.25, 'tr': 1},
          {'name': 'dimmer', 'sel': 1},
        ],
        'heads': [
          {'k': 1, 'op': -300, 'zt': 25},
        ],
      });
      expect(r.$1, isTrue, reason: r.$2);
      expect(t.txt('CRLF.gpj'), want);
      expect(t.bytes('CRLF.gpj')[0], 0xEF);
    });

    test('Save refused when the file changed since it was opened', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': s0,
        'secs': [
          {'name': pt, 'dur': 50},
        ],
      });
      expect(r.$1, isFalse);
      expect(r.$2, contains('changed since'));
    });

    test('Save refused: a point outside 0..65535', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'secs': [
          {
            'name': 'dimmer',
            'pts': [
              [0, 0],
              [70000, 1],
            ],
          },
        ],
      });
      expect(r.$1, isFalse);
      expect(r.$2, contains('0..65535'));
      expect(t.txt('CRLF.gpj'), want);
    });

    test('Save refused: a channel the movement does not have', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'secs': [
          {'name': 'nope', 'sel': 1},
        ],
      });
      expect((r.$1, r.$2.contains('no channel')), (false, true));
    });

    test('Save refused: Reverse belongs to Reverse heads', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'heads': [
          {'k': 0, 'rp': 1},
        ],
      });
      expect((r.$1, r.$2.contains('Reverse heads')), (false, true));
    });

    test('Save with nothing different writes nothing', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'secs': [
          {'name': pt, 'pts': five},
        ],
      });
      expect((r.$1, r.$2.contains('nothing to change')), (true, true));
      expect(t.txt('CRLF.gpj'), want);
    });

    test('Fewer points: the block shrinks in place', () {
      final r = t.save({
        'move': 'CRLF.gpj',
        'sha': t.open('CRLF.gpj').sha,
        'secs': [
          {
            'name': pt,
            'pts': [
              [11, 12],
            ],
          },
        ],
      });
      expect(r.$1, isTrue, reason: r.$2);
      expect(t.txt('CRLF.gpj'), contains('Shift = 6.25\r\nPoint_0 = 11,12\r\n[dimmer]'));
    });

    test('Save (odd file): unknown keys, lines and sections kept, each line keeps its own ending, no BOM added', () {
      final r = t.save({
        'move': 'ODD.gpj',
        'sha': t.open('ODD.gpj').sha,
        'secs': [
          {
            'name': pt,
            'pts': [
              [10, 20],
              [30, 40],
              [50, 60],
            ],
          },
        ],
        'heads': [
          {'k': 0, 'op': 9},
        ],
      });
      final wo = odd
          .replaceAll('Point_0 = 1,2\r\nPoint_1 = 3,4\n', 'Point_0 = 10,20\r\nPoint_1 = 30,40\r\nPoint_2 = 50,60\n')
          .replaceAll('OffsetPan = 5\r\n', 'OffsetPan = 9\r\n');
      expect(r.$1, isTrue, reason: r.$2);
      expect(t.txt('ODD.gpj'), wo);
      expect(t.bytes('ODD.gpj')[0], isNot(0xEF));
    });

    test('Save refused: a key the head does not have', () {
      final r = t.save({
        'move': 'ODD.gpj',
        'sha': t.open('ODD.gpj').sha,
        'heads': [
          {'k': 0, 'ot': 1},
        ],
      });
      expect((r.$1, r.$2.contains("no 'OffsetTilt' line")), (false, true));
    });

    test('Save refused: locked points', () {
      final r = t.save({
        'move': 'GAP.gpj',
        'sha': t.open('GAP.gpj').sha,
        'secs': [
          {
            'name': pt,
            'pts': [
              [5, 5],
            ],
          },
        ],
      });
      expect((r.$1, r.$2.contains("doesn't change")), (false, true));
    });

    test('...but its cycle can still be changed', () {
      final r = t.save({
        'move': 'GAP.gpj',
        'sha': t.open('GAP.gpj').sha,
        'secs': [
          {'name': pt, 'dur': 77},
        ],
      });
      expect(r.$1, isTrue, reason: r.$2);
      expect(t.txt('GAP.gpj'), contains('Duration = 77'));
    });

    test('Save refused: head aim in a movement Aim Movers looks after', () {
      final r = t.save({
        'move': 'FIG.gpj',
        'sha': t.open('FIG.gpj').sha,
        'heads': [
          {'k': 0, 'op': 100},
        ],
      });
      expect((r.$1, r.$2.contains('Aim Movers')), (false, true));
    });

    test("A saved shape goes into Aim Movers' record (written = as saved, base = at size 100)", () {
      final r = t.save({
        'move': 'FIG.gpj',
        'sha': t.open('FIG.gpj').sha,
        'secs': [
          {
            'name': pt,
            'pts': [
              [20000, 50000],
              [32000, 44000],
              [26000, 50000],
            ],
          },
        ],
      });
      expect(r.$1, isTrue, reason: r.$2);
      final rec = ((jsonDecode(File(p.join(t.root, 'df_aim_state.json')).readAsStringSync()) as Map)['files'] as Map)['FIG.gpj'] as Map;
      expect((rec['written'], rec['base']), ('20000,50000;32000,44000;26000,50000', '21000,49500;31000,44500;26000,49500'));
    });

    test('Render writes the preview file only', () {
      final before = t.sha('FIG.gpj'), rf = p.join(t.tmp.path, 'preview.gpj');
      moveRender(t.env, {
        'move': 'FIG.gpj',
        'sha': t.open('FIG.gpj').sha,
        'secs': [
          {'name': pt, 'dur': 20},
        ],
      }, rf);
      expect(t.sha('FIG.gpj'), before);
      expect(File(rf).readAsStringSync(), contains('Duration = 20'));
    });

    test('Every save kept a backup', () {
      expect(moveBackups(t.env, 'CRLF.gpj', backups: t.backups).backups.length, 2);
    });

    test('Revert of an old backup asks first (it was saved again since)', () {
      final first = moveBackups(t.env, 'CRLF.gpj', backups: t.backups).backups.last;
      expect(moveRevert(t.env, 'CRLF.gpj', first.id, backups: t.backups), isA<MoveRevertConflict>());
    });

    test('Revert puts the very first version back, byte for byte', () {
      final first = moveBackups(t.env, 'CRLF.gpj', backups: t.backups).backups.last;
      expect(moveRevert(t.env, 'CRLF.gpj', first.id, force: true, backups: t.backups), isA<MoveReverted>());
      expect(t.sha('CRLF.gpj'), s0);
    });

    test('No temp file left in projects/', () {
      expect(t.g.listSync().where((f) => !f.path.endsWith('.gpj')), isEmpty);
    });
  });

  // ---------------------------------------------------------------- new in the port

  test("If Aim Movers' record can't be written, the movement is put back as it was", () {
    final s = TestShow();
    addTearDown(s.dispose);
    // A record without "base": the old tool stopped after the movement was already written.
    File(p.join(s.root, 'df_aim_state.json')).writeAsStringSync('{"sx":1,"sy":1,"files":{"FIG.gpj":{"written":"1,1;2,2","sx":1,"sy":1}}}');
    final before = s.sha('FIG.gpj');
    final r = s.save({
      'move': 'FIG.gpj',
      'sha': s.open('FIG.gpj').sha,
      'secs': [
        {
          'name': pt,
          'pts': [
            [1, 1],
            [9, 9],
          ],
        },
      ],
    });
    expect(r.$1, isFalse);
    expect(r.$2, contains("'base' cannot be found"));
    expect(s.sha('FIG.gpj'), before);
  });

  test('ShowXpress open: Save and Revert refuse', () {
    final s = TestShow();
    addTearDown(s.dispose);
    final env = ShowEnv(s.root, sxRunning: () => true);
    expect(
      () => moveSave(env, {'move': 'FIG.gpj'}, backups: s.backups),
      throwsA(isA<ToolError>().having((e) => e.message, 'message', contains('ShowXpress is OPEN'))),
    );
    expect(() => moveRevert(env, 'FIG.gpj', '20260101-000000-000', backups: s.backups), throwsA(isA<ToolError>()));
  });

  group('the curve', () {
    test('pan/tilt uses tangents 0.75 x (next - previous), value graphs plain Catmull-Rom', () {
      expect(moveCard(0, 0, 100, 300, 0.5), 31.25);
      expect(moveCR(0, 0, 100, 300, 0.5), 37.5);
    });

    // The frames below come from the SX Player's own C# (player.ps1 LoadMove
    // and Eval) run on this movement: 2 heads, one aimed, sized and reversed,
    // shift on both channels, points out of order on the dimmer graph.
    test('DMX frames match the SX Player number for number', () {
      final tmp = Directory.systemTemp.createTempSync('sxm_curve_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final g = Directory(p.join(tmp.path, 'show', 'Editor', 'Generator', 'projects'))..createSync(recursive: true);
      File(p.join(tmp.path, 'show', 'fixtures.ini')).writeAsStringSync('[Fixture1]\naddress = 1\nid = 11\n\n[Fixture2]\naddress = 20\nid = 12\n');
      File(p.join(g.path, 'T.gpj')).writeAsStringSync(
        '\n[Params]\nPanTiltShift = 0.0\n[Fixture_0]\nID = 11\nName = A\nChannels = pan,upan,tilt,utilt,dimmer\nReversePan = 0\nReverseTilt = 0\n'
        'OffsetPan = 0\nOffsetTilt = 0\nZoomPan = 0\nZoomTilt = 0\n[Fixture_1]\nID = 12\nName = A #2\nChannels = pan,upan,tilt,utilt,dimmer\n'
        'ReversePan = 0\nReverseTilt = 1\nOffsetPan = 300\nOffsetTilt = -150\nZoomPan = 20\nZoomTilt = -10\n[Pan/Tilt/uPan/uTilt]\nSelected = 1\n'
        'Transition = 2\nDuration = 40\nShift = 12.5\nPoint_0 = 20000,50000\nPoint_1 = 30000,41000\nPoint_2 = 26000,52000\nPoint_3 = 21000,44000\n'
        '[dimmer]\nSelected = 1\nTransition = 2\nDuration = 20\nShift = 30.0\nPoint_0 = 0,10000\nPoint_1 = 40000,65535\nPoint_2 = 20000,30000\nPoint_3 = 60000,0\n',
      );
      final d = moveOpen(ShowEnv(p.join(tmp.path, 'show')), 'T.gpj'), st = MoveState.of(d);
      String frame(double t) {
        final f = moveFrame(d, st, t, player: true);
        return [
          for (final k in f.keys.toList()..sort())
            if (f[k] != 0) '$k:${f[k]}',
        ].join(' ');
      }

      expect(
        {
          for (final t in [0.0, 250, 777, 1999.5, 3100, 5432.1]) t: frame(t.toDouble()),
        },
        {
          0.0: '1:78 2:32 3:195 4:80 5:39 20:65 21:155 22:73 23:16 24:201',
          250: '1:87 2:29 3:188 4:79 5:62 20:65 21:14 22:66 23:14 24:69',
          777: '1:110 2:225 3:163 4:126 5:161 20:85 21:91 22:70 23:129 24:54',
          1999.5: '1:101 2:147 3:203 4:31 20:123 21:161 22:75 23:67 24:202',
          3100: '1:80 2:67 3:172 4:35 5:252 20:86 21:58 22:72 23:147 24:98',
          5432.1: '1:116 2:52 3:177 4:45 5:186 20:124 21:225 22:92 23:71 24:179',
        },
      );
    });

    test('the preview rounds an exact half up like the old page; the player rounds it to even', () {
      final tmp = Directory.systemTemp.createTempSync('sx_move_half_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final g = Directory(p.join(tmp.path, 'show', 'Editor', 'Generator', 'projects'))..createSync(recursive: true);
      File(p.join(tmp.path, 'show', 'fixtures.ini')).writeAsStringSync('[Fixture1]\naddress = 1\nid = 11\n');
      File(p.join(g.path, 'H.gpj')).writeAsStringSync(
        '[Params]\nPanTiltShift = 0.0\n[Fixture_0]\nID = 11\nName = A\nChannels = pan,upan,tilt,utilt\nReversePan = 0\nReverseTilt = 0\n'
        'OffsetPan = 0\nOffsetTilt = 0\nZoomPan = 0\nZoomTilt = 0\n[Pan/Tilt/uPan/uTilt]\nSelected = 1\nTransition = 0\nDuration = 40\nShift = 0\n'
        'Point_0 = 1,4\n',
      );
      final d = moveOpen(ShowEnv(p.join(tmp.path, 'show')), 'H.gpj');
      // Aimed 1.5 steps right: pan 2.5 and tilt 5.5 on the way out.
      final st = MoveState.of(d).withHead(0, const MoveHeadState(op: 1.5, ot: 1.5, zp: 0, zt: 0));
      expect(moveFrame(d, st, 0), {1: 0, 2: 3, 3: 0, 4: 6});
      expect(moveFrame(d, st, 0, player: true), {1: 0, 2: 2, 3: 0, 4: 6});
    });

    test('a save body holds only what differs from the file', () {
      final s = TestShow();
      addTearDown(s.dispose);
      final d = s.open('CRLF.gpj');
      var st = MoveState.of(d);
      expect(st.diff(d).isEmpty, isTrue);
      final i = d.secs.indexWhere((x) => x.name == pt);
      st = st.withSec(i, st.secs[i].copyWith(dur: 45, pts: [(1, 2), ...st.secs[i].pts.skip(1)])).withHead(1, st.heads[1].with_('op', -300));
      expect(st.diff(d).toJson(), {
        'move': 'CRLF.gpj',
        'sha': d.sha,
        'secs': [
          {
            'name': pt,
            'dur': 45,
            'pts': [
              [1, 2],
              [25000, 45000],
              [25000, 50000],
              [20000, 45000],
            ],
          },
        ],
        'heads': [
          {'k': 1, 'op': -300},
        ],
      });
      expect(moveWhat(st.diff(d)), 'Pan / Tilt: shape, cycle · 1 head aimed or sized');
      expect(s.save(st.diff(d).toJson()).$1, isTrue);
    });
  });

  group('PowerShell number and text habits', () {
    test('"\$x" of a JSON number', () {
      expect(
        [psText(45.0), psText(45), psText(6.25), psText(0.1 + 0.2), psText(1e20), psText(2 / 3 * 1e-7), psText(true), psText(null)],
        ['45', '45', '6.25', '0.3', '1E+20', '6.66666666666667E-08', 'True', ''],
      );
    });

    test('Shift is written with a decimal point and at most 4 decimals', () {
      // Values from the old Format-Num under PowerShell 7.7 (.NET 11).
      expect(
        [
          for (final v in [0.0, 6.25, 12.34565, 0.00005, 0.00015, 99.99999, 100.0, 1.5, 0.00025, 2.00005, 0.00045, 0.03125]) formatShift(v),
        ],
        ['0.0', '6.25', '12.3456', '0.0001', '0.0001', '100.0', '100.0', '1.5', '0.0003', '2.0', '0.0004', '0.0312'],
      );
    });

    test('[int]::TryParse and [double]::TryParse', () {
      expect([netInt(' 45 '), netInt('+7'), netInt('4.5'), netInt('1,000'), netInt('99999999999')], [45, 7, null, null, null]);
      expect([netDouble('6,25'), netDouble(' 1e2 '), netDouble('.5'), netDouble('5.')], [null, 100, .5, 5]);
    });

    test('lines keep their own endings', () {
      const s = 'a\r\nb\nc\rd';
      expect(splitLines(s), [('a', '\r\n'), ('b', '\n'), ('c', '\r'), ('d', '')]);
      expect(joinLines(splitLines(s)), s);
      expect(splitLines(''), isEmpty);
    });

    test('ConvertTo-Json layout of PowerShell 7', () {
      final j = jsonDecode('{"sx":1.2,"n":1,"d":5.0,"e":1e-7,"s":"a\\"b\\u0001","files":{"X.gpj":{"base":"1,1"}},"copied":{},"l":[],"m":[1,[2]]}');
      expect(
        psJsonPretty(j),
        '{\n  "sx": 1.2,\n  "n": 1,\n  "d": 5.0,\n  "e": 1E-07,\n  "s": "a\\"b\\u0001",\n  "files": {\n    "X.gpj": {\n      "base": "1,1"\n    }\n  },\n'
        '  "copied": {},\n  "l": [],\n  "m": [\n    1,\n    [\n      2\n    ]\n  ]\n}',
      );
    });
  });
}
