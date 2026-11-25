import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

// Old `df_aim.ps1` against `tools/aim` on copies of the real show.

/// The state file's shape records come from unordered hashtables, so the old
/// tool writes their keys in a different order every run. Sorts the lines of
/// each record (and only those) before comparing.
List<int> _recordKeyOrder(String path, List<int> bytes) {
  if (!path.endsWith('aim_state.json')) return bytes;
  final lines = utf8.decode(bytes).split('\n');
  final out = <String>[];
  var run = <String>[];
  bool inRecord(String l) => l.startsWith('      "') && !l.startsWith('       ');
  void flush() {
    final keys = [for (final l in run) l.replaceFirst(RegExp(r',?(\r?)$'), '')]..sort();
    for (var i = 0; i < keys.length; i++) {
      out.add(i < keys.length - 1 ? '${keys[i]},' : keys[i]);
    }
    run = [];
  }

  for (final l in lines) {
    if (inRecord(l)) {
      run.add(l);
      continue;
    }
    if (run.isNotEmpty) flush();
    out.add(l);
  }
  if (run.isNotEmpty) flush();
  return utf8.encode(out.join('\n'));
}

const _opts = ParityOptions(rewriteFile: _recordKeyOrder);

Map<String, Object> _args(String action, AimMode mode, [Map<String, Object> more = const {}]) => {
  'Action': action,
  if (mode == AimMode.room) 'Mode': 'Room',
  ...more,
};

/// Replaces the text of a show file.
void _edit(ShowEnv env, String rel, String Function(String) change) {
  final f = env.file(rel);
  final b = f.readAsBytesSync();
  final bom = hasBom(b);
  f.writeAsBytesSync([
    if (bom) ...[0xEF, 0xBB, 0xBF],
    ...utf8.encode(change(readText(f.path))),
  ]);
}

/// Shifts every point of a movement's shape by [dx], [dy], as if dragged in Generator.
String _dragShape(String text, int dx, int dy, {bool firstOnly = false}) {
  var first = true;
  return text.replaceAllMapped(RegExp(r'^(Point_\d+) = (-?\d+),(-?\d+)', multiLine: true), (m) {
    if (firstOnly && !first) return m[0]!;
    first = false;
    return '${m[1]} = ${int.parse(m[2]!) + dx},${int.parse(m[3]!) + dy}';
  });
}

