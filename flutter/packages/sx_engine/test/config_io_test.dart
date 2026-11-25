import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

class _FakeRevealer implements Revealer {
  final revealed = <String>[];

  @override
  Future<void> reveal(String file) async => revealed.add(file);
}

class _FakeHooks implements LabPlayerHooks {
  var synced = 0;

  @override
  void syncExtras() => synced++;
}

/// Two pads (RED on note 0, BLUE on note 1) and two speed faders.
const _liveIni =
    '[live]\r\nmaster_faders = 2\r\n\r\n[master_faders]\r\ncaption_fader0 = MOVEMENTS\r\ntype_fader0 = 1\r\ncaption_fader1 = COLORS\r\ntype_fader1 = 1\r\n\r\n'
    '[page1]\r\nname = COLORS\r\nnb_buttons = 2\r\n\r\n'
    '[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = RED.scex\r\ntitle = RED\r\n'
    'trigger_midi_device = 0\r\ntrigger_midi_channel = 1\r\ntrigger_midi_type = 0\r\ntrigger_midi_note = 0\r\n'
    'trigger_midiout_device = 0\r\ntrigger_midiout_channel = 7\r\ntrigger_midiout_type = 0\r\ntrigger_midiout_note = 0\r\n'
    'trigger_midiout_data = 5\r\ntrigger_midiout_data_off = 3\r\n\r\n'
    '[page1_button2]\r\nline = 1\r\ncolumn = 2\r\nname = BLUE.scex\r\ntitle = BLUE\r\n'
    'trigger_midi_device = 0\r\ntrigger_midi_channel = 1\r\ntrigger_midi_type = 0\r\ntrigger_midi_note = 1\r\n';

