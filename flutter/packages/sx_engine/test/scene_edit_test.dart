// The Scene Editor's rules, on a small made-up show. Port of the old tool's
// own suite, `tools/test_scene_edit.ps1`, check for check, plus the cases the
// port fixes or adds. Runs anywhere: no PowerShell, no real show.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

const _m = 'Intimidator Hybrid 140SR (19ch)';
const _crlf = '\r\n';

final _chase = [
  '<?xml version="1.0" encoding="UTF-8"?>',
  '',
  '<Scene>',
  '  <Fixtures>',
  '    <Fixture id="11" name="140 #1" model="$_m"/>',
  '    <Fixture id="12" name="140 #2" model="$_m"/>',
  '  </Fixtures>',
  '  <Steps>',
  '    <Step length="50">',
  '      <Fixture id="11">',
  '        <Channel index="5" name="color" value="10" fade="1"/>',
  '        <Channel index="15" name="dimmer" value="255"/>',
  '      </Fixture>',
  '      <Fixture id="12">',
  '        <Channel index="5" name="color" value="0"/>',
  '        <Channel index="15" name="dimmer" value="0"/>',
  '      </Fixture>',
  '    </Step>',
  '    <Step length="50">',
  '      <Fixture id="11">',
  '        <Channel index="5" name="color" value="10"/>',
  '        <Channel index="15" name="dimmer" value="0"/>',
  '      </Fixture>',
  '      <Fixture id="12">',
  '        <Channel index="5" name="color" value="20" fade="1"/>',
  '        <Channel index="15" name="dimmer" value="255"/>',
  '      </Fixture>',
  '    </Step>',
  '    <Step length="25">',
  '      <Fixture id="11">',
  '        <Channel index="5" name="color" value="0"/>',
  '        <Channel index="15" name="dimmer" value="0"/>',
  '      </Fixture>',
  '      <Fixture id="12">',
  '        <Channel index="5" name="color" value="0"/>',
  '        <Channel index="15" name="dimmer" value="0"/>',
  '      </Fixture>',
  '    </Step>',
  '  </Steps>',
  '</Scene>',
  '',
].join(_crlf);

// things the editor doesn't know: extra attributes, an unknown tag in a step, a comment, single quotes, odd spacing
const _odd =
    '<?xml version="1.0" encoding="UTF-8"?>\n<Scene version="9.4.7" flags=\'x\'>\n  <Fixtures>\n    <Fixture id="11" name="140 #1" model="$_m" extra="keep me"/>\n  </Fixtures>\n  <Steps speed="1">\n'
    '    <Step length="100" note="a &amp; b">\n      <Fixture id="11" x="1">\n        <!-- keep this -->\n        <Channel index="5" name="color" value = \'20\'  curve="2" />\n        <Channel   index="15"   name="dimmer"   value="200"/>\n      </Fixture>\n      <Unknown a="b"><Deep/></Unknown>\n    </Step>\n'
    '    <Step>\n      <Fixture id="11">\n        <Channel index="5" name="color" value="0" fade="0"/>\n        <Channel index="15" name="dimmer" value="0"/>\n      </Fixture>\n    </Step>\n  </Steps>\n  <Other>text</Other>\n</Scene>';

const _between =
    '<?xml version="1.0" encoding="UTF-8"?>\n<Scene>\n  <Fixtures>\n    <Fixture id="11" name="140 #1" model="$_m"/>\n  </Fixtures>\n  <Steps>\n    <Step length="10">\n      <Fixture id="11">\n        <Channel index="15" name="dimmer" value="9"/>\n      </Fixture>\n    </Step>\n    <Marker/>\n    <Step length="20">\n      <Fixture id="11">\n        <Channel index="15" name="dimmer" value="8"/>\n      </Fixture>\n    </Step>\n  </Steps>\n</Scene>\n';

const _selfStep =
    '<?xml version="1.0" encoding="UTF-8"?>\r\n<Scene>\r\n  <Fixtures>\r\n    <Fixture id="11" name="140 #1" model="$_m"/>\r\n  </Fixtures>\r\n  <Steps>\r\n    <Step length="10"/>\r\n    <Step length="30">\r\n      <Fixture id="11">\r\n        <Channel index="15" name="dimmer" value="1"/>\r\n      </Fixture>\r\n    </Step>\r\n  </Steps>\r\n</Scene>\r\n';