void main() {
  if (paritySkip != null) {
    test('aim parity', skip: paritySkip, () {});
    return;
  }
  final real = ShowEnv(realShowPath!);
  final movers = showMovers(real);
  final a140 = movers.firstWhere((m) => m.is140), b140 = movers.where((m) => m.is140).elementAt(2), a251 = movers.firstWhere((m) => !m.is140);
  final pairs = trussPartners(real, movers);

  // tonight's aims: two 140s with a center, one with a corner too, and a 251
  final aims = {
    a140.id: const LiveAim(c: (24000, 48000), k: (20000, 52000)),
    b140.id: const LiveAim(c: (21800, 50300)),
    a251.id: const LiveAim(c: (33000, 11000), k: (28800, 16500)),
  };
  void aimed(ShowEnv env) => aimLiveSave(env, AimMode.floor, aims);
  final aimsJson = {
    'aims': {for (final e in aims.entries) e.key: e.value.toJson()},
  };

  group('preview', () {
    for (final mode in AimMode.values) {
      parityTest('${mode.name} as found', script: 'df_aim.ps1', args: _args('Preview', mode), dart: (env) => aimPreview(env, mode));
    }
    parityTest(
      'floor with aims, a corner and a T-bar copy',
      script: 'df_aim.ps1',
      args: _args('Preview', AimMode.floor),
      setup: aimed,
      dart: (env) => aimPreview(env, AimMode.floor),
    );
    parityTest(
      'floor without an aim scene',
      script: 'df_aim.ps1',
      args: _args('Preview', AimMode.floor),
      setup: (env) => env.file('scenes/DF AIM (ADJUST).scex').deleteSync(),
      dart: (env) => aimPreview(env, AimMode.floor),
    );
    parityTest(
      'refuses without a MOVEMENTS page',
      script: 'df_aim.ps1',
      args: _args('Preview', AimMode.floor),
      setup: (env) => _edit(env, 'Live/live.ini', (t) => t.replaceAll(RegExp('movement', caseSensitive: false), 'MOVES')),
      dart: (env) => aimPreview(env, AimMode.floor),
    );
  });

  group('live info', () {
    for (final mode in AimMode.values) {
      parityTest('${mode.name} as found', script: 'df_aim.ps1', args: _args('LiveInfo', mode), dart: (env) => aimLiveInfo(env, mode));
    }
    parityTest(
      'floor with aims and a reversed head',
      script: 'df_aim.ps1',
      args: _args('LiveInfo', AimMode.floor),
      setup: (env) {
        aimed(env);
        env
            .file('flip_state.json')
            .writeAsStringSync(
              jsonEncode({
                'heads': {
                  a140.id: {'pan': true, 'tilt': false},
                },
              }),
            );
      },
      dart: (env) => aimLiveInfo(env, AimMode.floor),
    );
  });

  group('apply', () {
    for (final mode in AimMode.values) {
      parityTest(
        '${mode.name} at 100 as found',
        script: 'df_aim.ps1',
        args: _args('Apply', mode, {'NoPrompt': true}),
        options: _opts,
        dart: (env) => aimApply(env, mode),
      );
    }
    parityTest(
      'floor with aims at 120 x 90',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': '120 90'}),
      setup: aimed,
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, size: '120 90'),
    );
    parityTest(
      'floor again with the same aims changes nothing',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': '120 90'}),
      setup: (env) {
        aimed(env);
        aimApply(env, AimMode.floor, size: '120 90');
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, size: '120 90'),
    );
    parityTest(
      'floor resize from 120 to 80 starts from the original shapes',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': '80'}),
      setup: (env) => aimApply(env, AimMode.floor, size: '120'),
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, size: '80'),
    );
    parityTest(
      'floor with a reversed head',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
      setup: (env) {
        aimed(env);
        env
            .file('flip_state.json')
            .writeAsStringSync(
              jsonEncode({
                'heads': {
                  a140.id: {'pan': true, 'tilt': false},
                  a251.id: {'pan': false, 'tilt': true},
                },
              }),
            );
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor),
    );
    if (pairs.isNotEmpty) {
      final one = pairs.keys.first;
      parityTest(
        'floor copies an aim to the untouched T-bar partner',
        script: 'df_aim.ps1',
        args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
        setup: (env) => aimLiveSave(env, AimMode.floor, {one: const LiveAim(c: (23400, 48800), k: (19200, 52600))}),
        options: _opts,
        dart: (env) => aimApply(env, AimMode.floor),
      );
      parityTest(
        'floor partner copy follows a new aim next time',
        script: 'df_aim.ps1',
        args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
        setup: (env) {
          aimLiveSave(env, AimMode.floor, {one: const LiveAim(c: (23400, 48800))});
          aimApply(env, AimMode.floor);
          aimLiveSave(env, AimMode.floor, {one: const LiveAim(c: (21000, 51000))});
        },
        options: _opts,
        dart: (env) => aimApply(env, AimMode.floor),
      );
    }
    parityTest(
      'floor makes a shape changed in Generator symmetrical',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': '110'}),
      setup: (env) {
        _edit(env, 'Editor/Generator/projects/251 DANCE.gpj', (t) => _dragShape(t, 700, -300, firstOnly: true));
        _edit(env, 'Editor/Generator/projects/ZIG ZAG.gpj', (t) => _dragShape(t, 1500, 900));
        _edit(env, 'Editor/Generator/projects/GALAXY SPIRAL.gpj', (t) => _dragShape(t, -800, 400, firstOnly: true));
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, size: '110'),
    );
    parityTest(
      'floor makes a missing check movement and an aim scene',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
      setup: (env) {
        env.file('Editor/Generator/projects/DF CHECK 251.gpj').deleteSync();
        env.file('scenes/DF AIM (ADJUST).scex').deleteSync();
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor),
    );
    parityTest(
      'floor upgrades a one-step aim scene',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
      setup: (env) {
        aimed(env);
        _edit(
          env,
          'scenes/DF AIM (ADJUST).scex',
          (t) => t.replaceFirstMapped(RegExp(r'(</Step>\n)\s*<Step length="300">.*?</Step>\n', dotAll: true), (m) => m[1]!),
        );
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor),
    );
    parityTest(
      'floor clips a shape that grows past the pan/tilt range',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': '300'}),
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, size: '300'),
    );
    parityTest(
      'floor applies wrong-looking aims when forced',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Force': true}),
      setup: (env) => aimLiveSave(env, AimMode.floor, {a140.id: const LiveAim(c: (65000, 49700), k: (64950, 49650))}),
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor, force: true),
    );
    parityTest(
      'floor refuses wrong-looking aims',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.floor, {'NoPrompt': true}),
      setup: (env) => aimLiveSave(env, AimMode.floor, {a140.id: const LiveAim(c: (65000, 49700))}),
      options: _opts,
      dart: (env) => aimApply(env, AimMode.floor),
    );
    for (final size in ['abc', '10', '120 90 80']) {
      parityTest(
        'refuses size "$size"',
        script: 'df_aim.ps1',
        args: _args('Apply', AimMode.floor, {'NoPrompt': true, 'Size': size}),
        options: _opts,
        dart: (env) => aimApply(env, AimMode.floor, size: size),
      );
    }
    parityTest(
      'room with aims at 110 x 130',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.room, {'NoPrompt': true, 'Size': '110 130'}),
      setup: (env) {
        final info = aimLiveInfo(env, AimMode.room);
        final h = info.heads.first, g = info.heads.last;
        aimLiveSave(env, AimMode.room, {
          h.id: LiveAim(c: (h.home.$1 + 600, h.home.$2 - 400), k: (h.dk.$1 - 300, h.dk.$2 + 500)),
          g.id: LiveAim(c: (g.home.$1 - 900, g.home.$2 + 200)),
        });
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.room, size: '110 130'),
    );
    parityTest(
      'room after AROUND ROOM was reshaped in Generator',
      script: 'df_aim.ps1',
      args: _args('Apply', AimMode.room, {'NoPrompt': true}),
      setup: (env) {
        aimApply(env, AimMode.room, size: '120');
        _edit(env, 'Editor/Generator/projects/AROUND ROOM.gpj', (t) => _dragShape(t, 1200, -600));
      },
      options: _opts,
      dart: (env) => aimApply(env, AimMode.room),
    );
  });

  group('home', () {
    for (final mode in AimMode.values) {
      parityTest(
        '${mode.name} as found',
        script: 'df_aim.ps1',
        args: _args('Home', mode, {'NoPrompt': true}),
        options: _opts,
        dart: (env) => aimHome(env, mode),
      );
      parityTest(
        '${mode.name} after an apply',
        script: 'df_aim.ps1',
        args: _args('Home', mode, {'NoPrompt': true}),
        setup: (env) {
          if (mode == AimMode.floor) aimed(env);
          aimApply(env, mode, size: '115', force: true);
        },
        options: _opts,
        dart: (env) => aimHome(env, mode),
      );
    }
  });

  group('install', () {
    parityTest(
      'room buttons already there',
      script: 'df_aim.ps1',
      args: _args('Install', AimMode.room),
      options: _opts,
      dart: (env) => aimInstall(env, AimMode.room),
    );
    parityTest(
      'room buttons and ROOM CHECK made again',
      script: 'df_aim.ps1',
      args: _args('Install', AimMode.room),
      setup: (env) {
        env.file('Editor/Generator/projects/ROOM CHECK.gpj').deleteSync();
        _edit(env, 'Live/live.ini', (t) {
          // drop both buttons' sections
          final nl = t.contains('\r\n') ? '\r\n' : '\n';
          final out = <String>[];
          var skip = false;
          final lines = t.split(RegExp(r'\r?\n'));
          for (var i = 0; i < lines.length; i++) {
            final l = lines[i];
            if (l.startsWith('[')) {
              final next = lines.skip(i + 1).takeWhile((x) => !x.startsWith('['));
              skip = next.any((x) => x == 'name = ROOM AIM (ADJUST).scex' || x == 'name = ROOM CHECK.gpj');
            }
            if (!skip) out.add(l);
          }
          return out.join(nl);
        });
      },
      options: _opts,
      dart: (env) => aimInstall(env, AimMode.room),
    );
    parityTest(
      'refuses without a SETUP page',
      script: 'df_aim.ps1',
      args: _args('Install', AimMode.room),
      setup: (env) => _edit(env, 'Live/live.ini', (t) => t.replaceAll(RegExp(r'^name = SETUP$', multiLine: true), 'name = SET UP')),
      options: _opts,
      dart: (env) => aimInstall(env, AimMode.room),
    );
  });

  group('rebuild', () {
    parityTest('as found', script: 'df_aim.ps1', args: {'Action': 'Rebuild'}, options: _opts, dart: aimRebuild);
    parityTest(
      'after GRAND ENTRANCE.gpj changed',
      script: 'df_aim.ps1',
      args: {'Action': 'Rebuild'},
      setup: (env) => _edit(
        env,
        'Editor/Generator/projects/GRAND ENTRANCE.gpj',
        (t) => _dragShape(t, 300, 200).replaceFirst(RegExp(r'^OffsetPan = -?\d+', multiLine: true), 'OffsetPan = 1500'),
      ),
      options: _opts,
      dart: aimRebuild,
    );
  });

  group('live save', () {
    parityTest(
      'floor aims',
      script: 'df_aim.ps1',
      args: _args('LiveSave', AimMode.floor),
      changes: aimsJson,
      options: _opts,
      dart: (env) => aimLiveSave(env, AimMode.floor, aims),
    );
    final mixed = {
      'aims': {
        a140.id: {
          'c': [100, 70000],
          'k': [5000, 6000],
        },
        '999999': {
          'c': [1, 2],
        },
        b140.id: {
          'c': ['12', 13],
          'k': null,
        },
        a251.id: {
          'c': [1.5, 2],
        },
      },
    };
    parityTest(
      'keeps only whole numbers in range',
      script: 'df_aim.ps1',
      args: _args('LiveSave', AimMode.floor),
      changes: mixed,
      options: _opts,
      dart: (env) => aimLiveSave(env, AimMode.floor, {
        for (final e in (mixed['aims'] as Map<String, Object?>).entries) e.key: LiveAim.fromJson((e.value as Map).cast<String, Object?>()),
      }),
    );
    parityTest(
      'nothing aimed',
      script: 'df_aim.ps1',
      args: _args('LiveSave', AimMode.room),
      changes: {'aims': <String, Object>{}},
      options: _opts,
      dart: (env) => aimLiveSave(env, AimMode.room, const {}),
    );
    parityTest(
      'makes the room aim scene when it is missing',
      script: 'df_aim.ps1',
      args: _args('LiveSave', AimMode.room),
      changes: {'aims': <String, Object>{}},
      setup: (env) => File('${env.root}/scenes/ROOM AIM (ADJUST).scex').deleteSync(),
      options: _opts,
      dart: (env) => aimLiveSave(env, AimMode.room, const {}),
    );
  });
}
