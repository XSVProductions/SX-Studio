import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

// The old tool's size compounding, reproduced, and the port's fix.
//
// df_aim.ps1 writes every movement first and its state file last. The state
// says which shape it wrote (`written`) and the original (`base`). When the
// state write fails after the movements were resized, the next Apply finds
// shapes that don't match `written`, takes them for an edit made in
// Generator, and resizes the already resized shapes: 120% then 120% gives 144%.

ShowEnv _copy(String to) {
  final dir = Directory(to)..createSync(recursive: true);
  for (final e in Directory(realShowPath!).listSync(recursive: true, followLinks: false)) {
    final target = p.join(dir.path, p.relative(e.path, from: realShowPath!));
    if (e is Directory) Directory(target).createSync(recursive: true);
    if (e is File) e.copySync(target);
  }
  return ShowEnv(dir.path);
}

/// Width of a movement's shape: the pan span of its `[Pan/Tilt/uPan/uTilt]` points.
int _width(ShowEnv env, String gpj) {
  final text = readText(env.path('Editor/Generator/projects/$gpj'));
  final sec = text.split(RegExp(r'\[Pan/Tilt/uPan/uTilt\]', caseSensitive: false))[1].split(RegExp(r'\r?\n\['))[0];
  final xs = RegExp(r'Point_\d+ = (-?\d+),').allMatches(sec).map((m) => int.parse(m[1]!));
  return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
}

void main() {
  late Directory tmp;
  late String gpj;
  late int before;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sx_compound_');
    // a movement that is a plain 4-point floor shape, so the auto-symmetry keeps its size
    final real = ShowEnv(realShowPath!);
    gpj = '${aimPreview(real, AimMode.floor).targets.firstWhere((t) => !t.startsWith('DF CHECK'))}.gpj';
    before = _width(real, gpj);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('old tool: a failed state write makes the next apply resize again', skip: paritySkip, () async {
    final env = _copy(p.join(tmp.path, 'old'));
    final state = env.path('df_aim_state.json');
    await Process.run('chmod', ['444', state]);
    final first = await runOld('df_aim.ps1', {'Action': 'Apply', 'Size': '120', 'NoPrompt': true, 'TestRoot': env.root});
    expect(first.exitCode, isNot(0), reason: 'the state file could not be written');
    expect(_width(env, gpj), closeTo(before * 1.2, 2), reason: 'the movements were written anyway');
    await Process.run('chmod', ['644', state]);
    final second = await runOld('df_aim.ps1', {'Action': 'Apply', 'Size': '120', 'NoPrompt': true, 'TestRoot': env.root});
    expect(second.exitCode, 0);
    expect(_width(env, gpj), closeTo(before * 1.44, 3), reason: '120% of 120%');
  });

  test('port: a failed state write puts every movement back', skip: paritySkip, () {
    final env = _copy(p.join(tmp.path, 'new'));
    final files = Directory(env.root).listSync(recursive: true).whereType<File>().toList();
    final bytes = {for (final f in files) f.path: f.readAsBytesSync()};
    // the state file's temp name is taken, so the last write fails
    Directory(env.path('df_aim_state.json.sxtmp')).createSync();
    expect(() => aimApply(env, AimMode.floor, size: '120'), throwsA(isA<FileSystemException>()));
    for (final f in files) {
      expect(File(f.path).readAsBytesSync(), bytes[f.path], reason: '${p.relative(f.path, from: env.root)} is back as it was');
    }
    Directory(env.path('df_aim_state.json.sxtmp')).deleteSync();
    aimApply(env, AimMode.floor, size: '120');
    expect(_width(env, gpj), closeTo(before * 1.2, 2));
    aimApply(env, AimMode.floor, size: '120');
    expect(_width(env, gpj), closeTo(before * 1.2, 2), reason: 'applying the same size again changes nothing');
  });
}