/// The old suite's test show, in a fresh temp folder.
class _Show {
  _Show() {
    tmp = Directory.systemTemp.createTempSync('sx_scene_test_');
    root = p.join(tmp.path, 'Test Show');
    for (final d in ['scenes', 'Live', 'fixtures']) {
      Directory(p.join(root, d)).createSync(recursive: true);
    }
    File(p.join(root, 'fixtures.ini')).writeAsStringSync(
      '[Fixture1]\r\nname = 140 #1\r\nmodel = $_m\r\naddress = 1\r\nid = 11\r\n\r\n[Fixture2]\r\nname = 140 #2\r\nmodel = $_m\r\naddress = 20\r\nid = 12\r\n\r\n[Fixture3]\r\nname = UPLIGHT\r\naddress = 513\r\nid = 30\r\n',
    );
    File(
      p.join(root, 'fixtures', '$_m.txt'),
    ).writeAsStringSync('Channel = color\r\nWhite,0,9,Red,10,19,Green,20,29\r\n\r\nChannel = shutter\r\nClosed,0,7,Open,8,15\r\n');
    File(p.join(root, 'Live', 'live.ini')).writeAsBytesSync([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(
        '[live]\r\nmaster_faders = 0\r\n\r\n[page1]\r\nname = CHASES\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CHASE.scex\r\ntitle = CHASE\r\n',
      ),
    ]);
    write('CHASE.scex', _chase, bom: true);
    write('ODD.scex', _odd);
    write('BETWEEN.scex', _between);
    write('SELFSTEP.scex', _selfStep);
    write('BROKEN.scex', '<?xml version="1.0"?>\n<Scene>\n  <Steps>\n    <Step length="10">\n  </Steps>\n</Scene>\n');
    final u16 = <int>[0xFF, 0xFE];
    for (final c in _chase.codeUnits) {
      u16.addAll([c & 0xFF, c >> 8]);
    }
    File(p.join(root, 'scenes', 'UTF16.scex')).writeAsBytesSync(u16);
    write('NOSTEPS.scex', '<?xml version="1.0"?>\n<Scene>\n  <Fixtures/>\n  <Steps/>\n</Scene>\n');
  }

  late final Directory tmp;
  late final String root;
  var _tick = 0;

  /// Each call is a millisecond later, so backups never share a name.
  late final env = ShowEnv(root, now: () => DateTime(2026, 11, 24, 21, 0, 0, _tick++));
  String get backups => p.join(tmp.path, 'scene_backups');

  void write(String f, String text, {bool bom = false}) => File(p.join(root, 'scenes', f)).writeAsBytesSync([
    if (bom) ...const [0xEF, 0xBB, 0xBF],
    ...utf8.encode(text),
  ]);
  List<int> bytes(String f) => File(p.join(root, 'scenes', f)).readAsBytesSync();
  String txt(String f) {
    final b = bytes(f);
    return utf8.decode(b.length >= 3 && b[0] == 0xEF ? b.sublist(3) : b);
  }

  String sha(String f) => sha256.convert(bytes(f)).toString();

  /// Every file in the show, to its sha.
  Map<String, String> all() => {
    for (final f in Directory(root).listSync(recursive: true).whereType<File>()) f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };

  SceneOpen open(String f) => sceneOpen(env, f, backupBase: backups);

  /// A save, as the route runs it: the report, or the refusal as `ERR:...`.
  String save(String scene, String sha, List<SceneStepChange> steps, {List<SceneChannelRef> addch = const [], List<SceneChannelRef> delch = const []}) {
    try {
      return sceneSave(
        env,
        SceneChanges(scene: scene, sha: sha, steps: steps, addch: addch, delch: delch),
        backupBase: backups,
      );
    } on ToolError catch (e) {
      return 'ERR:${e.message}';
    }
  }
}

List<SceneStepChange> _steps(int k) => [for (var i = 0; i < k; i++) SceneStepChange(src: i)];

