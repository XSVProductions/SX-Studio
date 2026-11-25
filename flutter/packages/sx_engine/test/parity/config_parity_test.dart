/// Old versus new for Export and Import settings. The old feature lives
/// inside the old server and calls its other tools, so this starts the old
/// server itself in test mode on one copy of the show, the port's engine on
/// another, and swaps settings files between them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
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

/// The APC40 tab isn't ported in this branch: no layout, and any import of
/// one is refused, which the old server also does when it has none to compare.
final _noApc40 = Apc40Part(readText: () => null, save: (raw) => false);

/// The old server, `df_aim_gui.ps1 -TestRoot`, on its own port.
class _OldServer {
  _OldServer._(this.process, this.base, this.infoFile);

  final Process process;
  final String base;
  final File infoFile;

  static Future<_OldServer> start(String show) async {
    final port = 47500 + Random().nextInt(400);
    final info = File(p.join(Directory.systemTemp.path, 'showxpress_helper_gui_$port.json'));
    if (info.existsSync()) info.deleteSync();
    final proc = await Process.start(pwshPath!, [
      '-NoProfile',
      '-File',
      p.join(oldSrcPath!, 'df_aim_gui.ps1'),
      '-TestRoot',
      show,
      '-Port',
      '$port',
      '-PhonePort',
      '${port + 1}',
      '-NoBrowser',
    ]);
    proc.stdout.drain<void>();
    proc.stderr.drain<void>();
    for (var i = 0; i < 120 && !info.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!info.existsSync()) {
      proc.kill();
      throw StateError('the old server did not start');
    }
    final url = (jsonDecode(info.readAsStringSync()) as Map)['url'] as String;
    return _OldServer._(proc, url.replaceFirst('/?', '/@?'), info);
  }

  /// Sends [body] to [path] (a GET without one) and answers the status and the text.
  Future<(int, String)> send(String path, {Object? body, Map<String, String> headers = const {}}) async {
    final c = HttpClient();
    try {
      final rq = await c.openUrl(body == null ? 'GET' : 'POST', Uri.parse(base.replaceFirst('/@', path)));
      headers.forEach(rq.headers.set);
      if (body != null) {
        rq.headers.contentType = ContentType.json;
        rq.write(jsonEncode(body));
      }
      final rs = await rq.close();
      return (rs.statusCode, await rs.transform(utf8.decoder).join());
    } finally {
      c.close();
    }
  }

  Future<Json> post(String path, Object body) async => (jsonDecode((await send(path, body: body)).$2) as Map).cast();

  Future<Json> get(String path) async => (jsonDecode((await send(path)).$2) as Map).cast();

  void stop() {
    process.kill();
    if (infoFile.existsSync()) infoFile.deleteSync();
  }
}