void main() {
  late Directory tmp;
  late String show, cfg, downloads;
  late _FakeSx sx;
  late Engine e;
  late _FakeRevealer revealer;
  var a40Text = <String?>[null];
  var a40Saved = <Json>[];
  var a40Ok = true;
  late Apc40Part apc40;
  final at = DateTime(2026, 11, 25, 9, 30, 5);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_config_io_');
    show = p.join(tmp.path, 'show');
    cfg = p.join(tmp.path, 'cfg');
    downloads = p.join(tmp.path, 'Downloads');
    Directory(p.join(show, 'Live')).createSync(recursive: true);
    Directory(downloads).createSync();
    File(p.join(show, 'Live', 'live.ini')).writeAsStringSync(_liveIni);
    sx = _FakeSx();
    e = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 't', showPath: show, settingsDir: cfg, appVersion: '2.0.0'),
      sx: sx,
    );
    revealer = _FakeRevealer();
    e.provide<Revealer>(revealer);
    e.provide(ExportFolders([downloads]));
    a40Text = [null];
    a40Saved = [];
    a40Ok = true;
    apc40 = Apc40Part(
      readText: () => a40Text.single,
      save: (raw) {
        a40Saved.add(raw);
        return a40Ok;
      },
    );
  });

  tearDown(() async {
    await e.stop();
    tmp.deleteSync(recursive: true);
  });

  String ini() => File(p.join(show, 'Live', 'live.ini')).readAsStringSync();
  Json export() => configExport(e, apc40, now: at);
  Future<Json> import(Json d) => importConfig(e, apc40, d, now: at);

  /// A settings file with only [parts] in it.
  Json file(Json parts) => {'app': 'SX Studio', 'kind': 'settings', 'format': 1, ...parts};

  group('export', () {
    test('holds every part in the old key order, and the device keys the page may send', () async {
      a40Text = ['{"pages":[{"pads":{}}]}'];
      final r = saveConfigExport(
        e,
        apc40,
        {'sxh_theme': 'light', 'sxh_phone_key': 'secret', 'sxh_lvspd': 2, 'other': 'x', 'sxh_flip_3': '{"pan":true}'},
        folders: [downloads],
        now: at,
      );
      expect(r['ok'], isTrue);
      expect(r['name'], 'SX Studio settings 2026-11-25.json');
      expect(r['folder'], downloads);
      final d = jsonDecode(File(r['path']! as String).readAsStringSync()) as Map;
      expect(d.keys, ['app', 'kind', 'format', 'version', 'saved', 'settings', 'apc40', 'autoShow', 'apcMini', 'speedFaders', 'phone', 'device']);
      expect(d['saved'], '2026-11-25T09:30:05');
      expect(d['version'], '2.0.0');
      expect((d['settings'] as Map).keys, ['tabOrder', 'tabHidden', 'tabNames', 'playerLayout', 'reopen', 'autoUpd', 'driveFolder']);
      expect(d['apc40'], {
        'pages': [
          {'pads': {}},
        ],
      });
      expect(d['apcMini'], {
        'pads': [
          {'sec': 'page1_button1', 'title': 'RED', 'note': 0, 'on': 5, 'off': 3},
          {'sec': 'page1_button2', 'title': 'BLUE', 'note': 1, 'on': -1, 'off': -1},
        ],
      });
      expect(d['speedFaders'], {
        'buttons': [
          {'sec': 'page1_button1', 'title': 'RED', 'fader': 0},
          {'sec': 'page1_button2', 'title': 'BLUE', 'fader': 0},
        ],
      });
      expect(d['phone'], {'on': false});
      expect(d['device'], {'sxh_theme': 'light', 'sxh_flip_3': '{"pan":true}'});
    });

    test('a taken name gets a number, and Show the file reveals the newest', () async {
      final a = saveConfigExport(e, apc40, null, folders: [downloads], now: at);
      final b = saveConfigExport(e, apc40, null, folders: [downloads], now: at);
      final c = saveConfigExport(e, apc40, null, folders: [downloads], now: at);
      expect(
        [a['name'], b['name'], c['name']],
        ['SX Studio settings 2026-11-25.json', 'SX Studio settings 2026-11-25 (2).json', 'SX Studio settings 2026-11-25 (3).json'],
      );
      final r = await runRoute(e.api.find('/api/open')!, ApiRequest(body: {'what': 'export'}, query: const {}, fromPhone: false));
      expect(r['ok'], isTrue);
      expect(revealer.revealed, [c['path']]);
    });

    test('Show the file before any export has nothing to open', () async {
      final r = await runRoute(e.api.find('/api/open')!, ApiRequest(body: {'what': 'export'}, query: const {}, fromPhone: false));
      expect(r['error'], 'Nothing to open.');
    });

    test('a folder that cannot be written passes to the next one', () {
      final blocked = p.join(tmp.path, 'blocked');
      File(blocked).writeAsStringSync('a file, not a folder');
      final r = saveConfigExport(e, apc40, null, folders: [blocked, p.join(cfg, 'exports')], now: at);
      expect(r['folder'], p.join(cfg, 'exports'));
      final none = saveConfigExport(e, apc40, null, folders: [blocked], now: at);
      expect(none['ok'], isFalse);
      expect(none['error'], startsWith("The settings couldn't be saved: "));
    });

    test('the route saves where ExportFolders says', () async {
      final r = await runRoute(
        e.api.find('/api/config/export')!,
        ApiRequest(
          body: {
            'device': {'sxh_theme': 'dark'},
          },
          query: const {},
          fromPhone: false,
        ),
      );
      expect(r['ok'], isTrue);
      expect(p.dirname(r['path']! as String), downloads);
    });

    test('a phone gets the old refusals', () async {
      Future<Json> phone(String path) => runRoute(e.api.find(path)!, ApiRequest(body: const {}, query: const {}, fromPhone: true));
      expect(await phone('/api/config/export'), {'ok': false, 'error': 'Export the settings on the computer.'});
      expect(await phone('/api/config/import'), {'ok': false, 'error': 'Import the settings on the computer.'});
    });
  });

  group('import', () {
    test('refuses a file that is not a settings file, or is from a newer SX Studio', () async {
      const notOurs = "That file isn't an SX Studio settings file. Nothing was changed.";
      const newer = 'That file is from a newer SX Studio - update SX Studio first. Nothing was changed.';
      expect((await import({'app': 'Other', 'kind': 'settings'}))['error'], notOurs);
      expect((await importConfig(e, apc40, null))['error'], notOurs);
      expect((await importConfig(e, apc40, 'text'))['error'], notOurs);
      expect((await import({'app': 'SX Studio', 'kind': 'settings', 'format': 2}))['error'], newer);
      expect((await import({'app': 'SX Studio', 'kind': 'settings'}))['error'], newer);
      expect(Directory(configBackupDir(e)).existsSync(), isFalse);
    });

    test('backs up what is there now and keeps the newest 5', () async {
      for (var i = 1; i <= 6; i++) {
        Directory(p.join(configBackupDir(e), 'settings before import 2026-01-0$i 120000')).createSync(recursive: true);
      }
      Directory(p.join(configBackupDir(e), 'SX Studio show 2026-01-01')).createSync();
      final r = await import(file({}));
      expect(r['ok'], isTrue);
      expect(r['backup'], p.join(configBackupDir(e), 'settings before import 2026-11-25 093005'));
      final kept = Directory(configBackupDir(e)).listSync().map((x) => p.basename(x.path)).toList()..sort();
      expect(kept, [
        'SX Studio show 2026-01-01',
        'settings before import 2026-01-03 120000',
        'settings before import 2026-01-04 120000',
        'settings before import 2026-01-05 120000',
        'settings before import 2026-01-06 120000',
        'settings before import 2026-11-25 093005',
      ]);
      final saved = jsonDecode(File(p.join(r['backup']! as String, 'SX Studio settings.json')).readAsStringSync()) as Map;
      expect(saved['kind'], 'settings');
      expect(saved.containsKey('device'), isFalse);
      expect(r['done'], isEmpty);
      expect(r['warn'], isEmpty);
    });

    test('the tabs and the player pages go through the settings checks', () async {
      final hooks = _FakeHooks();
      e.provide<LabPlayerHooks>(hooks);
      final r = await import(
        file({
          'settings': {
            'tabOrder': ['speed', 'rt', 'nope'],
            'tabHidden': ['lab'],
            'tabNames': {'rt': 'Rig <b>', 'zz': 'gone'},
            'playerLayout': {
              'pages': ['1', 'x1', 'bad'],
              'custom': [
                {'id': 'x1', 'name': '', 'buttons': []},
              ],
            },
            'reopen': false,
            'autoUpd': false,
            'driveFolder': p.join(tmp.path, 'not here'),
          },
        }),
      );
      expect(r['done'], ['the tabs and the SX Player pages']);
      expect(r['warn'], ["The Google Drive folder in the file isn't on this computer, so that one setting was kept as it was."]);
      final s = SxSettings.fromJson((r['settings']! as Map).cast());
      expect(s.tabOrder.take(2), ['speed', 'rt']);
      expect(s.tabHidden, ['lab']);
      expect(s.tabNames, {'rt': 'Rig b'});
      expect(s.playerLayout.pages, ['1', 'x1']);
      expect(s.playerLayout.custom.single.name, 'NEW PAGE');
      expect(s.reopen, isFalse);
      expect(s.autoUpd, isFalse);
      expect(e.queue.reopen, isFalse);
      expect(hooks.synced, 1);
    });

    test('settings that are not an object are kept', () async {
      final r = await import(file({'settings': 'tabs'}));
      expect(r['warn'], ["The tabs and SX Player pages in the file couldn't be read, so they were kept as they were."]);
      expect(r['done'], isEmpty);
    });

    test('the APC40 pages go to the APC40 tab, which may refuse them', () async {
      final pages = {
        'pages': [
          {'pads': {}},
        ],
      };
      expect((await import(file({'apc40': pages})))['done'], ['the APC40 pads and faders']);
      expect(a40Saved, [pages]);
      a40Ok = false;
      const kept = "The APC40 pages in the file couldn't be read, so they were kept as they were.";
      expect((await import(file({'apc40': pages})))['warn'], [kept]);
      a40Saved.clear();
      for (final bad in [
        {'pages': []},
        {'x': 1},
        {
          'pages': [
            {'pads': []},
          ],
        },
      ]) {
        expect((await import(file({'apc40': bad})))['warn'], [kept], reason: '$bad');
      }
      expect(a40Saved, isEmpty);
    });

    test('the Auto Show is saved through its own checks', () async {
      final r = await import(
        file({
          'autoShow': {
            'bpm': 300,
            'looks': [
              {
                'name': 'Opening',
                'titles': ['RED'],
              },
            ],
          },
        }),
      );
      expect(r['done'], ['the Auto Show']);
      final saved = jsonDecode(File(p.join(show, 'auto_show.json')).readAsStringSync()) as Map;
      expect(saved['bpm'], 220);
      expect((saved['looks'] as List).single['name'], 'Opening');
      final bad = await import(
        file({
          'autoShow': {'bpm': 120},
        }),
      );
      expect(bad['warn'], ["The Auto Show in the file couldn't be read, so it was kept as it was."]);
    });

    test('APC mini pads are matched by place and title, and only changes are saved', () async {
      final r = await import(
        file({
          'apcMini': {
            'pads': [
              {'sec': 'page1_button1', 'title': 'red', 'note': 0, 'on': 9, 'off': 3},
              {'sec': 'page1_button2', 'title': 'BLUE', 'note': 8, 'on': -1, 'off': -1},
              {'sec': 'page1_button3', 'title': 'GREEN', 'note': 2},
              {'sec': 'bad', 'title': 'X', 'note': 2},
            ],
          },
        }),
      );
      expect(r['done'], ['the APC mini pads']);
      expect(r['warn'], ["1 APC mini pad in the file isn't the same button in this show, so it was left out."]);
      expect(ini(), contains('trigger_midiout_data = 9\r\n'));
      expect(ini(), contains('trigger_midi_note = 8\r\n'));

      final again = await import(
        file({
          'apcMini': {
            'pads': [
              {'sec': 'page1_button1', 'title': 'RED', 'note': 0, 'on': 9, 'off': 3},
              {'sec': 'page1_button2', 'title': 'GREEN', 'note': 3},
              {'sec': 'page1_button2', 'title': 'BLUE', 'note': 99},
            ],
          },
        }),
      );
      expect(again['done'], ['the APC mini pads (already the same)']);
      expect(again['warn'], ["2 APC mini pads in the file aren't the same buttons in this show, so they were left out."]);
    });

    test('speed faders are matched by place and title, and a fader the show lacks is left out', () async {
      final r = await import(
        file({
          'speedFaders': {
            'buttons': [
              {'sec': 'page1_button1', 'title': 'RED', 'fader': 1},
              {'sec': 'page1_button2', 'title': 'BLUE', 'fader': 0},
              {'sec': 'page1_button2', 'title': 'BLUE', 'fader': 2},
            ],
          },
        }),
      );
      expect(r['done'], ['the speed faders']);
      expect(r['warn'], ["1 button in the file isn't in this show (or follows a fader it doesn't have), so its speed fader was left out."]);
      expect(ini(), contains('masterspeedfader = 1\r\n'));
      final same = await import(
        file({
          'speedFaders': {
            'buttons': [
              {'sec': 'page1_button1', 'title': 'RED', 'fader': 1},
              {'sec': 'page9_button1', 'title': 'X', 'fader': 0},
              {'sec': 'page9_button2', 'title': 'Y', 'fader': 0},
            ],
          },
        }),
      );
      expect(same['done'], ['the speed faders (already the same)']);
      expect(same['warn'], ["2 buttons in the file aren't in this show (or follow a fader it doesn't have), so their speed faders were left out."]);
    });

    test('while ShowXpress is open the pads and faders are queued', () async {
      sx.running = true;
      final before = ini();
      final r = await import(
        file({
          'apcMini': {
            'pads': [
              {'sec': 'page1_button2', 'title': 'BLUE', 'note': 9},
            ],
          },
          'speedFaders': {
            'buttons': [
              {'sec': 'page1_button1', 'title': 'RED', 'fader': 1},
            ],
          },
        }),
      );
      expect(r['done'], ['the APC mini pads (saved as soon as ShowXpress is closed)', 'the speed faders (saved as soon as ShowXpress is closed)']);
      expect(ini(), before);
      expect([for (final i in e.queue.info()['items']! as List) (i as Map)['label']], ['APC pads', 'Speed faders']);
      sx.running = false;
      await e.queue.run(reopen: false);
      expect(ini(), contains('trigger_midi_note = 9\r\n'));
      expect(ini(), contains('masterspeedfader = 1\r\n'));
    });

    test('a save the tool refuses is reported and the rest goes on', () async {
      final r = await import(
        file({
          'apcMini': {
            'pads': [
              {'sec': 'page1_button2', 'title': 'BLUE', 'note': 0},
            ],
          },
          'phone': {'on': true},
        }),
      );
      expect(r['warn'], [
        "the APC mini pads couldn't be imported (Two buttons would be on the same pad (RED and BLUE). NOTHING was changed.), so they were kept as they were.",
      ]);
      expect(r['done'], ['phone access on (phones still pair here with a code)']);
    });

    test('phone access is switched only when it differs', () async {
      expect(
        (await import(
          file({
            'phone': {'on': false},
          }),
        ))['done'],
        isEmpty,
      );
      expect(
        (await import(
          file({
            'phone': {'on': true},
          }),
        ))['done'],
        ['phone access on (phones still pair here with a code)'],
      );
      expect(e.phones.on, isTrue);
      expect(e.phonePort, isNotNull);
      expect(
        (await import(
          file({
            'phone': {'on': false},
          }),
        ))['done'],
        ['phone access off'],
      );
      expect(e.phonePort, isNull);
    });

    test('a show that cannot be read keeps the pads and faders', () async {
      File(p.join(show, 'Live', 'live.ini')).deleteSync();
      final r = await import(
        file({
          'apcMini': {
            'pads': [
              {'sec': 'page1_button1', 'title': 'RED', 'note': 0},
            ],
          },
          'speedFaders': {
            'buttons': [
              {'sec': 'page1_button1', 'title': 'RED', 'fader': 0},
            ],
          },
        }),
      );
      expect(r['warn'], [
        "The show's APC mini pads couldn't be read, so they were kept as they were.",
        "The show's speed faders couldn't be read, so they were kept as they were.",
      ]);
    });

    test('an exported file imports into the same show as already the same', () async {
      final d = export();
      final r = await import(d);
      expect(r['done'], ['the tabs and the SX Player pages', 'the Auto Show', 'the APC mini pads (already the same)', 'the speed faders (already the same)']);
      expect(r['warn'], isEmpty);
    });
  });
}
