// Every check of the old `tools/test_looks.ps1`, on the same small test show,
// so they run anywhere. Then the template builder (`buildLook` in sx_api) on
// the same show.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _mv = 'Mover 140 (19ch)', _led = 'LED_BAR_CH8';
const _live = '[live]\r\nmaster_faders = 0\r\n';
const _old = '<?xml version="1.0" encoding="UTF-8"?>\n\n<Scene>\n  <Fixtures/>\n  <Steps/>\n</Scene>\n';

/// The old suite's test show: two 140-style movers (one with a name that needs
/// escaping), an LED bar with two sets of red/green/blue, a group of four
/// pars, and a hazer with no definition.
ShowEnv _testShow() {
  final tmp = Directory.systemTemp.createTempSync('sx_looks_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final t = p.join(tmp.path, 'Test Show');
  for (final d in ['scenes', 'fixtures', 'Live']) {
    Directory(p.join(t, d)).createSync(recursive: true);
  }
  void write(String rel, String text, {bool bom = false}) => File(p.join(t, rel)).writeAsBytesSync([
    if (bom) ...[0xEF, 0xBB, 0xBF],
    ...utf8.encode(text),
  ]);
  write(
    'fixtures/$_mv.txt',
    'ViewType = VIEW_TYPE_HEAD\r\n\r\nChannel = pan\r\n dimmer,0,255 \r\n\r\nChannel = tilt\r\n dimmer,0,255 \r\n\r\n'
        'Channel = color\r\n white,0,3 red,4,7 yellow,8,11 blue,12,15 index,16,127 right_rotate,128,255 \r\n\r\nChannel = gobo\r\n open,0,7 gobo1,8,15 \r\n\r\nChannel = gobo\r\n open,0,7 \r\n\r\n'
        'Channel = 8 facet prism\r\n no_function,0,7 8 facet prsim,8,12 right_rotate,13,130 left_rotate,131,247 \r\n\r\nChannel = zoom\r\n zoom,0,255 \r\n\r\n'
        'Channel = dimmer\r\n\r\nChannel = shutter\r\n closed,0,7 open,8,15 strobe,16,131 open,248,255 \r\n',
  );
  write(
    'fixtures/$_led.txt',
    'Channel = dimmer\r\n\r\nChannel = strobe\r\n no_function,0,5 strobe,6,255 \r\n\r\nChannel = red\r\n\r\nChannel = green\r\n\r\nChannel = blue\r\n\r\n'
        'Channel = red\r\n\r\nChannel = green\r\n\r\nChannel = blue\r\n',
  );
  write(
    'fixtures.ini',
    '\r\n[Fixture1]\r\naddress = 1\r\nname = Mover 140 (19ch)\r\nmodel = $_mv\r\nquantity = 1\r\nid = 101\r\n'
        '[Fixture2]\r\naddress = 20\r\nname = Mover <A&B> "2"\r\nmodel = $_mv\r\nquantity = 1\r\nid = 102\r\n'
        '[Fixture3]\r\naddress = 40\r\nname = LED BAR\r\nmodel = $_led\r\nquantity = 1\r\nid = 201\r\n'
        '[Fixture4]\r\naddress = 60\r\nname = PARS\r\nmodel = $_led\r\nquantity = 4\r\nid = 301\r\n'
        '[Fixture5]\r\naddress = 100\r\nname = HAZER\r\nmodel = NO DEFINITION\r\nquantity = 1\r\nid = 401\r\n',
    bom: true,
  );
  write('Live/live.ini', _live);
  write('scenes/OLD.scex', _old);
  return ShowEnv(t);
}

/// The page's own JSON, as it sends it.
String _make(ShowEnv env, String json) => looksMake(env, LookDraft.fromJson((jsonDecode(json) as Map).cast<String, Object?>()));

File _scene(ShowEnv env, String name) => env.file('scenes/$name');

const _look =
    '{"name":"MY LOOK.scex","steps":[{"len":100,"f":{"102":[[2,6],[7,255],[8,255]],"201":[[0,255],[1,0],[2,255,1],[3,0,1],[4,0,1],[5,255,1],[6,0,1],[7,0,1]],"101":[[2,14],[7,255],[8,255]]}},'
    '{"len":8,"f":{"101":[[2,6],[7,0],[8,0]],"102":[[2,14],[7,0],[8,0]],"201":[[0,0],[1,0],[2,0,1],[3,0,1],[4,255,1],[5,0,1],[6,0,1],[7,255,1]]}}]}';

void main() {
  group('Rig', () {
    late LookRig g;
    setUp(() => g = looksRig(_testShow()));

    test('the single heads, in fixtures.ini order', () => expect([for (final h in g.heads) h.id], ['101', '102', '201']));

    test('a group of 4 and a head with no definition are left out, by name', () => expect(g.skipped, ['PARS', 'HAZER']));

    test('a repeated channel name gets #2 (as ShowXpress writes it)', () {
      expect([for (final c in g.models[_mv]!.chans) c.name], ['pan', 'tilt', 'color', 'gobo', 'gobo#2', '8 facet prism', 'zoom', 'dimmer', 'shutter']);
    });

    test('colour wheel slots up to the index range', () {
      final c = g.models[_mv]!;
      expect(c.wheel, 2);
      expect([for (final s in c.slots) '${s.n}=${s.v}'], ['white=2', 'red=6', 'yellow=10', 'blue=14']);
    });

    test('shutter open 255 / closed 0, dimmer', () {
      final c = g.models[_mv]!;
      expect((c.shut!.ix, c.shut!.open, c.shut!.closed, c.dim), (8, 255, 0, 7));
    });

    test('prism with its spin ranges, both gobos, zoom', () {
      final c = g.models[_mv]!;
      expect(c.prisms, hasLength(1));
      expect((c.prisms[0].ix, c.prisms[0].l, c.zoom), (5, (131, 247), 6));
      expect(c.gobos, [3, 4]);
      // "8 facet prsim,8,12": [int](21 / 2) is 10, halves to even
      expect(c.prisms[0].on, 10);
    });

    test('an LED head - every red / green / blue, the strobe kept at no_function', () {
      final l = g.models[_led]!;
      expect((l.wheel, l.shut), (-1, null));
      expect(l.rgb['red'], [2, 5]);
      expect(l.kill, [(1, 0)]);
    });

    test('lists the scenes already in the show', () => expect(g.scenes, contains('OLD.scex')));

    test('every model of fixtures.ini is described, even one without a definition', () {
      expect(g.models.keys, [_mv, _led, 'NO DEFINITION']);
      expect(g.models['NO DEFINITION']!.chans, isEmpty);
    });
  });

  group('Make', () {
    late ShowEnv env;
    setUp(() => env = _testShow());

    test('writes a new scene', () {
      final out = _make(env, _look);
      expect(_scene(env, 'MY LOOK.scex').existsSync(), isTrue);
      expect(jsonDecode(const LineSplitter().convert(out).last), {'made': 'MY LOOK.scex'});
      expect(out, startsWith('  Made the scene MY LOOK: 2 steps, 3 heads, 1.08 s.\n'));
    });

    group('the file', () {
      late List<int> b;
      late String txt;
      late XmlElement x;
      setUp(() {
        _make(env, _look);
        b = _scene(env, 'MY LOOK.scex').readAsBytesSync();
        txt = utf8.decode(b);
        x = XmlDocument.parse(txt).rootElement;
      });
      List<XmlElement> steps() => x.findElements('Steps').expand((s) => s.findElements('Step')).toList();

      test('written like ShowXpress: UTF-8 with no BOM, LF only, the XML header and a blank line', () {
        expect(b[0], isNot(0xEF));
        expect(txt, isNot(contains('\r')));
        expect(txt, startsWith('<?xml version="1.0" encoding="UTF-8"?>\n\n<Scene>\n  <Fixtures>\n'));
      });

      test('fixtures in fixtures.ini order, names and models as in the show (escaped)', () {
        final fx = x.findElements('Fixtures').single.findElements('Fixture').toList();
        expect([for (final f in fx) f.getAttribute('id')], ['101', '102', '201']);
        expect(fx[1].getAttribute('name'), 'Mover <A&B> "2"');
        expect(fx[2].getAttribute('model'), _led);
        expect(txt, contains('name="Mover &lt;A&amp;B&gt; &quot;2&quot;"'));
      });

      test('steps and their times', () => expect([for (final s in steps()) s.getAttribute('length')], ['100', '8']));

      test('channels sorted, named from the definition (#2 for the second red)', () {
        final f = steps()[0].findElements('Fixture').toList()[2];
        expect(
          [for (final c in f.findElements('Channel')) '${c.getAttribute('index')}:${c.getAttribute('name')}'],
          [
            '0:dimmer', '1:strobe', '2:red', '3:green', '4:blue', '5:red#2', '6:green#2', '7:blue#2', //
          ],
        );
      });

      test('values and fade="1" where asked', () {
        final ch = steps()[0].findElements('Fixture').toList()[2].findElements('Channel').toList();
        expect((ch[2].getAttribute('value'), ch[2].getAttribute('fade'), ch[0].getAttribute('fade')), ('255', '1', null));
        expect(steps()[1].findElements('Fixture').first.findElements('Channel').first.getAttribute('value'), '6');
      });

      test('the text has one line per channel, ShowXpress style', () {
        expect(txt, contains('\n        <Channel index="2" name="red" value="255" fade="1"/>\n'));
      });

      test('live.ini and the other scenes are untouched', () {
        expect(env.file('Live/live.ini').readAsStringSync(), _live);
        expect(_scene(env, 'OLD.scex').readAsStringSync(), _old);
      });
    });

    test('an existing scene is never overwritten', () {
      _make(env, _look);
      String sha() => sha256.convert(_scene(env, 'MY LOOK.scex').readAsBytesSync()).toString();
      final before = sha();
      expect(() => _make(env, _look), _refused(contains('already in the show')));
      expect(sha(), before);
    });

    // The old tool passes this on Windows and the Mac only: on Linux its
    // Test-Path sees no "old.scex" and writes one next to OLD.scex.
    test('not even with other capitals (OLD.scex)', () {
      expect(
        () => _make(env, _look.replaceAll('MY LOOK', 'old')),
        _refused("A scene called 'old' is already in the show. Pick another name - NOTHING was changed."),
      );
      expect(_scene(env, 'OLD.scex').readAsStringSync(), _old);
      expect([for (final f in Directory(env.path('scenes')).listSync()) p.basename(f.path)], ['OLD.scex']);
    });

    for (final (what, json, message) in [
      ('a head not in the show', '{"name":"B1.scex","steps":[{"len":10,"f":{"999":[[0,1]]}}]}', "Head 999 isn't in the show's fixtures. NOTHING was changed."),
      (
        'a head of a group (no id of its own)',
        '{"name":"B2.scex","steps":[{"len":10,"f":{"301":[[0,1]]}}]}',
        "Head 301 isn't in the show's fixtures. NOTHING was changed.",
      ),
      (
        'a channel the head does not have',
        '{"name":"B3.scex","steps":[{"len":10,"f":{"101":[[9,1]]}}]}',
        'Head Mover 140 (19ch) has no channel 9. NOTHING was changed.',
      ),
      ('a value over 255', '{"name":"B4.scex","steps":[{"len":10,"f":{"101":[[0,256]]}}]}', 'A channel value must be 0-255. NOTHING was changed.'),
      ('a step time of 0', '{"name":"B5.scex","steps":[{"len":0,"f":{"101":[[0,1]]}}]}', "A step's time must be 0.01 s to 1 hour. NOTHING was changed."),
      (
        'steps with different channels',
        '{"name":"B6.scex","steps":[{"len":10,"f":{"101":[[0,1]]}},{"len":10,"f":{"101":[[1,1]]}}]}',
        'Every step of a look must set the same heads and channels. NOTHING was changed.',
      ),
      (
        'steps with different heads',
        '{"name":"B7.scex","steps":[{"len":10,"f":{"101":[[0,1]]}},{"len":10,"f":{"102":[[0,1]]}}]}',
        'Every step of a look must set the same heads and channels. NOTHING was changed.',
      ),
      (
        'a channel twice',
        '{"name":"B8.scex","steps":[{"len":10,"f":{"101":[[0,1],[0,2]]}}]}',
        'Channel 0 of Mover 140 (19ch) is in a step twice. NOTHING was changed.',
      ),
      ('no steps', '{"name":"B9.scex","steps":[]}', 'The look has no steps. NOTHING was changed.'),
      (
        'a name with a folder in it',
        r'{"name":"..\\x.scex","steps":[{"len":10,"f":{"101":[[0,1]]}}]}',
        r"'..\x.scex' can't be a scene name. NOTHING was changed.",
      ),
      ('a name that is not a .scex', '{"name":"x.gpj","steps":[{"len":10,"f":{"101":[[0,1]]}}]}', "'x.gpj' can't be a scene name. NOTHING was changed."),
    ]) {
      test('refused: $what', () {
        expect(() => _make(env, json), _refused(message));
        expect(Directory(env.path('scenes')).listSync(), hasLength(1));
      });
    }

    test('a one-channel, one-step look (single-item lists)', () {
      _make(env, '{"name":"ONE.scex","steps":[{"len":500,"f":{"101":[[3,0]]}}]}');
      final x = XmlDocument.parse(_scene(env, 'ONE.scex').readAsStringSync());
      expect(x.findAllElements('Channel').single.getAttribute('name'), 'gobo');
    });

    test('no temp file left in scenes/', () {
      _make(env, _look);
      expect([for (final f in Directory(env.path('scenes')).listSync()) p.basename(f.path)]..sort(), ['MY LOOK.scex', 'OLD.scex']);
    });
  });

  test('the routes: the rig through the typed client, a nameless look refused', () async {
    final env = _testShow();
    final engine = Engine(
      EngineConfig(port: 0, token: 't', showPath: env.root),
      sx: const NoSxApp(),
    );
    await engine.start();
    final client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
    addTearDown(() async {
      client.close();
      await engine.stop();
    });
    final rig = await client.looks();
    expect(rig.models[_mv]!.prisms.single.l, (131, 247));
    final look = buildLook(rig, LookTemplate.prism, LookOptions());
    expect((await client.looksMake(look.draft(''))).error, 'Give the look a name.');
    final r = await client.looksMake(look.draft('PRISM FAN.scex'));
    expect(r.out, contains('Made the scene PRISM FAN: 1 step, 2 heads, 5 s.'));
  });

  group('templates', () {
    late ShowEnv env;
    late LookRig rig;
    setUp(() {
      env = _testShow();
      rig = looksRig(env);
    });

    test('contrast pairs: every other head, the colors swap each step', () {
      final o = LookOptions()..pairs.removeRange(1, 4);
      final l = buildLook(rig, LookTemplate.contrast, o);
      expect(l.steps.map((s) => s.len), [100, 100]);
      // movers on the wheel (red slot 6, blue slot 14), the LED bar on its LEDs
      expect(l.steps[0].f['101']!.first, [2, 6, 0]);
      expect(l.steps[0].f['102']!.first, [2, 14, 0]);
      expect(l.steps[1].f['101']!.first, [2, 14, 0]);
      expect(lookAutoName(LookTemplate.contrast, o, rig.scenes), 'CONTRAST RED BLUE');
      expect(_make(env, jsonEncode(l.draft('CONTRAST RED BLUE.scex').toJson())), contains('2 steps, 3 heads, 2 s.'));
    });

    test('strobe on the beat: an 8/100 s flash, then 60 s dark', () {
      final l = buildLook(rig, LookTemplate.strobe, LookOptions());
      expect(l.beat, isTrue);
      expect([for (final s in l.steps) s.len], [8, 6000]);
      // the LED bar: LEDs in channel order, then the dimmer, then the strobe kept at no_function
      expect(l.steps[0].f['201'], [
        [2, 255, 0], [3, 255, 0], [4, 255, 0], [5, 255, 0], [6, 255, 0], [7, 255, 0], [0, 255, 0], [1, 0, 0], //
      ]);
      expect(l.steps[1].f['101'], [
        [2, 2, 0], [7, 0, 0], [8, 0, 0], //
      ]);
      expect(l.steps[1].show['101'], isNull);
    });

    test('colour chase goes back and forth, 1..n..2', () {
      final o = LookOptions()
        ..cols.setAll(0, ['Red', 'Yellow', 'Blue'])
        ..cols.removeRange(3, 8);
      final l = buildLook(rig, LookTemplate.chase, o);
      expect([for (final s in l.steps) s.f['101']!.first[1]], [6, 10, 14, 10]);
      expect(l.steps.first.len, 50);
    });

    test('prism fan: gobos open, prism spinning, zoom, lit', () {
      final l = buildLook(rig, LookTemplate.prism, LookOptions());
      // spin left at 77: 131 + (247 - 131) * 0.77 = 220.32
      expect(l.steps.single.f['101'], [
        [3, 0, 0], [4, 0, 0], [5, 220, 0], [6, 80, 0], [7, 255, 0], [8, 255, 0], //
      ]);
      expect(l.steps.single.f.keys, ['101', '102'], reason: 'the LED bar has no prism');
    });

    test('nothing to build with', () {
      final o = LookOptions()..on[LookTemplate.prism]![_mv] = false;
      expect(buildLook(rig, LookTemplate.prism, o).err, 'Pick the lights for the look (HEADS).');
      expect(buildLook(rig, LookTemplate.chase, LookOptions()..cols.removeRange(1, 8)).err, 'Pick at least 2 colours.');
    });

    test('names: unique among the scenes, cleaned like a file name', () {
      expect(lookAutoName(LookTemplate.prism, LookOptions(), ['PRISM FAN.scex', 'prism fan 2.SCEX']), 'PRISM FAN 3');
      expect(lookCleanName('  My: "look"  .scex'), 'My look');
      // like the old page: ".scex" only comes off the very end
      expect(lookCleanName('My look .scex.'), 'My look .scex');
      expect(lookNameTaken('old', rig.scenes), isTrue);
    });
  });
}

Matcher _refused(Object message) => throwsA(isA<ToolError>().having((e) => e.message, 'message', message));