void main() {
  if (paritySkip != null) {
    test('config parity', () {}, skip: paritySkip);
    return;
  }

  late Directory tmp;
  late String oldShow, newShow;
  late _OldServer old;
  late Engine e;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('sx_config_parity_');
    oldShow = p.join(tmp.path, 'old', 'LightShows', 'Awaaz Lightshow');
    newShow = p.join(tmp.path, 'new', 'show');
    for (final to in [oldShow, newShow]) {
      copyDir(Directory(realShowPath!), Directory(to));
    }
    old = await _OldServer.start(oldShow);
    e = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 't', showPath: newShow, settingsDir: p.join(tmp.path, 'new', 'cfg')),
      sx: _FakeSx(),
    );
    e.provide(ExportFolders([p.join(tmp.path, 'new', 'exports')]));
  });

  tearDownAll(() async {
    old.stop();
    await e.stop();
    tmp.deleteSync(recursive: true);
  });

  String ini(String show) => File(p.join(show, 'Live', 'live.ini')).readAsStringSync();
  Future<Json> newImport(Object? d) => importConfig(e, _noApc40, d);

  /// The answer without what may differ: the backup's path, and the
  /// settings, compared on their own.
  Json answer(Json r) => {for (final x in r.entries) x.key: x.value}
    ..remove('backup')
    ..remove('settings');

  /// The settings an import answers, without the APC40 tab, which only the
  /// old app has until that tab is merged.
  Object? settingsOf(Json r) {
    final s = r['settings'];
    if (s is! Map) return null;
    return {...s, 'tabOrder': (s['tabOrder'] as List).where((t) => t != 'apc40').toList()};
  }

  test('a file the old app exports imports into the port with the same result', () async {
    final sp = (await old.get('/api/speed'))['buttons'] as List;
    final b = sp.first as Map;
    await old.post('/api/speed/apply', {
      'changes': [
        {'sec': b['sec'], 'title': b['title'], 'fader': ((b['fader'] as int) + 1) % 4},
      ],
    });
    final pad = ((await old.get('/api/apc'))['pads'] as List).cast<Map>().firstWhere((x) => x['type'] == 0);
    await old.post('/api/apc/apply', {
      'changes': [
        {'sec': pad['sec'], 'title': pad['title'], 'note': pad['note'], 'on': 45, 'off': 9},
      ],
    });
    await old.post('/api/settings/set', {
      'tabHidden': ['lab'],
      'tabNames': {'rt': 'Rig Check'},
      'playerLayout': {
        'pages': ['1', 'x1'],
        'custom': [
          {
            'id': 'x1',
            'name': 'MY PAGE',
            'buttons': [
              {'id': 'x1_b1', 'title': 'Red', 'file': 'RED.scex', 'fader': 2, 'beats': 2.5},
            ],
          },
        ],
      },
    });
    final ex = await old.post('/api/config/export', {
      'device': {'sxh_theme': 'light', 'sxh_phone_key': 'no'},
    });
    final file = File(ex['path']! as String);
    final d = jsonDecode(file.readAsStringSync()) as Map;
    file.deleteSync();
    expect(d['device'], {'sxh_theme': 'light'});

    final r = await newImport(d);
    expect(r['warn'], isEmpty);
    expect(r['done'], ['the tabs and the SX Player pages', 'the Auto Show', 'the APC mini pads', 'the speed faders']);
    expect(ini(newShow), ini(oldShow));
    expect(jsonDecode(File(p.join(newShow, 'auto_show.json')).readAsStringSync()), jsonDecode(File(p.join(oldShow, 'auto_show.json')).readAsStringSync()));

    // the same file again: both apps find nothing to change in the show
    final again = await old.post('/api/config/import', {'data': d});
    expect(answer(await newImport(d)), answer(again));
    expect(settingsOf(await newImport(d)), settingsOf(again));
  });

  test('a file the port exports imports into the old app with the same result', () async {
    final b = speedPreview(e.show()).buttons[3];
    speedApply(e.show(), [SpeedChange(sec: b.sec, title: b.title, fader: (b.fader + 2) % 4)]);
    final saved = saveConfigExport(e, _noApc40, {'sxh_theme': 'dark', 'sxh_mvlite': 'RED.scex'}, folders: [p.join(tmp.path, 'new', 'exports')]);
    final d = jsonDecode(File(saved['path']! as String).readAsStringSync());

    final r = await old.post('/api/config/import', {'data': d});
    expect(r['warn'], isEmpty);
    expect(r['done'], ['the tabs and the SX Player pages', 'the Auto Show', 'the APC mini pads (already the same)', 'the speed faders']);
    expect(ini(oldShow), ini(newShow));
    expect(settingsOf(r), settingsOf(await newImport(d)));
  });

  test('refusals, warnings and queued parts read the same', () async {
    final ex = configExport(e, _noApc40);
    final pads = ((ex['apcMini']! as Map)['pads'] as List).cast<Json>();
    final btns = ((ex['speedFaders']! as Map)['buttons'] as List).cast<Json>();
    final h = {'app': 'SX Studio', 'kind': 'settings', 'format': 1};
    final files = <String, Object?>{
      'not a settings file': {'app': 'Other', 'kind': 'settings'},
      'newer': {...h, 'format': 2},
      'no format': {'app': 'SX Studio', 'kind': 'settings'},
      'a fraction for the format': {...h, 'format': 1.0},
      'parts that cannot be read': {
        ...h,
        'settings': {
          'driveFolder': p.join(tmp.path, 'not here'),
          'tabNames': {'rt': 'X'},
        },
        'apc40': {'pages': []},
        'autoShow': {'bpm': 100},
        'apcMini': {
          'pads': [
            {...pads[0], 'title': 'NOT THIS'},
            {...pads[1], 'title': 'NOR THIS'},
            pads[2],
          ],
        },
        'speedFaders': {
          'buttons': [
            {...btns[0], 'fader': 9},
            {...btns[1], 'title': 'zz'},
            btns[2],
            {...btns[0], 'fader': 'x'},
          ],
        },
      },
      'parts of the wrong kind': {
        ...h,
        'settings': 'abc',
        'apc40': 'x',
        'autoShow': [1],
      },
      'one miss each': {
        ...h,
        'apcMini': {
          'pads': [
            {...pads[0], 'title': 'NOT THIS'},
          ],
        },
        'speedFaders': {
          'buttons': [
            {...btns[0], 'fader': 9},
          ],
        },
      },
      'a pad the tool refuses': {
        ...h,
        'apcMini': {
          'pads': [
            {...pads[1], 'note': pads[0]['note']},
          ],
        },
      },
      'phone access on': {
        ...h,
        'phone': {'on': true},
      },
      'phone access off': {
        ...h,
        'phone': {'on': false},
      },
    };
    for (final MapEntry(key: name, value: f) in files.entries) {
      final a = await old.post('/api/config/import', {'data': f});
      final b = await newImport(f);
      expect(answer(b), answer(a), reason: name);
      expect(settingsOf(b), settingsOf(a), reason: name);
      expect(ini(newShow), ini(oldShow), reason: name);
    }

    // ShowXpress open: the old server's marker file, the port's fake
    File(p.join(oldShow, '_sx_open')).writeAsStringSync('test');
    (e.sx as _FakeSx).running = true;
    final b0 = btns[0];
    final queued = {
      ...h,
      'speedFaders': {
        'buttons': [
          {...b0, 'fader': ((b0['fader']! as int) + 1) % 4},
        ],
      },
    };
    expect(answer(await newImport(queued)), answer(await old.post('/api/config/import', {'data': queued})));
    expect(ini(newShow), ini(oldShow));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a phone gets the old refusal as an ok:false answer', () async {
    // the old server marks a phone by the relay's header
    final (status, _) = await old.send('/api/config/import', body: const {}, headers: {'X-SXH-Phone': '10.0.0.2'});
    // with phone access off the old server answers before the route
    expect(status, 403);
    final now = await runRoute(e.api.find('/api/config/import')!, ApiRequest(body: const {}, query: const {}, fromPhone: true));
    expect(now, {'ok': false, 'error': 'Import the settings on the computer.'});
  });
}
