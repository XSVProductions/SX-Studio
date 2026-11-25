/// Old versus new for `settings.json`. The old settings code lives inside the
/// old server (`df_aim_gui.ps1`), so this lifts its SETTINGS block and the body
/// of its `/api/settings/set` route out of the file and runs them on their own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// The old code, cut from the server's source by its first and last lines.
({String block, String route}) _oldCode() {
  final lines = File(p.join(oldSrcPath!, 'df_aim_gui.ps1')).readAsLinesSync();
  int at(bool Function(String) test, [int from = 0]) {
    final i = lines.indexWhere(test, from);
    if (i < 0) throw StateError('df_aim_gui.ps1 changed: a marker line is gone');
    return i;
  }

  final a = at((l) => l.startsWith(r'$tabIds = @('));
  final b = at((l) => l.startsWith('function Get-BackupDir'), a);
  final r0 = at((l) => l.trim() == "'/api/settings/set' {");
  final r1 = at((l) => l.trim() == r'Save-Settings $st', r0);
  return (block: lines.sublist(a, b).join('\n'), route: lines.sublist(r0 + 1, r1 + 1).join('\n'));
}

/// Runs the old code in [dir]. With [body], runs the set route with it;
/// without, prints what `Get-Settings` answers.
Future<Object?> _runOld(String dir, {Json? body, bool fromPhone = false}) async {
  final code = _oldCode();
  final bodyFile = p.join(dir, '..', 'body.json');
  if (body != null) File(bodyFile).writeAsStringSync(jsonEncode(body));
  String q(String s) => "'${s.replaceAll("'", "''")}'";
  final script = [
    r"$ErrorActionPreference = 'Stop'",
    '\$cfgDir = ${q(dir)}',
    r"$setF = Join-Path $cfgDir 'settings.json'",
    code.block,
    r'function Send-Json($c, $o) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Depth 10 -Compress)) }',
    if (body == null)
      r'Send-Json $null @{ ok = $true; settings = (Get-Settings) }'
    else ...[
      '\$fromPhone = \$${fromPhone ? 'true' : 'false'}',
      '\$body = [IO.File]::ReadAllText(${q(bodyFile)}) | ConvertFrom-Json',
      "switch ('x') { 'x' {",
      code.route,
      r'Send-Json $null @{ ok = $true; settings = (Get-Settings) }',
      '} }',
    ],
  ].join('\n');
  final sf = writePsScript(p.join(dir, '..', 'run.ps1'), script);
  final r = await Process.run(pwshPath!, ['-NoProfile', '-NonInteractive', '-File', sf.path], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0) fail('old code failed: ${r.stderr}');
  return jsonDecode((r.stdout as String).trim().split('\n').last);
}

Object? _dart(String dir, {Json? body, bool fromPhone = false}) {
  final store = SettingsStore(dir);
  try {
    final s = body == null ? store.readRaw() : store.apply(body, fromPhone: fromPhone).toJson();
    return jsonDecode(jsonEncode({'ok': true, 'settings': s}));
  } on ToolError catch (e) {
    return {'ok': false, 'error': e.message};
  }
}

