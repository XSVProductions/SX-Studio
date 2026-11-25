import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

/// The save time in tonights_color.json is the only thing allowed to differ.
final _savedInFile = RegExp(r'"saved": "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d"');

/// pwsh 7's ConvertFrom-Json turns the saved ISO time into a DateTime, and
/// "$(...)" prints that as `MM/dd/yyyy HH:mm:ss`. Windows PowerShell 5.1 and
/// the port keep the ISO text. Put the pwsh 7 form back to ISO to compare.
Object? _isoSaved(Object? j) {
  if (j is! Map) return j;
  final m = RegExp(r'^(\d\d)/(\d\d)/(\d{4}) (\d\d:\d\d:\d\d)$').firstMatch('${j['saved']}');
  return m == null ? j : {...j, 'saved': '${m[3]}-${m[1]}-${m[2]}T${m[4]}'};
}

final _maskSaved = ParityOptions(
  rewriteFile: (path, bytes) => path == 'tonights_color.json' ? utf8.encode(utf8.decode(bytes).replaceAll(_savedInFile, '"saved": "<time>"')) : bytes,
);

/// Takes out every live button that plays a TONIGHTS COLOR scene.
void _dropButtons(ShowEnv env) {
  final ini = LiveIni.read(env);
  final info = LiveInfo.read(env, ini);
  for (final b in info.buttons.where((b) => b.name.toUpperCase().startsWith('TONIGHTS COLOR'))) {
    final se = ini.findSection(b.sec)!;
    ini.lines.removeRange(se.$1, se.$2);
  }
  ini.save();
}

/// Renames a live page, so the tool can't find it.
void _renamePage(ShowEnv env, String from, String to) {
  final ini = LiveIni.read(env);
  final info = LiveInfo.read(env, ini);
  final pg = info.pages.entries.firstWhere((e) => e.value.trim() == from).key;
  ini.setKey('page$pg', 'name', to);
  ini.save();
}