SceneSet _set(String fx, int ix, {int? v, bool? fade}) => SceneSet(fx: fx, ix: ix, v: v, fade: fade);

void main() {
  // The old suite runs its checks in order on one show; so do these.
  late _Show t;
  setUpAll(() => t = _Show());
  tearDownAll(() => t.tmp.deleteSync(recursive: true));

  group('reading', () {
    test('editable scenes read back byte for byte, broken ones are left alone', () {
      final c = sceneCheck(t.env);
      final ed = {for (final s in c.scenes) s.file: s};
      for (final f in ['CHASE.scex', 'ODD.scex', 'BETWEEN.scex', 'SELFSTEP.scex']) {
        expect(ed[f]!.editable && ed[f]!.same && ed[f]!.selfCheck, isTrue, reason: '$f (${ed[f]!.why})');
      }
      for (final f in ['BROKEN.scex', 'UTF16.scex', 'NOSTEPS.scex']) {
        expect(ed[f]!.editable, isFalse, reason: f);
      }
      expect(ed['UTF16.scex']!.why, 'the file is not plain UTF-8 text');
      expect(ed['NOSTEPS.scex']!.why, 'it has no steps');
      expect(c.bad, isEmpty);
    });

    test('BETWEEN.scex: steps can be changed but not moved', () {
      final b = sceneCheck(t.env).scenes.firstWhere((s) => s.file == 'BETWEEN.scex');
      expect(b.editable && !b.structural, isTrue);
    });

    test('List: steps, heads and the button that uses it', () {
      final ch = sceneList(t.env).scenes.firstWhere((s) => s.file == 'CHASE.scex');
      expect((ch.steps, ch.heads), (3, 2));
      expect(ch.used, ['CHASES: CHASE']);
    });

    test('Open: steps, heads, DMX addresses, channel names, named ranges', () {
      final o = t.open('CHASE.scex');
      expect(o.steps, hasLength(3));
      expect(o.heads![1].addr, 20);
      expect(o.models![_m]!.chans, hasLength(2));
      expect(o.models![_m]!.ranges['color']![1].n, 'red');
    });

    test('Open: values and fades', () {
      final ch = t.open('CHASE.scex').steps![0].fx[0].ch;
      expect((ch[0].v, ch[0].fade, ch[1].fade), (10, true, false));
    });

    test('Open: a scene it can not read says why', () {
      final o = t.open('BROKEN.scex');
      expect(o.readonly, "its <Steps> tags don't match up");
      expect(o.steps, isNull);
    });

    test('Open: only scene files in scenes/', () {
      expect(() => t.open(r'..\fixtures.ini'), throwsA(isA<ToolError>()));
      expect(() => t.open('../x.scex'), throwsA(isA<ToolError>()));
      expect(() => t.open('.hidden.scex'), throwsA(isA<ToolError>()));
    });
  });

  group('saving', () {
    late Map<String, String> before;
    late SceneOpen o;
    late String s0;
    setUpAll(() {
      before = t.all();
      o = t.open('CHASE.scex');
    });

    test('Save with no changes writes nothing', () {
      expect(t.save('CHASE.scex', o.sha, _steps(3)), contains('nothing to change'));
      expect(t.sha('CHASE.scex'), o.sha);
    });

    test('One value changed = only that value in the file', () {
      final r = t.save('CHASE.scex', o.sha, [
        SceneStepChange(src: 0, set: [_set('12', 15, v: 128)]),
        const SceneStepChange(src: 1),
        const SceneStepChange(src: 2),
      ]);
      final exp = _chase.replaceFirst(
        '<Channel index="15" name="dimmer" value="0"/>\r\n      </Fixture>\r\n    </Step>\r\n    <Step length="50">',
        '<Channel index="15" name="dimmer" value="128"/>\r\n      </Fixture>\r\n    </Step>\r\n    <Step length="50">',
      );
      expect(r, startsWith('  CHANGED  CHASE: 1 value(s)'));
      expect(t.txt('CHASE.scex'), exp);
    });

    test('The BOM is kept', () => expect(t.bytes('CHASE.scex').sublist(0, 3), [0xEF, 0xBB, 0xBF]));

    test('No other file in the show changed', () {
      final after = t.all();
      expect([
        for (final k in before.keys)
          if (!k.endsWith('CHASE.scex') && after[k] != before[k]) k,
      ], isEmpty);
    });

    test('A save from an old copy is refused (the file changed since)', () {
      expect(t.save('CHASE.scex', o.sha, _steps(3)), contains('changed since'));
    });

    test('Step length, fade on and fade off', () {
      o = t.open('CHASE.scex');
      final cur = t.txt('CHASE.scex');
      final r = t.save('CHASE.scex', o.sha, [
        SceneStepChange(src: 0, len: 75, set: [_set('11', 5, fade: false), _set('11', 15, fade: true)]),
        const SceneStepChange(src: 1),
        const SceneStepChange(src: 2),
      ]);
      final exp = cur.replaceFirst(
        '<Step length="50">$_crlf      <Fixture id="11">$_crlf        <Channel index="5" name="color" value="10" fade="1"/>$_crlf        <Channel index="15" name="dimmer" value="255"/>',
        '<Step length="75">$_crlf      <Fixture id="11">$_crlf        <Channel index="5" name="color" value="10"/>$_crlf        <Channel index="15" name="dimmer" value="255" fade="1"/>',
      );
      expect(r, contains('CHANGED'));
      expect(t.txt('CHASE.scex'), exp);
    });

    test('Steps moved, copied and taken out - each step exactly as it was', () {
      o = t.open('CHASE.scex');
      final cur = t.txt('CHASE.scex');
      final sc = RegExp(r'\r\n    <Step[\s\S]*?</Step>').allMatches(cur).toList();
      final head = cur.substring(0, sc[0].start), tail = cur.substring(sc[2].end);
      final r = t.save('CHASE.scex', o.sha, [
        const SceneStepChange(src: 2),
        const SceneStepChange(src: 0),
        SceneStepChange(src: 0, set: [_set('11', 15, v: 7)]),
      ]);
      final exp = head + sc[2][0]! + sc[0][0]! + sc[0][0]!.replaceFirst('value="255" fade="1"', 'value="7" fade="1"') + tail;
      expect(r, contains('steps moved, 1 value(s)'));
      expect(t.txt('CHASE.scex'), exp);
    });

    test('A channel that is already there is not added twice', () {
      o = t.open('CHASE.scex');
      final r = t.save(
        'CHASE.scex',
        o.sha,
        [
          SceneStepChange(src: 0, set: [_set('12', 15, v: 9, fade: true)]),
          const SceneStepChange(src: 1),
          const SceneStepChange(src: 2),
        ],
        addch: [const SceneChannelRef(fx: '12', ix: 15)],
        delch: [const SceneChannelRef(fx: '12', ix: 5)],
      );
      final t2 = t.txt('CHASE.scex');
      expect(r, contains('CHANGED'));
      expect('index="15"'.allMatches(t2), hasLength(6));
      expect('index="5"'.allMatches(t2), hasLength(3));
      expect(t2, contains('<Channel index="15" name="dimmer" value="9" fade="1"/>'));
    });

    test('A channel added to every step (its name from the show), set in one step', () {
      o = t.open('CHASE.scex');
      final cur = t.txt('CHASE.scex');
      final r = t.save(
        'CHASE.scex',
        o.sha,
        [
          SceneStepChange(src: 0, set: [_set('11', 5, v: 20, fade: true)]),
          const SceneStepChange(src: 1),
          const SceneStepChange(src: 2),
        ],
        addch: [const SceneChannelRef(fx: '11', ix: 5)],
      );
      var exp = cur.replaceAll(
        '      <Fixture id="11">\r\n        <Channel index="15"',
        '      <Fixture id="11">\r\n        <Channel index="5" name="color" value="0"/>\r\n        <Channel index="15"',
      );
      final i0 = exp.indexOf('<Channel index="5" name="color" value="0"/>');
      exp = exp.replaceRange(i0, i0 + 43, '<Channel index="5" name="color" value="20" fade="1"/>');
      expect(r, contains('1 channel(s) added'));
      expect(t.txt('CHASE.scex'), exp);
    });

    test('A channel taken out of every step (whole lines)', () {
      o = t.open('CHASE.scex');
      final cur = t.txt('CHASE.scex');
      final r = t.save('CHASE.scex', o.sha, _steps(3), delch: [const SceneChannelRef(fx: '11', ix: 5)]);
      final exp = cur.replaceAll(
        RegExp(
          r'\r\n        <Channel index="5" name="color" value="\d+"( fade="1")?/>(?=\r\n        <Channel index="15"[^\r]*\r\n      </Fixture>\r\n      <Fixture id="12">)',
        ),
        '',
      );
      expect(r, contains('1 channel(s) taken out'));
      expect(t.txt('CHASE.scex'), exp);
    });

    test('Tags, attributes, comments and spacing it does not know are kept', () {
      o = t.open('ODD.scex');
      final r = t.save('ODD.scex', o.sha, [
        SceneStepChange(src: 0, set: [_set('11', 5, v: 30, fade: true)]),
        SceneStepChange(src: 1, len: 40, set: [_set('11', 5, fade: false)]),
        const SceneStepChange(src: 0),
      ]);
      const s0 =
          '\n    <Step length="100" note="a &amp; b">\n      <Fixture id="11" x="1">\n        <!-- keep this -->\n        <Channel index="5" name="color" value = \'20\'  curve="2" />\n        <Channel   index="15"   name="dimmer"   value="200"/>\n      </Fixture>\n      <Unknown a="b"><Deep/></Unknown>\n    </Step>';
      const s1 =
          '\n    <Step>\n      <Fixture id="11">\n        <Channel index="5" name="color" value="0" fade="0"/>\n        <Channel index="15" name="dimmer" value="0"/>\n      </Fixture>\n    </Step>';
      final i1 = _odd.indexOf(s0), i2 = _odd.indexOf(s1) + s1.length;
      final exp =
          _odd.substring(0, i1) +
          s0.replaceFirst('value = \'20\'  curve="2"', 'value = \'30\'  curve="2" fade="1"') +
          s1.replaceFirst('<Step>', '<Step length="40">').replaceFirst(' fade="0"', '') +
          s0 +
          _odd.substring(i2);
      expect(r, contains('CHANGED'));
      expect(t.txt('ODD.scex'), exp);
    });

    test('No BOM added, line endings kept', () {
      expect(t.bytes('ODD.scex')[0], 0x3C);
      expect(t.txt('ODD.scex'), isNot(contains('\r')));
    });

    test('Steps with something unknown between them are not moved', () {
      o = t.open('BETWEEN.scex');
      expect(t.save('BETWEEN.scex', o.sha, const [SceneStepChange(src: 1), SceneStepChange(src: 0)]), contains('NOTHING was changed'));
      expect(t.txt('BETWEEN.scex'), _between);
    });

    test('...but their values can be changed', () {
      final r = t.save('BETWEEN.scex', o.sha, [
        const SceneStepChange(src: 0),
        SceneStepChange(src: 1, set: [_set('11', 15, v: 99)]),
      ]);
      expect(r, contains('CHANGED'));
      expect(t.txt('BETWEEN.scex'), _between.replaceFirst('value="8"', 'value="99"'));
    });

    test('An empty step (<Step/>) moves too', () {
      o = t.open('SELFSTEP.scex');
      final cur = t.txt('SELFSTEP.scex');
      final r = t.save('SELFSTEP.scex', o.sha, const [SceneStepChange(src: 1), SceneStepChange(src: 0, len: 15)]);
      expect(r, contains('CHANGED'));
      expect(
        t.txt('SELFSTEP.scex'),
        cur.replaceFirst('\r\n    <Step length="10"/>', '').replaceFirst('    </Step>\r\n  </Steps>', '    </Step>\r\n    <Step length="15"/>\r\n  </Steps>'),
      );
    });

    group('refused, nothing written', () {
      setUpAll(() {
        o = t.open('CHASE.scex');
        s0 = t.sha('CHASE.scex');
      });
      final cases = <String, (String, List<SceneStepChange> Function(), List<SceneChannelRef>)>{
        'no steps left': ('CHASE.scex', () => const [], const []),
        'a value over 255': (
          'CHASE.scex',
          () => [
            SceneStepChange(src: 0, set: [_set('11', 15, v: 300)]),
            const SceneStepChange(src: 1),
            const SceneStepChange(src: 2),
          ],
          const [],
        ),
        'a step that is not there': ('CHASE.scex', () => const [SceneStepChange(src: 9)], const []),
        'a head that is not in the scene': (
          'CHASE.scex',
          () => [
            SceneStepChange(src: 0, set: [_set('99', 15, v: 1)]),
            const SceneStepChange(src: 1),
            const SceneStepChange(src: 2),
          ],
          const [],
        ),
        'a channel with no name anywhere': ('CHASE.scex', () => _steps(3), const [SceneChannelRef(fx: '11', ix: 18)]),
        'a scene it can not read': ('BROKEN.scex', () => const [SceneStepChange(src: 0)], const []),
      };
      for (final MapEntry(key: what, value: (scene, steps, addch)) in cases.entries) {
        test('Refused: $what', () {
          final r = t.save(scene, scene == 'CHASE.scex' ? o.sha : '', steps(), addch: addch);
          expect(r, startsWith('ERR:'));
          expect(r, contains('NOTHING was changed'));
          expect(t.sha('CHASE.scex'), s0);
        });
      }
    });

    group('backups and revert', () {
      test('Every save kept a backup', () => expect(sceneBackups(t.env, 'CHASE.scex', backupBase: t.backups).backups, hasLength(6)));

      test('Revert of an old backup asks first (the scene was saved again since)', () {
        final first = sceneBackups(t.env, 'CHASE.scex', backupBase: t.backups).backups.last;
        final r = sceneRevert(t.env, 'CHASE.scex', first.id, backupBase: t.backups);
        expect(r.conflict, isTrue);
        expect(t.sha('CHASE.scex'), s0);
      });

      test('Revert puts the very first version back, byte for byte', () {
        final first = sceneBackups(t.env, 'CHASE.scex', backupBase: t.backups).backups.last;
        final r = sceneRevert(t.env, 'CHASE.scex', first.id, force: true, backupBase: t.backups);
        expect(r.out, contains('CHANGED'));
        expect(t.txt('CHASE.scex'), _chase);
        expect(t.bytes('CHASE.scex')[0], 0xEF);
      });

      test('...and that can be undone too', () {
        final newest = sceneBackups(t.env, 'CHASE.scex', backupBase: t.backups).backups.first;
        final r = sceneRevert(t.env, 'CHASE.scex', newest.id, backupBase: t.backups);
        expect(r.conflict, isFalse, reason: r.out);
        expect(t.sha('CHASE.scex'), s0);
      });

      test('No temp file left in scenes/', () {
        expect(Directory(p.join(t.root, 'scenes')).listSync().where((f) => p.basename(f.path).contains('tmp')), isEmpty);
      });
    });
  });

  group('beyond the old suite', () {
    late _Show s;
    setUp(() => s = _Show());
    tearDown(() => s.tmp.deleteSync(recursive: true));

    test('Only 20 backups are kept, the oldest go first', () {
      for (var i = 0; i < 22; i++) {
        final o = s.open('CHASE.scex');
        s.save('CHASE.scex', o.sha, [
          SceneStepChange(src: 0, set: [_set('11', 15, v: i)]),
          const SceneStepChange(src: 1),
          const SceneStepChange(src: 2),
        ]);
      }
      final b = sceneBackups(s.env, 'CHASE.scex', backupBase: s.backups).backups;
      expect(b, hasLength(maxSceneBackups));
      expect(Directory(p.join(s.backups, 'Test Show', 'CHASE.scex')).listSync(), hasLength(2 * maxSceneBackups));
      expect(b.first.id.compareTo(b.last.id), greaterThan(0));
    });

    test('A save refuses while ShowXpress is open', () {
      final env = ShowEnv(s.root, sxRunning: () => true);
      final o = s.open('CHASE.scex');
      expect(
        () => sceneSave(
          env,
          SceneChanges(scene: 'CHASE.scex', sha: o.sha, steps: _steps(3)),
          backupBase: s.backups,
        ),
        throwsA(isA<ToolError>()),
      );
    });

    // Fixed in the port (CLAUDE.md): the old tool left the scene saved when
    // the backup's info file could not be written. Now the scene goes back.
    test('If the backup info cannot be written, the scene is put back and the backup dropped', () {
      final o = s.open('CHASE.scex');
      final before = s.bytes('CHASE.scex');
      // the next backup's info file is taken by a folder, so writing it fails
      final dir = p.join(s.backups, 'Test Show', 'CHASE.scex');
      final env = ShowEnv(s.root, now: () => DateTime(2026, 1, 2, 3, 4, 5, 6));
      Directory(p.join(dir, '20260102-030405-006.json')).createSync(recursive: true);
      expect(
        () => sceneSave(
          env,
          SceneChanges(
            scene: 'CHASE.scex',
            sha: o.sha,
            steps: [
              SceneStepChange(src: 0, set: [_set('11', 15, v: 1)]),
              const SceneStepChange(src: 1),
              const SceneStepChange(src: 2),
            ],
          ),
          backupBase: s.backups,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(s.bytes('CHASE.scex'), before);
      expect(File(p.join(dir, '20260102-030405-006.scex')).existsSync(), isFalse);
    });

    // The old tool left the order of tags added at one place to Sort-Object's
    // ties: right on Windows PowerShell 5.1 for two tags, refused by its
    // self-check on PowerShell 7. The port always puts them in channel order.
    test('Channels added into the same gap come out in channel order, however many and in any order', () {
      const names = {1: 'one', 2: 'two', 3: 'three', 6: 'six', 7: 'seven', 8: 'eight'};
      s.write(
        'NAMES.scex',
        '<Scene><Fixtures><Fixture id="11" name="a" model="$_m"/></Fixtures><Steps><Step><Fixture id="11">'
            '${[for (final e in names.entries) '<Channel index="${e.key}" name="${e.value}" value="0"/>'].join()}</Fixture></Step></Steps></Scene>',
      );
      String line(int ix) => '        <Channel index="$ix" name="${names[ix]}" value="0"/>';
      // CHASE with the new lines around channel 5 of head 11, in every step
      String expected(List<int> before, List<int> after) {
        final lines = _chase.split(_crlf);
        return [
          for (final (i, l) in lines.indexed)
            if (i > 0 && lines[i - 1] == '      <Fixture id="11">') ...[...before.map(line), l, ...after.map(line)] else l,
        ].join(_crlf);
      }

      for (final (add, before, after) in [
        ([6, 7], <int>[], [6, 7]),
        ([7, 6], <int>[], [6, 7]),
        ([8, 6, 7], <int>[], [6, 7, 8]),
        ([7, 8, 6], <int>[], [6, 7, 8]),
        ([3, 1, 2], [1, 2, 3], <int>[]),
        ([8, 2, 6, 1, 7], [1, 2], [6, 7, 8]),
      ]) {
        s.write('CHASE.scex', _chase, bom: true);
        final o = s.open('CHASE.scex');
        final r = s.save(
          'CHASE.scex',
          o.sha,
          _steps(3),
          addch: [for (final ix in add) SceneChannelRef(fx: '11', ix: ix)],
        );
        expect(r, contains('CHANGED'), reason: '$add');
        expect(s.txt('CHASE.scex'), expected(before, after), reason: '$add');
      }
    });

    test('Channels added into the same gap of a one-line scene come out in channel order', () {
      s.write(
        'NAMES.scex',
        '<Scene><Fixtures><Fixture id="11" name="a" model="$_m"/></Fixtures><Steps><Step><Fixture id="11">'
            '<Channel index="6" name="six" value="0"/><Channel index="7" name="seven" value="0"/><Channel index="8" name="eight" value="0"/></Fixture></Step></Steps></Scene>',
      );
      s.write(
        'LINE.scex',
        '<Scene><Fixtures><Fixture id="11" name="140 #1" model="$_m"/></Fixtures><Steps><Step length="5"><Fixture id="11"><Channel index="5" name="color" value="1"/><Channel index="15" name="dimmer" value="2"/></Fixture></Step></Steps></Scene>',
      );
      final o = s.open('LINE.scex');
      final r = s.save(
        'LINE.scex',
        o.sha,
        _steps(1),
        addch: const [
          SceneChannelRef(fx: '11', ix: 8),
          SceneChannelRef(fx: '11', ix: 6),
          SceneChannelRef(fx: '11', ix: 7),
        ],
      );
      expect(r, contains('CHANGED'));
      expect(
        s.txt('LINE.scex'),
        '<Scene><Fixtures><Fixture id="11" name="140 #1" model="$_m"/></Fixtures><Steps><Step length="5"><Fixture id="11"><Channel index="5" name="color" value="1"/>'
        '<Channel index="6" name="six" value="0"/><Channel index="7" name="seven" value="0"/><Channel index="8" name="eight" value="0"/>'
        '<Channel index="15" name="dimmer" value="2"/></Fixture></Step></Steps></Scene>',
      );
    });

    test('Text that is not valid XML is left alone', () {
      for (final (bad, why) in [
        ('<Scene><Steps><Step a="1 & 2"/></Steps></Scene>', 'it is not valid XML'),
        ('<Scene><Steps><Step a="&nbsp;"/></Steps></Scene>', 'it is not valid XML'),
        ('<Scene><Steps><Step a="1" a="2"/></Steps></Scene>', 'it is not valid XML'),
        ('<Scene><Steps><Step/></Steps></Scene>x', 'it is not valid XML'),
        ('<Scene><Steps><x:Step/><Step/></Steps></Scene>', 'it is not valid XML'),
        ('<Other/>', 'it is not a scene file'),
        ('<Scene><Steps><Step/></Steps><Steps><Step/></Steps></Scene>', 'it has two lists of steps'),
        ('<Scene><Steps><Step/></Steps> < </Scene>', 'it has a "<" the editor does not understand'),
      ]) {
        s.write('X.scex', bad);
        expect(s.open('X.scex').readonly, why, reason: bad);
      }
    });

    test('A scene trimmed by Tonight\'s Rig says so, and a save notes it', () {
      final sha = textSha(s.txt('CHASE.scex'));
      File(p.join(s.root, 'rig_state.json')).writeAsStringSync(
        jsonEncode({
          'scenes': {
            'chase.scex': {'written': sha},
          },
        }),
      );
      final o = s.open('CHASE.scex');
      expect(o.trimmed, isTrue);
      expect(sceneList(s.env).scenes.firstWhere((x) => x.file == 'CHASE.scex').trimmed, isTrue);
      final r = s.save('CHASE.scex', o.sha, [
        SceneStepChange(src: 0, set: [_set('11', 15, v: 1)]),
        const SceneStepChange(src: 1),
        const SceneStepChange(src: 2),
      ]);
      expect(r, contains("NOTE  Tonight's Rig had trimmed this scene"));
      expect(s.open('CHASE.scex').trimmed, isFalse);
    });

    test('Through the engine, backups go to the engine\'s settings folder', () async {
      final settings = p.join(s.tmp.path, 'cfg');
      final engine = Engine(
        EngineConfig(port: 0, token: 't', showPath: s.root, settingsDir: settings),
        sx: _ClosedSx(),
      );
      await engine.start();
      final client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
      try {
        final o = await client.scene('CHASE.scex');
        final r = await client.sceneSave(
          SceneChanges(
            scene: 'CHASE.scex',
            sha: o.sha,
            steps: [
              SceneStepChange(src: 0, set: [_set('11', 15, v: 1)]),
              const SceneStepChange(src: 1),
              const SceneStepChange(src: 2),
            ],
            addch: const [],
            delch: const [],
          ),
        );
        expect(r.ok, isTrue, reason: r.error);
        final kept = Directory(p.join(settings, 'scene_backups', p.basename(s.root), 'CHASE.scex')).listSync();
        expect(kept, hasLength(2), reason: 'the scene as it was, and what the save did');
        expect((await client.sceneBackups('CHASE.scex')).backups, hasLength(1));
      } finally {
        client.close();
        await engine.stop();
      }
    });
  });
}

/// ShowXpress, never open.
class _ClosedSx implements SxApp {
  @override
  bool get running => false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}