/// One case: [file] is what `settings.json` holds before (null for none).
void _case(String name, {String? file, Json? body, bool fromPhone = false}) {
  test(name, skip: paritySkip, () async {
    final tmp = Directory.systemTemp.createTempSync('sx_set_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dir = p.join(tmp.path, 'cfg');
    void fresh() {
      if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
      Directory(dir).createSync();
      Directory(p.join(tmp.path, 'Drive Folder')).createSync(recursive: true);
      if (file != null) File(p.join(dir, 'settings.json')).writeAsStringSync(file);
    }

    final set = p.join(dir, 'settings.json');
    String? bytes() => File(set).existsSync() ? utf8.decode(forCompare(set, File(set).readAsBytesSync())) : null;
    fresh();
    final old = await _runOld(dir, body: body, fromPhone: fromPhone);
    final oldFile = bytes();
    fresh();
    final mine = _dart(dir, body: body, fromPhone: fromPhone);
    expect(mine, old, reason: 'answer');
    expect(bytes(), oldFile, reason: 'settings.json');
  });
}

void main() {
  final messyLayout = {
    'pages': ['3', '3', 'X12', 'x1', 'page4', 7, '1000'],
    'order': {
      '3': ['page3_button1', 'page3_button1', 'bad/sec', 'ünïcode btn'],
      'zz': ['page1_button1'],
    },
    'hidden': '5',
    'collapsed': ['x1', null],
    'custom': [
      {
        'id': 'x1',
        'name': '  My <page>|\u0001 with a name that is far too long to keep all of it  ',
        'swap': 'false',
        'buttons': [
          {'id': 'x1_b1', 'title': '', 'file': 'CHASE.SCEX', 'fader': 99, 'bpm': 1, 'flash': '', 'beats': '2.5', 'color': '16777215'},
          {'id': 'X1_B1', 'title': 'dup', 'file': 'A.scex'},
          {'id': 'x2_b1', 'title': 'wrong page', 'file': 'A.scex'},
          {'id': 'x1_b2', 'title': 'bad file', 'file': 'a/b.scex'},
          {'id': 'x1_b3', 'title': 'Move', 'file': 'CIRCLE.gpj', 'fader': '3', 'beats': 100, 'color': 16777216},
          {'id': 'x1_b4', 'file': 'x.gpj', 'beats': 0.5, 'fader': -2},
        ],
      },
      {'id': 'X1', 'name': 'dup page'},
      {'id': 'y1', 'name': 'bad id'},
      {'id': 'x2', 'name': ''},
    ],
  };

  group('read', () {
    _case('no settings file');
    _case('a broken file reads as the defaults', file: '{"tabOrder": [');
    _case('the pre-1.9.7 default order gives way to the new one', file: '{"tabOrder":["rt","rig","aim","skip","color"]}');
    _case(
      'a custom order is kept, cleaned and completed',
      file: '{"tabOrder":["speed","RT","nope","speed","aim"],"tabHidden":["apc","APC","x"],"reopen":"false","autoUpd":0,"driveFolder":5}',
    );
    _case(
      'tab names are cleaned',
      file: jsonEncode({
        'tabNames': {'rt': ' Rig <b>Test</b>\t ', 'aim': 'A' * 25, 'nope': 'x', 'color': '', 'SPEED': 'Fast'},
      }),
    );
    _case('the player layout is cleaned', file: jsonEncode({'playerLayout': messyLayout}));
    _case(
      'an old Windows file with escapes and CRLF',
      file: '{\r\n    "tabOrder":  [\r\n "aim", "rt"\r\n],\r\n    "tabNames":  {"rt":  "Rig \\u0026 Test"}\r\n}',
    );
  });

  group('set', () {
    final before = jsonEncode({
      'tabOrder': ['aim', 'rt'],
      'tabNames': {'rt': 'Rig'},
      'reopen': true,
      'autoUpd': true,
      'driveFolder': '',
    });
    _case(
      'tabs from the laptop',
      file: before,
      body: {
        'tabOrder': ['skip', 'rt', 'junk', 7],
        'tabHidden': ['look'],
        'tabNames': {'aim': 'Aim <here>', 'bad': 'x'},
      },
    );
    _case(
      'unhide every tab and drop the names',
      file: jsonEncode({
        'tabHidden': ['rt', 'aim'],
        'tabNames': {'rt': 'R'},
      }),
      body: {'tabHidden': [], 'tabNames': {}},
    );
    _case('the laptop-only switches', file: before, body: {'reopen': false, 'autoUpd': 'no'});
    _case(
      'a phone may not change the laptop-only switches',
      file: before,
      body: {
        'reopen': false,
        'autoUpd': false,
        'tabHidden': ['rt'],
      },
      fromPhone: true,
    );
    _case('the player layout', body: {'playerLayout': messyLayout});
    _case('no settings file and an empty change', body: {});
  });

  group('drive folder', () {
    // The folder is made next to the settings folder by `_case`.
    test('a folder that exists, given with quotes and a trailing slash', skip: paritySkip, () async {
      final tmp = Directory.systemTemp.createTempSync('sx_set_parity_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final dir = p.join(tmp.path, 'cfg'), drive = p.join(tmp.path, 'Drive Folder');
      Directory(drive).createSync();
      for (final (body, wantOk) in [
        ({'driveFolder': ' "$drive/" '}, true),
        ({'driveFolder': p.join(tmp.path, 'not there')}, false),
        ({'driveFolder': ''}, true),
      ]) {
        if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
        Directory(dir).createSync();
        final old = await _runOld(dir, body: body);
        final oldFile = File(p.join(dir, 'settings.json')).existsSync() ? File(p.join(dir, 'settings.json')).readAsStringSync() : null;
        Directory(dir).deleteSync(recursive: true);
        Directory(dir).createSync();
        expect(_dart(dir, body: body), old);
        expect((old as Map)['ok'], wantOk);
        expect(File(p.join(dir, 'settings.json')).existsSync() ? File(p.join(dir, 'settings.json')).readAsStringSync() : null, oldFile);
      }
    });
  });
}
