import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

// Old versus new for the Scene Editor on the real show. Saves keep backups
// next to the show folder (the old tool's -TestRoot layout), so these cases
// compare that folder too, not just the show.

String _backupBase(ShowEnv env) => p.join(p.dirname(env.root), 'scene_backups');

void _copyDir(Directory from, Directory to) {
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

final _idRx = RegExp(r'\d{8}-\d{6}-\d{3}');
final _atRx = RegExp(r'"at":"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d"');

/// Every file under [dir], with backup ids made stable: the n-th id (oldest
/// first) of a run becomes `ID<n>`, and the time a backup was taken is masked.
/// Ids from before 2021 come from a setup with a fixed clock and are kept.
Map<String, List<int>> _snapshot(Directory dir) {
  final files = dir.listSync(recursive: true).whereType<File>().toList();
  final ids = {for (final f in files) ..._idRx.allMatches(p.relative(f.path, from: dir.path)).map((m) => m[0]!)}.where((i) => !i.startsWith('2020')).toList()
    ..sort();
  String mask(String s) => s.replaceAllMapped(_idRx, (m) => ids.contains(m[0]) ? 'ID${ids.indexOf(m[0]!)}' : m[0]!);
  return {
    for (final f in files)
      mask(p.relative(f.path, from: dir.path)): f.path.endsWith('.json') && f.path.contains('scene_backups')
          ? utf8.encode(utf8.decode(forCompare(f.path, f.readAsBytesSync())).replaceAll(_atRx, '"at":"AT"'))
          : forCompare(f.path, f.readAsBytesSync()),
  };
}

String _diff(Map<String, List<int>> a, Map<String, List<int>> b) {
  final out = <String>[];
  for (final k in {...a.keys, ...b.keys}) {
    if (!b.containsKey(k)) out.add('only the old tool wrote: $k');
    if (!a.containsKey(k)) out.add('only the Dart port wrote: $k');
    if (a.containsKey(k) && b.containsKey(k) && !_same(a[k]!, b[k]!)) {
      final x = utf8.decode(a[k]!, allowMalformed: true), y = utf8.decode(b[k]!, allowMalformed: true);
      var i = 0;
      while (i < x.length && i < y.length && x[i] == y[i]) {
        i++;
      }
      out.add(
        'differs: $k at char $i\n  old: ${jsonEncode(x.substring(i, (i + 80).clamp(0, x.length)))}\n  new: ${jsonEncode(y.substring(i, (i + 80).clamp(0, y.length)))}',
      );
    }
  }
  return out.join('\n');
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _tidy(String t) => t.replaceAll('\r\n', '\n').split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).join('\n').replaceAll(_idRx, 'ID');

/// One Save or Revert, old versus new: same report (or refusal), same show
/// folder and same backups, byte for byte.
void sceneParity(
  String name, {
  required Map<String, Object> args,
  SceneChanges Function(ShowEnv env)? changes,
  required Object? Function(ShowEnv env, String backups) dart,
  void Function(ShowEnv env, String backups)? setup,
  Pattern? expectOut,
}) {
  test(name, skip: paritySkip, () async {
    final tmp = Directory.systemTemp.createTempSync('sx_scene_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final work = Directory(p.join(tmp.path, 'w'));
    final show = p.join(work.path, 'show');
    ShowEnv fresh() {
      if (work.existsSync()) work.deleteSync(recursive: true);
      _copyDir(Directory(realShowPath!), Directory(show));
      final env = ShowEnv(show);
      setup?.call(ShowEnv(show, now: () => DateTime(2020, 1, 1, 12)), _backupBase(env));
      return env;
    }

    var env = fresh();
    final psArgs = {...args, 'TestRoot': show};
    if (changes != null) {
      final cf = File(p.join(tmp.path, 'changes.json'))..writeAsStringSync(jsonEncode(changes(env).toJson()));
      psArgs['ChangesFile'] = cf.path;
    }
    final old = await runOld('scene_edit.ps1', psArgs);
    final oldFiles = _snapshot(work);

    env = fresh();
    Object? answer;
    String? error;
    try {
      answer = dart(env, _backupBase(env));
    } on ToolError catch (e) {
      error = e.message;
    }
    final newFiles = _snapshot(work);
    if (old.error != null || error != null) {
      expect(error, old.error, reason: 'error message (old stderr: ${old.stderr.trim()})');
    } else {
      expect(_tidy('$answer'), _tidy(old.stdout), reason: 'text report');
    }
    if (expectOut != null) expect(old.error ?? old.stdout, contains(expectOut), reason: 'what the old tool did');
    final d = _diff(oldFiles, newFiles);
    if (d.isNotEmpty) fail('Files differ after the run.\n$d');
  });
}

/// Runs the old tool once per scene in a single PowerShell session and
/// returns each scene's last output line (or `ERR:` and the message).
Future<Map<String, String>> _oldPerScene(String show, String action) async {
  final script = p.join(oldSrcPath!, 'scene_edit.ps1');
  final names = [
    for (final f in Directory(p.join(show, 'scenes')).listSync().whereType<File>())
      if (f.path.endsWith('.scex')) p.basename(f.path),
  ]..sort();
  final out = <String, String>{};
  // in batches, so one command line never gets too long
  for (var i = 0; i < names.length; i += 40) {
    final batch = names.sublist(i, (i + 40).clamp(0, names.length));
    final list = batch.map((n) => "'${n.replaceAll("'", "''")}'").join(',');
    final call = action == 'Open'
        ? "& '$script' -Action Open -Scene \$n -TestRoot '$show'"
        : "& '$script' -Action Save -ChangesFile (Join-Path '${p.join(show, '..', 'changes')}' (\$n + '.json')) -TestRoot '$show'";
    final cmd =
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ErrorActionPreference='Stop'; "
        "foreach (\$n in @($list)) { try { \$o = @($call) | Select-Object -Last 1; 'SXOUT:' + \$n + '|' + \$o } catch { 'SXOUT:' + \$n + '|ERR:' + \$_.Exception.Message } }";
    final r = await Process.run(pwshPath!, ['-NoProfile', '-NonInteractive', '-Command', cmd], stdoutEncoding: utf8, stderrEncoding: utf8);
    for (final l in const LineSplitter().convert(r.stdout as String)) {
      if (!l.startsWith('SXOUT:')) continue;
      final bar = l.indexOf('|');
      out[l.substring(6, bar)] = l.substring(bar + 1);
    }
  }
  return out;
}

/// The real show's scenes, read through the port.
SceneOpen _open(ShowEnv env, String file) => sceneOpen(env, file, backupBase: _backupBase(env));

void main() {
  Object? noAt(Object? j) {
    for (final s in (j as Map)['scenes'] as List) {
      (s as Map)['at'] = 'masked';
    }
    return j;
  }

  // the file times of two copies of the show differ by the copying
  parityTest(
    'List',
    script: 'scene_edit.ps1',
    args: {'Action': 'List'},
    dart: sceneList,
    options: ParityOptions(rewriteJson: noAt),
  );
  parityTest('Check: every scene reads back byte for byte', script: 'scene_edit.ps1', args: {'Action': 'Check'}, dart: sceneCheck);

  test('Open matches for every scene', skip: paritySkip, timeout: const Timeout(Duration(minutes: 5)), () async {
    final tmp = Directory.systemTemp.createTempSync('sx_scene_open_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final show = p.join(tmp.path, 'show');
    _copyDir(Directory(realShowPath!), Directory(show));
    final old = await _oldPerScene(show, 'Open');
    final env = ShowEnv(show);
    expect(old.length, Directory(p.join(show, 'scenes')).listSync().where((f) => f.path.endsWith('.scex')).length);
    for (final e in old.entries) {
      final mine = jsonDecode(jsonEncode(_open(env, e.key)));
      expect(mine, jsonDecode(e.value), reason: e.key);
    }
  });

  test('Save with no changes leaves every scene byte for byte the same', skip: paritySkip, timeout: const Timeout(Duration(minutes: 5)), () async {
    final tmp = Directory.systemTemp.createTempSync('sx_scene_same_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final work = Directory(p.join(tmp.path, 'w')), show = p.join(work.path, 'show');
    _copyDir(Directory(realShowPath!), Directory(show));
    final env = ShowEnv(show);
    final all = <String, SceneChanges>{};
    Directory(p.join(work.path, 'changes')).createSync();
    for (final f in Directory(p.join(show, 'scenes')).listSync().whereType<File>().where((f) => f.path.endsWith('.scex'))) {
      final name = p.basename(f.path);
      final o = _open(env, name);
      final c = SceneChanges(
        scene: name,
        sha: o.sha,
        steps: [for (var i = 0; i < (o.steps?.length ?? 1); i++) SceneStepChange(src: i)],
      );
      all[name] = c;
      File(p.join(work.path, 'changes', '$name.json')).writeAsStringSync(jsonEncode(c.toJson()));
    }
    final before = _snapshot(work);
    final old = await _oldPerScene(show, 'Save');
    expect(_diff(before, _snapshot(work)), '', reason: 'the old tool changed files');
    for (final e in all.entries) {
      String mine;
      try {
        mine = sceneSave(env, e.value, backupBase: _backupBase(env));
      } on ToolError catch (x) {
        mine = 'ERR:${x.message}';
      }
      expect(mine, old[e.key], reason: e.key);
    }
    expect(_diff(before, _snapshot(work)), '', reason: 'the port changed files');
  });

  group('Save', () {
    if (paritySkip != null) return;
    final probe = ShowEnv(realShowPath!);
    final scenes = [for (final s in sceneList(probe).scenes) _open(probe, s.file)].where((o) => o.readonly.isEmpty && o.structural).toList();
    // the scene with the most steps, and one with a single step if there is one
    final big = (scenes.toList()..sort((a, b) => b.steps!.length.compareTo(a.steps!.length))).first;
    final small = scenes.firstWhere((o) => o.steps!.length == 1, orElse: () => scenes.last);
    final pick = [big, if (small.file != big.file) small];

    SceneChanges same(SceneOpen o) => SceneChanges(
      scene: o.file,
      sha: o.sha,
      steps: [for (var i = 0; i < o.steps!.length; i++) SceneStepChange(src: i)],
    );

    /// The first channel with a plain value: (step, head id, channel).
    (int, String, SceneChannel) firstValue(SceneOpen o) {
      for (final (i, s) in o.steps!.indexed) {
        for (final f in s.fx) {
          for (final c in f.ch) {
            if (c.v >= 0 && c.ix >= 0) return (i, f.id, c);
          }
        }
      }
      throw StateError('no channel in ${o.file}');
    }

    void save(
      String name,
      SceneChanges Function(SceneOpen o) make, {
      SceneOpen? scene,
      void Function(ShowEnv env, String backups)? setup,
      String expect = 'CHANGED',
    }) {
      for (final o in scene == null ? pick : [scene]) {
        sceneParity(
          '$name (${o.name}, ${o.steps!.length} steps)',
          args: {'Action': 'Save'},
          setup: setup,
          expectOut: expect,
          changes: (env) => make(setup == null ? o : _open(env, o.file)),
          dart: (env, b) => sceneSave(env, make(setup == null ? o : _open(env, o.file)), backupBase: b),
        );
      }
    }

    save('change a value', (o) {
      final (i, fx, c) = firstValue(o);
      final steps = same(o).steps.toList();
      steps[i] = SceneStepChange(
        src: i,
        set: [SceneSet(fx: fx, ix: c.ix, v: (c.v + 1) % 256)],
      );
      return SceneChanges(scene: o.file, sha: o.sha, steps: steps);
    });
    save('fade on and off', (o) {
      final (i, fx, c) = firstValue(o);
      final steps = same(o).steps.toList();
      steps[i] = SceneStepChange(
        src: i,
        set: [SceneSet(fx: fx, ix: c.ix, fade: !c.fade)],
      );
      return SceneChanges(scene: o.file, sha: o.sha, steps: steps);
    });
    save(
      'add a step (a copy of the first, at the end)',
      (o) => SceneChanges(scene: o.file, sha: o.sha, steps: [...same(o).steps, const SceneStepChange(src: 0)]),
    );
    save(
      'delete a step',
      (o) => SceneChanges(
        scene: o.file,
        sha: o.sha,
        steps: [
          for (final s in same(o).steps)
            if (s.src != o.steps!.length - 1 || o.steps!.length == 1) s,
        ],
      ),
      scene: big,
    );
    save(
      'reorder steps',
      (o) => SceneChanges(scene: o.file, sha: o.sha, steps: [...same(o).steps.reversed]),
      scene: big,
    );
    save('change a length', (o) {
      final steps = same(o).steps.toList();
      steps[0] = SceneStepChange(src: 0, len: (o.steps![0].len ?? 100) + 7);
      return SceneChanges(scene: o.file, sha: o.sha, steps: steps);
    });
    save('every edit at once', (o) {
      final (i, fx, c) = firstValue(o);
      final n = o.steps!.length;
      return SceneChanges(
        scene: o.file,
        sha: o.sha,
        steps: [
          SceneStepChange(
            src: i,
            len: 33,
            set: [SceneSet(fx: fx, ix: c.ix, v: 200, fade: true)],
          ),
          for (var k = n - 1; k >= 0; k--) SceneStepChange(src: k),
        ],
      );
    }, scene: big);

    // a channel taken out of one head in every step, and one added back to another head
    final head = big.heads!.first;
    final model = big.models![head.model]!;
    final has = {for (final s in big.steps!) ...s.fx.where((f) => f.id == head.id).expand((f) => f.ch.map((c) => c.ix))};
    final drop = has.reduce((a, b) => a > b ? a : b);
    final missing = model.chans.where((c) => !has.contains(c.ix)).firstOrNull;
    save(
      'take a channel out',
      (o) => SceneChanges(
        scene: o.file,
        sha: o.sha,
        steps: same(o).steps,
        delch: [SceneChannelRef(fx: head.id, ix: drop)],
      ),
      scene: big,
    );
    if (missing != null) {
      save('add a channel, set in one step', (o) {
        final steps = same(o).steps.toList();
        final at = o.steps!.indexWhere((s) => s.fx.any((f) => f.id == head.id));
        steps[at] = SceneStepChange(
          src: at,
          set: [SceneSet(fx: head.id, ix: missing.ix, v: 77, fade: true)],
        );
        return SceneChanges(
          scene: o.file,
          sha: o.sha,
          steps: steps,
          addch: [SceneChannelRef(fx: head.id, ix: missing.ix)],
        );
      }, scene: big);
    }

    // old-app bug, kept: two channels added into the same gap are refused by the self-check
    final gapPair = () {
      final miss = [
        for (final c in model.chans)
          if (!has.contains(c.ix)) c.ix,
      ]..sort();
      for (var i = 0; i + 1 < miss.length; i++) {
        if (!has.any((h) => h > miss[i] && h < miss[i + 1])) return (miss[i], miss[i + 1]);
      }
      return null;
    }();
    if (gapPair != null) {
      save(
        'two channels added into the same gap (old bug: refused)',
        (o) => SceneChanges(
          scene: o.file,
          sha: o.sha,
          steps: same(o).steps,
          addch: [
            SceneChannelRef(fx: head.id, ix: gapPair.$1),
            SceneChannelRef(fx: head.id, ix: gapPair.$2),
          ],
        ),
        scene: big,
        expect: 'two ways',
      );
    }
    save('nothing to change', same, expect: 'nothing to change');
    save(
      'refused: the file changed since',
      (o) => SceneChanges(scene: o.file, sha: 'f' * 64, steps: same(o).steps),
      expect: 'changed since',
    );
    save(
      'refused: a value over 255',
      (o) {
        final (i, fx, c) = firstValue(o);
        final steps = same(o).steps.toList();
        steps[i] = SceneStepChange(
          src: i,
          set: [SceneSet(fx: fx, ix: c.ix, v: 300)],
        );
        return SceneChanges(scene: o.file, sha: o.sha, steps: steps);
      },
      scene: big,
      expect: '0 to 255',
    );
    save(
      'refused: a head that is not in the scene',
      (o) {
        final steps = same(o).steps.toList();
        steps[0] = const SceneStepChange(src: 0, set: [SceneSet(fx: '999', ix: 1, v: 1)]);
        return SceneChanges(scene: o.file, sha: o.sha, steps: steps);
      },
      scene: big,
      expect: 'is not in step',
    );

    // backups and revert: a save made in setup (with a fixed clock) and then put back
    void saveInSetup(ShowEnv env, String b) {
      final o = _open(env, big.file);
      final (i, fx, c) = firstValue(o);
      final steps = same(o).steps.toList();
      steps[i] = SceneStepChange(
        src: i,
        set: [SceneSet(fx: fx, ix: c.ix, v: (c.v + 9) % 256)],
      );
      sceneSave(
        env,
        SceneChanges(scene: o.file, sha: o.sha, steps: steps),
        backupBase: b,
      );
    }

    const setupId = '20200101-120000-000';
    sceneParity(
      'Backups lists the setup save',
      args: {'Action': 'Backups', 'Scene': big.file},
      setup: saveInSetup,
      expectOut: '20200101-120000-000',
      dart: (env, b) => jsonEncode(sceneBackups(env, big.file, backupBase: b)),
    );
    sceneParity(
      'Revert puts the earlier version back',
      args: {'Action': 'Revert', 'Scene': big.file, 'Backup': setupId},
      setup: saveInSetup,
      expectOut: 'back to the version',
      dart: (env, b) => sceneRevert(env, big.file, setupId, backupBase: b).out,
    );
    sceneParity(
      'Revert of a backup that is not there',
      args: {'Action': 'Revert', 'Scene': big.file, 'Backup': '20200101-120000-001'},
      setup: saveInSetup,
      expectOut: 'not there any more',
      dart: (env, b) => sceneRevert(env, big.file, '20200101-120000-001', backupBase: b).out,
    );
    void saveTwice(ShowEnv env, String b) {
      saveInSetup(env, b);
      saveInSetup(ShowEnv(env.root, now: () => DateTime(2020, 1, 1, 12, 0, 1)), b);
    }

    sceneParity(
      'Revert asks first when the scene was saved again since',
      args: {'Action': 'Revert', 'Scene': big.file, 'Backup': setupId},
      setup: saveTwice,
      expectOut: 'conflict',
      dart: (env, b) {
        final r = sceneRevert(env, big.file, setupId, backupBase: b);
        return r.conflict ? '{"conflict":true}\n${r.out}' : r.out;
      },
    );
    sceneParity(
      'Revert -Force goes back anyway',
      args: {'Action': 'Revert', 'Scene': big.file, 'Backup': setupId, 'Force': true},
      setup: saveTwice,
      expectOut: 'back to the version',
      dart: (env, b) => sceneRevert(env, big.file, setupId, force: true, backupBase: b).out,
    );
  });
}
