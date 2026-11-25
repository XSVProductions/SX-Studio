// Old versus new on the real show: `move_edit.ps1` against its Dart port, and
// the movement maths against the SX Player's own C# (player.ps1 LoadMove/Eval).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

const script = 'move_edit.ps1';

String gdir(String root) => p.join(root, 'Editor', 'Generator', 'projects');

/// The real show's movements, read once (never written).
final MoveList realList = moveList(ShowEnv(realShowPath!));
final List<MoveDoc> realDocs = [for (final m in realList.moves) moveOpen(ShowEnv(realShowPath!), m.file)];

/// Copies get the time they were copied. Give the movements back their own,
/// so List's "at" compares for real.
void keepTimes(ShowEnv env) {
  for (final f in Directory(gdir(realShowPath!)).listSync().whereType<File>()) {
    final c = File(p.join(gdir(env.root), p.basename(f.path)));
    if (c.existsSync()) c.setLastModifiedSync(f.lastModifiedSync());
  }
}

String shaOf(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

/// A change to [d] that touches what it can: cycle, shift, transition, the
/// points (each moved a little, one added), and the heads' aim and size when
/// Aim Movers doesn't own them.
Map<String, Object?> bigChange(MoveDoc d) => {
  'move': d.file,
  'sha': d.sha,
  'secs': [
    for (final s in d.secs)
      {
        'name': s.name,
        if (s.has.contains('Duration')) 'dur': s.dur.round() + 7,
        if (s.has.contains('Shift')) 'shift': 12.5,
        if (s.has.contains('Transition')) 'tr': (s.tr + 1) % 3,
        if (!s.locked && s.pts.isNotEmpty)
          'pts': [
            for (final (x, y) in s.pts) [(x + 101).clamp(0, 65535), (y + 57).clamp(0, 65535)],
            [1000, 2000],
          ],
      },
  ],
  'heads': [
    if (d.aim.isEmpty)
      for (final h in d.heads) {'k': h.k, if (h.has.contains('OffsetPan')) 'op': h.op.round() - 300, if (h.has.contains('ZoomTilt')) 'zt': 25},
  ],
};

// ---------------------------------------------------------------- a run of saves and reverts, backups included

/// One step of a save/revert run. Backup ids are picked by place in the
/// newest-first list, since the two sides make them at different times.
sealed class Step {}

class SaveStep extends Step {
  SaveStep(this.changes);

  /// `sha` is filled in from the file as it is when the step runs, unless given.
  final Map<String, Object?> changes;
}

class RevertStep extends Step {
  RevertStep(this.move, this.index, {this.force = false});

  final String move;
  final int index;
  final bool force;
}

/// Render [changes] into `_render.gpj` in the show copy, so it is compared too.
class RenderStep extends Step {
  RenderStep(this.changes);

  final Map<String, Object?> changes;
}

class BackupsStep extends Step {
  BackupsStep(this.move);

  final String move;
}

final _id = RegExp(r'\d{8}-\d{6}-\d{3}');
final _at = RegExp(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d');

/// Backup ids and times are timestamps: masked, and nothing else.
String maskStamps(String s) => s.replaceAll(_id, '<id>').replaceAll(_at, '<at>');

List<String> backupIds(String base, String move) {
  final d = Directory(p.join(base, 'show', move));
  if (!d.existsSync()) return const [];
  return {for (final f in d.listSync().whereType<File>()) p.basenameWithoutExtension(f.path)}.toList()..sort((a, b) => b.compareTo(a));
}

void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}

/// Every file under [dir], backup ids renamed by their order and backup times masked.
Map<String, String> snapshot(Directory dir) {
  final out = <String, String>{};
  if (!dir.existsSync()) return out;
  final files = dir.listSync(recursive: true).whereType<File>().toList();
  final ids = <String, Map<String, String>>{};
  for (final f in files) {
    final m = _id.firstMatch(p.basename(f.path));
    if (m != null) ids.putIfAbsent(f.parent.path, () => {})[m[0]!] = '';
  }
  for (final e in ids.entries) {
    final sorted = e.value.keys.toList()..sort();
    for (final (i, id) in sorted.indexed) {
      e.value[id] = 'backup$i';
    }
  }
  for (final f in files) {
    var rel = p.relative(f.path, from: dir.path);
    final m = _id.firstMatch(p.basename(f.path));
    if (m != null) rel = rel.replaceFirst(m[0]!, ids[f.parent.path]![m[0]!]!);
    final bytes = f.readAsBytesSync();
    out[rel] = rel.endsWith('.json') && m != null ? utf8.decode(bytes).replaceAll(_at, '<at>') : base64.encode(sha256.convert(bytes).bytes);
  }
  return out;
}

void runParity(String name, List<Step> steps, {void Function(ShowEnv env)? setup}) {
  test(name, skip: paritySkip, timeout: const Timeout(Duration(minutes: 5)), () async {
    final tmp = Directory.systemTemp.createTempSync('sx_move_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final show = Directory(p.join(tmp.path, 'show')), backups = p.join(tmp.path, 'move_backups');
    void fresh() {
      if (show.existsSync()) show.deleteSync(recursive: true);
      if (Directory(backups).existsSync()) Directory(backups).deleteSync(recursive: true);
      copyDir(Directory(realShowPath!), show);
      setup?.call(ShowEnv(show.path));
    }

    String withSha(Map<String, Object?> ch) {
      final c = {...ch};
      final f = File(p.join(gdir(show.path), '${c['move']}'));
      c['sha'] ??= f.existsSync() ? shaOf(f.path) : '';
      final cf = File(p.join(tmp.path, 'changes.json'))..writeAsStringSync(jsonEncode(c));
      return cf.path;
    }

    // The old tool.
    fresh();
    final oldOut = <String>[];
    for (final s in steps) {
      final r = switch (s) {
        SaveStep(:final changes) => await runOld(script, {'Action': 'Save', 'ChangesFile': withSha(changes), 'TestRoot': show.path}),
        RevertStep(:final move, :final index, :final force) => await runOld(script, {
          'Action': 'Revert',
          'Move': move,
          'Backup': backupIds(backups, move)[index],
          if (force) 'Force': true,
          'TestRoot': show.path,
        }),
        BackupsStep(:final move) => await runOld(script, {'Action': 'Backups', 'Move': move, 'TestRoot': show.path}),
        RenderStep(:final changes) => await runOld(script, {
          'Action': 'Render',
          'ChangesFile': withSha(changes),
          'Out': p.join(show.path, '_render.gpj'),
          'TestRoot': show.path,
        }),
      };
      oldOut.add(r.error != null ? 'ERROR ${r.error}' : r.stdout.replaceAll('\r\n', '\n').trimRight());
    }
    final oldFiles = {...snapshot(show), for (final e in snapshot(Directory(backups)).entries) 'backups/${e.key}': e.value};

    // The port, on a fresh copy, with a clock that moves a second per backup.
    fresh();
    var t = DateTime(2026, 11, 24, 21, 0, 0, 5);
    final env = ShowEnv(show.path, now: () => t = t.add(const Duration(seconds: 1)));
    final newOut = <String>[];
    for (final s in steps) {
      try {
        newOut.add(switch (s) {
          SaveStep(:final changes) => moveSave(env, jsonDecode(File(withSha(changes)).readAsStringSync()) as Map<String, Object?>, backups: backups),
          RevertStep(:final move, :final index, :final force) => switch (moveRevert(
            env,
            move,
            backupIds(backups, move)[index],
            force: force,
            backups: backups,
          )) {
            MoveRevertConflict() => '{"conflict":true}\n  The movement was changed after that save (in ShowXpress or SX Studio). Revert anyway?',
            MoveReverted(:final out) => out,
          },
          BackupsStep(:final move) => jsonEncode(moveBackups(env, move, backups: backups).toJson()),
          RenderStep(:final changes) => moveRender(env, changes, p.join(show.path, '_render.gpj')),
        });
      } on ToolError catch (e) {
        newOut.add('ERROR ${e.message}');
      }
    }
    final newFiles = {...snapshot(show), for (final e in snapshot(Directory(backups)).entries) 'backups/${e.key}': e.value};

    for (var i = 0; i < steps.length; i++) {
      if (steps[i] is BackupsStep && !oldOut[i].startsWith('ERROR')) {
        Object? fix(String s) => jsonDecode(maskStamps(s));
        expect(fix(newOut[i]), fix(oldOut[i]), reason: 'step ${i + 1} (backups)');
      } else {
        expect(maskStamps(newOut[i].trimRight()), maskStamps(oldOut[i]), reason: 'step ${i + 1}');
      }
    }
    final diff = [
      for (final k in {...oldFiles.keys, ...newFiles.keys})
        if (oldFiles[k] != newFiles[k])
          '$k: ${oldFiles.containsKey(k) ? (newFiles.containsKey(k) ? 'differs' : 'only the old tool wrote it') : 'only the port wrote it'}',
    ];
    expect(diff, isEmpty, reason: 'files after the run');
  });
}

// ---------------------------------------------------------------- the SX Player's own movement code

const _pinScript = r'''
param([string]$Root, [string]$Job, [string]$Player)
$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText($Player)
$a = $src.IndexOf('  // ---------------------------------------------------------------- movements (.gpj)')
$b = $src.IndexOf('  // ---------------------------------------------------------------- the live board')
$cs = "using System; using System.Collections.Generic; using System.IO;`npublic static class SxMove {`n public const int N = 512 * 16;`n static Dictionary<string, int> addr = new Dictionary<string, int>();`n public static void Patch(string id, int a) { addr[id] = a; }`n" + $src.Substring($a, $b - $a) + "}`n"
Add-Type -TypeDefinition $cs
$pa = $null
foreach ($l in [IO.File]::ReadAllLines("$Root/fixtures.ini")) {
  if ($l -match '^\[') { $pa = $null }
  elseif ($l -match '^address = (\d+)\s*$') { $pa = [int]$matches[1] }
  elseif ($l -match '^id = (\d+)\s*$' -and $pa) { [SxMove]::Patch($matches[1], $pa) }
}
$f = New-Object byte[] 8192
foreach ($j in ([IO.File]::ReadAllText($Job) | ConvertFrom-Json)) {
  $m = $null; try { $m = [SxMove]::LoadMove((Join-Path "$Root/Editor/Generator/projects" $j.file)) } catch { "$($j.file)`tERR`t$($_.Exception.InnerException.Message)"; continue }
  foreach ($t in $j.times) {
    [Array]::Clear($f, 0, $f.Length); [void][SxMove]::Eval($m, [double]$t, $f)
    $o = @(for ($i = 0; $i -lt $f.Length; $i++) { if ($f[$i]) { "$($i + 1):$($f[$i])" } }) -join ' '
    "$($j.file)`t$t`t$o"
  }
}
''';

/// Times to sample a movement at: across two cycles of its shape, plus a few odd ones.
List<double> sampleTimes(MoveDoc d) {
  final pt = d.secs.where((s) => s.name == movePtSection).firstOrNull;
  final cycle = (pt?.dur ?? 200) * 100;
  return [for (var i = 0; i < 40; i++) i * cycle / 20, 1.5, 333.3, 12345.678, 99999.5];
}

void main() {
  group('reading', () {
    if (paritySkip != null) return;
    parityTest('List', script: script, args: {'Action': 'List'}, setup: keepTimes, dart: moveList);
    parityTest('Check: every movement reads back byte for byte', script: script, args: {'Action': 'Check'}, dart: (env) => moveCheck(env));

    for (final m in realList.moves) {
      parityTest('Open ${m.file}', script: script, args: {'Action': 'Open', 'Move': m.file}, dart: (env) => moveOpen(env, m.file));
    }
    parityTest('Open: a name that is not a movement', script: script, args: {'Action': 'Open', 'Move': '../x.gpj'}, dart: (env) => moveOpen(env, '../x.gpj'));
    parityTest('Open: a movement that is not there', script: script, args: {'Action': 'Open', 'Move': 'NOPE.gpj'}, dart: (env) => moveOpen(env, 'NOPE.gpj'));

    // A key twice in a head's section: the old tool stops with a PowerShell
    // error (it marks a property the head object doesn't have). Kept as it was.
    void twice(ShowEnv env) {
      final f = File(p.join(gdir(env.root), realList.moves.first.file));
      f.writeAsStringSync(f.readAsStringSync().replaceFirst(RegExp(r'(\[Fixture_\d+\]\r?\n)'), r'$1Name = twice\n'));
    }

    parityTest(
      'a head with a key twice: Open fails like the old tool',
      script: script,
      args: {'Action': 'Open', 'Move': realList.moves.first.file},
      setup: twice,
      dart: (env) => moveOpen(env, realList.moves.first.file),
    );
    parityTest(
      'a head with a key twice: List marks it read only',
      script: script,
      args: {'Action': 'List'},
      setup: (env) {
        twice(env);
        keepTimes(env);
      },
      dart: moveList,
    );
  });

  group('render', () {
    if (paritySkip != null) return;
    for (final d in realDocs) {
      runParity('Render ${d.file}', [RenderStep(bigChange(d))]);
    }
  });

  group('save', () {
    if (paritySkip != null) return;
    final editable = realDocs.where((d) => d.readonly.isEmpty).toList();
    final floor = editable.firstWhere((d) => d.aim == 'floor'), room = editable.firstWhere((d) => d.aim == 'room');
    final free = editable.firstWhere((d) => d.aim.isEmpty && d.heads.any((h) => h.has.contains('OffsetPan')));
    final valueSec = free.secs.where((s) => s.name != movePtSection && s.has.contains('Selected')).firstOrNull;

    runParity('a save with no changes leaves every file as it was, for every movement', [
      for (final d in realDocs) SaveStep({'move': d.file, 'secs': <Object>[], 'heads': <Object>[]}),
    ]);

    runParity('every value sent again unchanged leaves every file as it was', [
      for (final d in editable)
        SaveStep({
          'move': d.file,
          'secs': [
            for (final s in d.secs)
              {
                'name': s.name,
                if (s.has.contains('Selected')) 'sel': s.sel,
                if (s.has.contains('Transition')) 'tr': s.tr,
                if (s.has.contains('Duration')) 'dur': s.dur.round(),
                if (!s.locked && s.pts.isNotEmpty)
                  'pts': [
                    for (final (x, y) in s.pts) [x, y],
                  ],
              },
          ],
        }),
    ]);

    runParity('a new shape on a Dance Floor movement updates Aim Movers\' record, then a revert puts it back', [
      SaveStep({
        'move': floor.file,
        'secs': [
          {
            'name': movePtSection,
            'pts': [
              [20000, 50000],
              [32000, 44000],
              [26000, 50001],
            ],
          },
        ],
      }),
      BackupsStep(floor.file),
      RevertStep(floor.file, 0),
      BackupsStep(floor.file),
    ]);

    runParity('a new shape on a Room movement', [
      SaveStep({
        'move': room.file,
        'secs': [
          {
            'name': movePtSection,
            'pts': [
              [100, 200],
              [65535, 0],
              [30000, 31000],
              [12345, 54321],
            ],
          },
        ],
      }),
    ]);

    runParity('cycle, shift, transition, on/off and head aim and size, then a smaller shape', [
      SaveStep({
        ...bigChange(free),
        'sha': null,
        'secs': [
          ...(bigChange(free)['secs'] as List).cast<Map<String, Object?>>().map((s) => s['name'] == valueSec?.name ? {...s, 'sel': 1 - valueSec!.sel} : s),
        ],
      }),
      SaveStep({
        'move': free.file,
        'secs': [
          {
            'name': movePtSection,
            'pts': [
              [1, 2],
            ],
            'shift': 0.00005,
          },
        ],
      }),
      BackupsStep(free.file),
      // The oldest backup: changed since, so it asks first, then goes back with force.
      RevertStep(free.file, 1),
      RevertStep(free.file, 1, force: true),
      RevertStep(free.file, 0, force: true),
      BackupsStep(free.file),
    ]);

    runParity('more than 20 saves keep the newest 20 backups', [
      for (var i = 0; i < 22; i++)
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'dur': 10 + i},
          ],
        }),
      BackupsStep(free.file),
    ]);

    runParity(
      'refusals',
      [
        SaveStep({
          'move': free.file,
          'sha': 'not the sha',
          'secs': [
            {'name': movePtSection, 'dur': 50},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {
              'name': movePtSection,
              'pts': [
                [0, 0],
                [70000, 1],
              ],
            },
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': 'nope', 'sel': 1},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'sel': 2},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'tr': 3},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'dur': 0},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'shift': 101},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'pts': <Object>[]},
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'dur': 50},
            {'name': movePtSection, 'dur': 60},
          ],
        }),
        SaveStep({
          'move': free.file,
          'heads': [
            {'k': 999, 'op': 1},
          ],
        }),
        SaveStep({
          'move': free.file,
          'heads': [
            {'k': free.heads.first.k, 'zp': 901},
          ],
        }),
        SaveStep({
          'move': free.file,
          'heads': [
            {'k': free.heads.first.k, 'rt': 1},
          ],
        }),
        SaveStep({
          'move': floor.file,
          'heads': [
            {'k': floor.heads.first.k, 'op': 5},
          ],
        }),
        SaveStep({
          'move': room.file,
          'heads': [
            {'k': room.heads.first.k, 'zt': 5},
          ],
        }),
        SaveStep({'move': 'NOPE.gpj'}),
        SaveStep({'move': 'a/b.gpj'}),
        RevertStep(free.file, 0),
      ],
      setup: (env) {
        // A backup to try reverting to: the file as it is, so nothing to change.
        final d = Directory(p.join(p.dirname(env.root), 'move_backups', 'show', free.file))..createSync(recursive: true);
        final f = File(p.join(gdir(env.root), free.file));
        f.copySync(p.join(d.path, '20260101-000000-000.gpj'));
        File(p.join(d.path, '20260101-000000-000.json')).writeAsStringSync('{"at":"2026-01-01 00:00:00","what":"x","written":"${shaOf(f.path)}"}');
      },
    );

    // Points not in one block: locked, but the cycle can still change.
    runParity(
      'locked points',
      [
        SaveStep({
          'move': free.file,
          'secs': [
            {
              'name': movePtSection,
              'pts': [
                [1, 1],
              ],
            },
          ],
        }),
        SaveStep({
          'move': free.file,
          'secs': [
            {'name': movePtSection, 'dur': 77},
          ],
        }),
      ],
      setup: (env) {
        final f = File(p.join(gdir(env.root), free.file));
        final t = f.readAsStringSync();
        final i = t.indexOf('Point_1 = ');
        f.writeAsStringSync('${t.substring(0, i)}CurveName = x\n${t.substring(i)}');
      },
    );
  });

  group('the curve, against the SX Player', () {
    test('every movement of the real show, sampled over two cycles', skip: paritySkip, () async {
      final tmp = Directory.systemTemp.createTempSync('sx_move_pin_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final job = File(p.join(tmp.path, 'job.json'))
        ..writeAsStringSync(
          jsonEncode([
            for (final d in realDocs) {'file': d.file, 'times': sampleTimes(d)},
          ]),
        );
      final ps = File(p.join(tmp.path, 'pin.ps1'))..writeAsStringSync(_pinScript);
      final r = await Process.run(pwshPath!, [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        ps.path,
        '-Root',
        realShowPath!,
        '-Job',
        job.path,
        '-Player',
        p.join(oldSrcPath!, 'player.ps1'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final old = <String, String>{};
      for (final l in const LineSplitter().convert(r.stdout as String)) {
        final c = l.split('\t');
        old['${c[0]}\t${c[1]}'] = c.length > 2 ? c[2] : '';
      }
      var compared = 0;
      for (final d in realDocs) {
        if (d.readonly.isNotEmpty || old.containsKey('${d.file}\tERR')) continue;
        final st = MoveState.of(d);
        for (final t in sampleTimes(d)) {
          final f = moveFrame(d, st, t, player: true);
          final mine = [
            for (final k in f.keys.toList()..sort())
              if (f[k] != 0) '$k:${f[k]}',
          ].join(' ');
          final key = '${d.file}\t${psText(t)}';
          expect(mine, old[key], reason: '${d.file} at $t ms');
          compared++;
        }
      }
      expect(compared, greaterThan(500));
    });
  });
}

/// `"$t"` the way the pin script prints a time.
String psText(double t) => t == t.truncateToDouble() ? t.toInt().toString() : '$t';