void main() {
  // Pinned from the old tool (the sweep below checks the same maths against it on 743 colors).
  group('color maths', () {
    test('nearest wheel slot, compared at full brightness', () {
      String pick(List<WheelColor> w, String x) => nearestWheel(w, x)!.name;
      expect(
        [
          for (final x in ['f4a6b8', '0a1a6e', '8b0a2a', '00a8a8', 'ffffff']) pick(wheel140, x),
        ],
        ['Natural white', 'Blue', 'Red', 'Pastel sky blue', 'White'],
      );
      expect(
        [
          for (final x in ['f4a6b8', '0a1a6e', '8b0a2a', '00a8a8', 'ffffff']) pick(wheel251, x),
        ],
        ['CTO (warm)', 'Blue', 'Red', 'Cyan', 'White'],
      );
      // black has no hue: every channel is 0 at full brightness too, and blue is closest
      expect(pick(wheel140, '000000'), 'Blue');
    });

    test('uplight mix with a white LED', () {
      // the user's tuned BLUSH: lots of white, blue pulled up
      expect(washMix('f4a6b8', hasWhite: true), {'dimmer': 244, 'red': 255, 'green': 0, 'blue': 137, 'white': 222});
      expect(washMix('8b0a2a', hasWhite: true), {'dimmer': 139, 'red': 255, 'green': 0, 'blue': 69, 'white': 32});
      expect(washMix('ffffff', hasWhite: true), {'dimmer': 255, 'red': 0, 'green': 0, 'blue': 0, 'white': 255});
      expect(washMix('000000', hasWhite: true), {'dimmer': 0, 'red': 0, 'green': 0, 'blue': 0, 'white': 0});
    });

    test('uplight mix without a white LED rounds halves to even', () {
      expect(washMix('f4a6b8', hasWhite: false), {'dimmer': 244, 'red': 255, 'green': 173, 'blue': 192, 'white': 0});
      // 1 * 255 / 6 = 42.5, which [Math]::Round makes 42
      expect(washMix('010006', hasWhite: false)['red'], 42);
    });

    test('uplight channels: effects and strobes held at 0, others left out', () {
      expect(washValues('ff0000', ['dimmer', 'red', 'green', 'blue', 'white', 'amber', 'uv', 'strobe_dimmer', 'auto_focus', 'animation_speed']), [
        (0, 'dimmer', 255), (1, 'red', 255), (2, 'green', 0), (3, 'blue', 0), (4, 'white', 0), (5, 'amber', 0), (6, 'uv', 0), (7, 'strobe_dimmer', 0), //
      ]);
    });
  });

  // The one allowed difference from the old tool: it wrote each file straight
  // away, so a failure part way left the show half changed.
  group('writes all or nothing', () {
    late ShowEnv env;
    setUp(() {
      final t = Directory.systemTemp.createTempSync('sx_color_');
      addTearDown(() => t.deleteSync(recursive: true));
      void write(String rel, String text) => (File('${t.path}/$rel')..parent.createSync(recursive: true)).writeAsStringSync(text);
      write('Live/live.ini', '[page1]\r\nname = MOVER COLORS\r\nnb_buttons = 0\r\n[page2]\r\nname = UPLIGHTS\r\nnb_buttons = 0\r\n');
      write('fixtures.ini', '[Fixture1]\r\nid = 1\r\naddress = 1\r\n[Fixture2]\r\nid = 2\r\naddress = 20\r\n');
      write('fixtures/UPLIGHT.txt', 'Channel = dimmer\r\nChannel = red\r\nChannel = green\r\nChannel = blue\r\n');
      write(
        'scenes/CENTER SPOT.scex',
        '<Scene>\n  <Fixtures>\n    <Fixture id="1" name="140 #1" model="$model140"/>\n    <Fixture id="2" name="UPLIGHT" model="UPLIGHT"/>\n  </Fixtures>\n</Scene>\n',
      );
      env = ShowEnv(t.path);
    });

    Map<String, String> files() => {
      for (final f in Directory(env.root).listSync(recursive: true).whereType<File>())
        f.path.substring(env.root.length + 1).replaceAll(r'\', '/'): f.readAsStringSync(),
    };

    test('a failed last write puts the scenes and live.ini back', () {
      final before = files();
      Directory(env.path('tonights_color.json')).createSync(); // the state can't be written
      expect(() => colorApply(env, 'ff0000'), throwsA(isA<FileSystemException>()));
      expect({...files()}..remove('tonights_color.json.sxtmp'), before);
    });

    test('a good run writes the scenes, both buttons and the state', () {
      final out = colorApply(env, 'ff0000', name: 'Red');
      expect(out, contains('added the TONIGHTS COLOR button to the UPLIGHTS page (line 1, column 1)'));
      expect(files().keys, containsAll(['scenes/TONIGHTS COLOR MOVERS.scex', 'scenes/TONIGHTS COLOR UPLIGHT.scex', 'tonights_color.json']));
      expect(files().keys.where((k) => k.endsWith('.sxtmp')), isEmpty);
    });

    test('the routes check the color, clean the name, and queue with the hex in the label', () async {
      final sx = _FakeSx();
      final engine = Engine(
        EngineConfig(port: 0, token: 't', showPath: env.root),
        sx: sx,
      );
      await engine.start();
      final client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
      addTearDown(() async {
        client.close();
        await engine.stop();
      });
      expect((await client.colorApply('nope', '')).error, 'Pick a colour first.');
      expect((await client.color()).buttons.map((b) => b.there), [false, false]);
      final r = await client.colorApply('#FF0000', ' Red <b>"x"</b>, and a much longer name than fits ');
      expect(r.ok, isTrue, reason: r.error);
      final p = await client.color();
      expect((p.hex, p.name), ('ff0000', 'Red bxb and a much longer name'));
      expect(p.buttons.map((b) => b.there), [true, true]);
      sx.running = true;
      // the page asks to queue once it has seen ShowXpress open
      await client.status();
      final q = await client.colorApply('#00A8A8', 'Teal');
      expect((q.extra['queued'], q.extra['label']), (true, "Tonight's Color (#00a8a8)"));
    });

    test('refuses while ShowXpress is open', () {
      final before = files();
      expect(() => colorApply(ShowEnv(env.root, sxRunning: () => true), 'ff0000'), throwsA(isA<ToolError>()));
      expect(files(), before);
    });
  });

  colorMathParity();

  parityTest(
    'preview',
    script: 'color.ps1',
    args: {'Action': 'Preview'},
    dart: colorPreview,
    options: ParityOptions(rewriteJson: _isoSaved),
  );

  parityTest(
    'preview with nothing saved and no buttons yet',
    script: 'color.ps1',
    args: {'Action': 'Preview'},
    setup: (env) {
      env.file('tonights_color.json').deleteSync();
      _dropButtons(env);
    },
    dart: colorPreview,
  );

  group('apply', () {
    for (final (what, color, name) in [
      ('a wheel color', 'ff0000', 'Red'),
      ('an off-wheel color', 'f4a6b8', 'Blush'),
      ('a dark color', '0a1a6e', 'Navy'),
      ('white', 'ffffff', ''),
      ('black', '000000', ''),
      ('with # and capitals', '#8B0A2A', 'Wine'),
    ]) {
      parityTest(
        what,
        script: 'color.ps1',
        args: {'Action': 'Apply', 'Color': color, 'Name': name},
        options: _maskSaved,
        dart: (env) => colorApply(env, color, name: name),
      );
    }

    parityTest(
      'adds both buttons the first time',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': '00a8a8', 'Name': 'Teal'},
      setup: _dropButtons,
      options: _maskSaved,
      dart: (env) => colorApply(env, '00a8a8', name: 'Teal'),
    );

    parityTest(
      'no UPLIGHTS page to put the button on',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': 'ffb000'},
      setup: (env) {
        _dropButtons(env);
        _renamePage(env, 'UPLIGHTS', 'UPLIGHTS OLD');
      },
      options: _maskSaved,
      dart: (env) => colorApply(env, 'ffb000'),
    );

    parityTest(
      'no uplights in the show',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': '7dffc4'},
      setup: (env) {
        _dropButtons(env);
        for (final f in Directory(env.path('fixtures')).listSync().whereType<File>()) {
          if (f.path.contains('UPLIGHT')) f.deleteSync();
        }
      },
      options: _maskSaved,
      dart: (env) => colorApply(env, '7dffc4'),
    );

    parityTest(
      'refuses something that is not a color',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': 'pink'},
      dart: (env) => colorApply(env, 'pink'),
    );

    parityTest(
      'refuses without the CENTER SPOT scene',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': 'ff0000'},
      setup: (env) {
        for (final n in ['CENTER SPOT.scex', 'CENTER SPOT (adjust).scex']) {
          if (env.file('scenes/$n').existsSync()) env.file('scenes/$n').deleteSync();
        }
      },
      dart: (env) => colorApply(env, 'ff0000'),
    );

    parityTest(
      'refuses a folder that is not a show',
      script: 'color.ps1',
      args: {'Action': 'Apply', 'Color': 'ff0000'},
      setup: (env) => env.file('Live/live.ini').deleteSync(),
      dart: (env) => colorApply(env, 'ff0000'),
    );
  });
}

/// Old versus new on the color maths alone, over many colors. The old
/// functions are loaded straight out of color.ps1 with PowerShell's parser.
void colorMathParity() {
  test('nearest wheel slot and uplight mix match on 743 colors', skip: paritySkip, () async {
    final r = Random(7);
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    final colors = <String>[
      for (var a = 0; a < 256; a += 51)
        for (var b = 0; b < 256; b += 51)
          for (var c = 0; c < 256; c += 51) '${h(a)}${h(b)}${h(c)}',
      for (var i = 0; i < 184; i++) '${h(r.nextInt(256))}${h(r.nextInt(256))}${h(r.nextInt(256))}',
      // very dark colors land on exact halves (1 * 255 / 6 = 42.5), where rounding to even matters
      for (var a = 0; a < 7; a++)
        for (var b = 0; b < 7; b++)
          for (var c = 0; c < 7; c++) '${h(a)}${h(b)}${h(c)}',
    ];
    final script = File('${Directory.systemTemp.createTempSync('sx_cm_').path}/m.ps1')
      ..writeAsStringSync('''
\$m140 = 'Intimidator Hybrid 140SR (19ch)'; \$m251 = 'IntimidatorHybrid251Sr(19ch)'
\$ast = [System.Management.Automation.Language.Parser]::ParseFile('$oldSrcPath/color.ps1', [ref]\$null, [ref]\$null)
foreach (\$f in \$ast.FindAll({ param(\$a) \$a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, \$true)) {
  if (\$f.Name -in 'Get-Rgb', 'Get-Nearest', 'Get-WashMix') { . ([scriptblock]::Create(\$f.Extent.Text)) } }
. ([scriptblock]::Create((\$ast.FindAll({ param(\$a) \$a -is [System.Management.Automation.Language.AssignmentStatementAst] -and \$a.Left.Extent.Text -eq '\$wheel' }, \$true) | Select-Object -First 1).Extent.Text))
foreach (\$x in '${colors.join(',')}'.Split(',')) {
  \$w = Get-WashMix \$x \$true; \$n = Get-WashMix \$x \$false
  "\$x \$((Get-Nearest \$m140 \$x).value) \$((Get-Nearest \$m251 \$x).value) \$(\$w.dimmer) \$(\$w.red) \$(\$w.green) \$(\$w.blue) \$(\$w.white) \$(\$n.red) \$(\$n.green) \$(\$n.blue)"
}
''');
    addTearDown(() => script.parent.deleteSync(recursive: true));
    final res = await Process.run(pwshPath!, ['-NoProfile', '-NonInteractive', '-File', script.path]);
    expect(res.exitCode, 0, reason: '${res.stderr}');
    final old = const LineSplitter().convert('${res.stdout}').where((l) => l.trim().isNotEmpty).toList();
    final mine = [
      for (final x in colors)
        () {
          final w = washMix(x, hasWhite: true), n = washMix(x, hasWhite: false);
          return '$x ${nearestWheel(wheel140, x)!.value} ${nearestWheel(wheel251, x)!.value} '
              '${w['dimmer']} ${w['red']} ${w['green']} ${w['blue']} ${w['white']} ${n['red']} ${n['green']} ${n['blue']}';
        }(),
    ];
    expect(old, hasLength(colors.length));
    expect(mine, old);
  });
}
