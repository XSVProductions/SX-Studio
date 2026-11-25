import 'dart:io';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity/parity.dart';

// The shared show readers, checked against the old tools' own answers on the
// real show. Tool-specific checks live in test/parity.
void main() {
  test('movers match the old flip tool', skip: paritySkip, () async {
    final env = ShowEnv(realShowPath!);
    final old = (await runOld('flip.ps1', {'Action': 'Preview', 'TestRoot': realShowPath!})).json as Map;
    final want = [for (final h in old['heads'] as List) '${h['id']} ${h['label']} ${h['is140']}'];
    expect([for (final m in showMovers(env)) '${m.id} ${m.label} ${m.is140}'], want);
  });

  test('live.ini reads and writes back byte for byte', skip: paritySkip, () {
    final tmp = Directory.systemTemp.createTempSync('sx_ini_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory('${tmp.path}/Live').createSync();
    final src = File('${realShowPath!}/Live/live.ini').readAsBytesSync();
    File('${tmp.path}/Live/live.ini').writeAsBytesSync(src);
    final ini = LiveIni.read(ShowEnv(tmp.path));
    expect(ini.save(), isFalse, reason: 'nothing changed, nothing written');
    ini.lines.add('x');
    expect(ini.save(), isTrue);
    ini.lines.removeLast();
    // save() compares with the text as first read, so force a write of the original lines
    writeTextSafely(ini.path, ini.lines.join(ini.nl), bom: ini.bom);
    expect(File(ini.path).readAsBytesSync(), src);
    expect(hasBom(src), ini.bom);
  });

  test('scenePath joins with / on every system, as Get-ScenePath does', () {
    final tmp = Directory.systemTemp.createTempSync('sx_scenepath_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/scenes/A.scex').createSync(recursive: true);
    File('${tmp.path}/Editor/Generator/projects/M.gpj').createSync(recursive: true);
    final env = ShowEnv(tmp.path);
    expect(scenePath(env, 'A.scex'), '${tmp.path}/scenes/A.scex');
    expect(scenePath(env, 'M.gpj'), '${tmp.path}/Editor/Generator/projects/M.gpj');
    expect(scenePath(env, 'gone.scex'), isNull);
  });

  test('psRound rounds halves to even', () {
    expect([0.5, 1.5, 2.5, 3.5, -0.5, -1.5, 2.4, 2.6].map(psRound), [0, 2, 2, 4, 0, -2, 2, 3]);
  });
}
