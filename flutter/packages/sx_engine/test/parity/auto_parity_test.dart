import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

// sx_remote.ps1 in test mode reads ShowXpress's settings from <show>/_param.ini
// and treats a marker file <show>/_sx_open as "ShowXpress is open".

String _param(ShowEnv env) => env.path('_param.ini');

void _writeParam(ShowEnv env, String text, {bool bom = false}) => File(_param(env)).writeAsBytesSync([
  if (bom) ...[0xEF, 0xBB, 0xBF],
  ...text.codeUnits,
]);

/// Turns the remote off in live.ini: no allow key, no password, and the first
/// page that has `live_mobile = yes` loses it.
void _remoteOffInLiveIni(ShowEnv env) {
  final f = env.file('Live/live.ini');
  var t = f.readAsStringSync();
  t = t.replaceFirst(RegExp(r'allow_live_mobile = [^\r\n]*\r?\n'), '');
  t = t.replaceFirst(RegExp(r'live_mobile_password = [^\r\n]*\r?\n'), '');
  t = t.replaceFirst(RegExp(r'(?<=\n)live_mobile = yes\r?\n'), '');
  f.writeAsStringSync(t);
}

/// A new password is random, so its value is masked. Nothing else is.
List<int> _maskPassword(String path, List<int> bytes) {
  if (path != 'Live/live.ini') return bytes;
  return String.fromCharCodes(bytes).replaceAll(RegExp(r'live_mobile_password = [a-z0-9]{10}'), 'live_mobile_password = <random>').codeUnits;
}

/// New look ids are random. Masks ids only in the file and the answer.
final _maskIds = ParityOptions(
  rewriteFile: (path, bytes) =>
      path == 'auto_show.json' ? String.fromCharCodes(bytes).replaceAll(RegExp(r'"id": ?"[0-9a-f]{8}"'), '"id":"<id>"').codeUnits : bytes,
  rewriteText: (t) => t.replaceAll(RegExp(r'"id": ?"[0-9a-f]{8}"'), '"id":"<id>"'),
);

void main() {
  Json get(ShowEnv env, {bool open = false}) {
    final j = autoGet(ShowEnv(env.root, sxRunning: () => open), paramPath: _param(env)).toJson();
    return j
      ..remove('player')
      ..remove('status');
  }

  group('AutoGet', () {
    parityTest('the show as it is', script: 'sx_remote.ps1', args: {'Action': 'AutoGet'}, dart: (env) => get(env));

    parityTest(
      'remote on, ShowXpress open',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoGet'},
      setup: (env) {
        _writeParam(env, '[General]\r\nX = 1\r\n[Network]\r\nLIVEMOBILEENABLE = yes\r\nLIVEMOBILEPORT = 7400\r\n');
        env.file('_sx_open').writeAsStringSync('test');
      },
      dart: (env) => get(env, open: true),
    );

    parityTest(
      'a page the remote cannot reach',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoGet'},
      setup: (env) {
        _writeParam(env, '[Network]\nLIVEMOBILEENABLE = yes\n');
        _remoteOffInLiveIni(env);
      },
      dart: (env) => get(env),
    );

    parityTest(
      'no auto_show.json',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoGet'},
      setup: (env) {
        final f = env.file('auto_show.json');
        if (f.existsSync()) f.deleteSync();
      },
      dart: (env) => get(env),
    );

    parityTest(
      'an auto_show.json that is not JSON',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoGet'},
      setup: (env) => env.file('auto_show.json').writeAsStringSync('{"looks": [ oops'),
      dart: (env) => get(env),
    );
  });

  group('AutoSave', () {
    final tidy = {
      'bpm': 128,
      'order': 'order',
      'stop': 'keep',
      'clean': false,
      'looks': [
        {
          'id': '0a1b2c3d',
          'name': 'Warm',
          'bars': 16,
          'on': true,
          'titles': ['UPLIGHTS AMBER', 'FIGURE 8'],
        },
        {
          'id': 'ffff0000',
          'name': 'Cold',
          'bars': 8,
          'on': false,
          'titles': ['UPLIGHTS BLUE'],
        },
      ],
    };
    parityTest(
      'saves settings',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoSave'},
      changes: tidy,
      changesArg: 'ConfigFile',
      dart: (env) => autoSave(env, tidy).report,
    );

    // Everything ConvertTo-AutoCfg tidies, with valid ids so nothing is random.
    final messy = {
      'bpm': '133.46',
      'order': 'SHUFFLE',
      'stop': 'Off',
      'clean': 1,
      'looks': [
        {
          'id': 'ABCDEF12',
          'name': '  A "very" | long name that goes on past forty letters  ',
          'bars': 7.5,
          'on': 'false',
          'titles': ['A|B', 'A|B', ' AB ', 5, true, null, ''],
        },
        null,
        {'id': 'abcdef12', 'name': '', 'bars': 'x', 'titles': 'ONE'},
        {'id': '12345678', 'name': 'big', 'bars': 999, 'on': 0, 'titles': []},
      ],
    };
    parityTest(
      'tidies what it is sent',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoSave'},
      changes: messy,
      changesArg: 'ConfigFile',
      options: _maskIds,
      dart: (env) => autoSave(env, messy).report,
    );

    final slow = {'bpm': 12.5, 'looks': <Object?>[]};
    parityTest(
      'a BPM out of range',
      script: 'sx_remote.ps1',
      args: {'Action': 'AutoSave'},
      changes: slow,
      changesArg: 'ConfigFile',
      dart: (env) => autoSave(env, slow).report,
    );

    parityTest('refuses when nothing is sent', script: 'sx_remote.ps1', args: {'Action': 'AutoSave'}, dart: (env) => autoSave(env, null).report);
  });

  group('Enable', () {
    String enable(ShowEnv env, {bool open = false}) => remoteEnable(ShowEnv(env.root, sxRunning: () => open), paramPath: _param(env));

    parityTest('refuses without param.ini', script: 'sx_remote.ps1', args: {'Action': 'Enable'}, dart: enable);

    parityTest(
      'refuses while ShowXpress is open',
      script: 'sx_remote.ps1',
      args: {'Action': 'Enable'},
      setup: (env) {
        _writeParam(env, '[Network]\r\n');
        env.file('_sx_open').writeAsStringSync('test');
      },
      dart: (env) => enable(env, open: true),
    );

    parityTest(
      'already on',
      script: 'sx_remote.ps1',
      args: {'Action': 'Enable'},
      setup: (env) => _writeParam(env, '[Network]\r\nLIVEMOBILEENABLE = yes\r\n'),
      dart: enable,
    );

    parityTest(
      'turns everything on',
      script: 'sx_remote.ps1',
      args: {'Action': 'Enable'},
      setup: (env) {
        _writeParam(env, '[General]\r\nLANG = en\r\n[Network]\r\nPORT = 1\r\n');
        _remoteOffInLiveIni(env);
      },
      options: const ParityOptions(rewriteFile: _maskPassword),
      dart: enable,
    );

    parityTest(
      'switches LIVEMOBILEENABLE from no to yes',
      script: 'sx_remote.ps1',
      args: {'Action': 'Enable'},
      setup: (env) => _writeParam(env, '[Network]\nLIVEMOBILEENABLE = no\nLIVEMOBILEPORT = 7348\n'),
      dart: enable,
    );

    parityTest(
      'adds a Network section, keeping the byte order mark',
      script: 'sx_remote.ps1',
      args: {'Action': 'Enable'},
      setup: (env) => _writeParam(env, '[General]\r\nLANG = en\r\n\r\n', bom: true),
      dart: enable,
    );
  });
}
