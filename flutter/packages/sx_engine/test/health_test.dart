import 'dart:io';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

// The places where the port means to differ from health.ps1, and the sort
// order it copies. Parity tests cover everything else on the real show.

const _liveIni =
    '[live]\r\nmaster_faders = 1\r\n\r\n[master_faders]\r\ncaption_fader0 = MOVEMENTS\r\ntype_fader0 = 1\r\n\r\n'
    '[page1]\r\nname = CHASES\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CHASE.scex\r\ntitle = CHASE\r\nmasterspeedfader = 7\r\n';

ShowEnv _show() {
  final d = Directory.systemTemp.createTempSync('sx_health_');
  addTearDown(() => d.deleteSync(recursive: true));
  Directory('${d.path}/Live').createSync();
  Directory('${d.path}/scenes').createSync();
  File('${d.path}/Live/live.ini').writeAsStringSync(_liveIni);
  File('${d.path}/fixtures.ini').writeAsStringSync('[1]\r\nid = 1\r\n');
  File('${d.path}/scenes/CENTER SPOT.scex').writeAsStringSync('<Scene><Fixtures/><Steps/></Scene>');
  File('${d.path}/scenes/CHASE.scex').writeAsStringSync('<Scene><Fixtures/><Steps/></Scene>');
  return ShowEnv(d.path);
}

void main() {
  test('finds the speed fader that does not exist and fixes it', () {
    final env = _show();
    final issue = healthCheck(env).issues.singleWhere((i) => i.kind == 'speed');
    expect(issue.fix!.key, 'speed|page1_button1');
    expect(healthFix(env, issue.fix!.key), contains('masterspeedfader 7 -> 0'));
    expect(env.file('Live/live.ini').readAsStringSync(), contains('masterspeedfader = 0'));
    expect(healthCheck(env).applied.single.title, issue.title);
  });

  test('keeping the last fix leaves an empty log instead of deleting it', () {
    final env = _show();
    healthFix(env, 'speed|page1_button1');
    final id = healthCheck(env).applied.single.id;
    healthKeep(env, id);
    expect(env.file(healthLogFile).readAsStringSync(), '[]');
    expect(healthCheck(env).applied, isEmpty);
  });

  test('reverting the last fix leaves an empty log too', () {
    final env = _show();
    healthFix(env, 'speed|page1_button1');
    final r = healthRevert(env, healthCheck(env).applied.single.id);
    expect((r as RevertDone).report, contains('live.ini put back'));
    expect(env.file('Live/live.ini').readAsStringSync(), _liveIni);
    expect(env.file(healthLogFile).readAsStringSync(), '[]');
  });

  // The log is written through a temp file next to it. A folder in the way
  // of that temp file makes the log the one write that fails.
  void blockLog(ShowEnv env) => Directory(env.path('$healthLogFile.sxtmp')).createSync();

  test('a fix whose log cannot be written puts live.ini back', () {
    final env = _show();
    blockLog(env);
    expect(() => healthFix(env, 'speed|page1_button1'), throwsA(isA<ToolError>().having((e) => e.message, 'message', startsWith('Could not save the fix'))));
    expect(env.file('Live/live.ini').readAsStringSync(), _liveIni);
  });

  test('a revert whose log cannot be written puts live.ini back', () {
    final env = _show();
    healthFix(env, 'speed|page1_button1');
    final id = healthCheck(env).applied.single.id;
    final fixed = env.file('Live/live.ini').readAsStringSync();
    blockLog(env);
    expect(() => healthRevert(env, id), throwsA(isA<ToolError>().having((e) => e.message, 'message', startsWith('Could not revert the fix'))));
    expect(env.file('Live/live.ini').readAsStringSync(), fixed);
    expect(healthCheck(env).applied.single.id, id);
  });

  test('refuses while ShowXpress is open', () {
    final env = _show();
    final open = ShowEnv(env.root, sxRunning: () => true);
    expect(() => healthFix(open, 'speed|page1_button1'), throwsA(isA<ToolError>().having((e) => e.message, 'message', startsWith('ShowXpress is OPEN'))));
  });

  test('PsText sorts names as Sort-Object does on PowerShell 7', () {
    // The expected order is what pwsh 7 printed for this list.
    final names = ['b', 'A', '_x', '1a', 'a-b', 'ab', 'a b', '(x)', 'Zeta', 'a.b', '10', '9'];
    expect(psSorted<String>(names, [(x) => PsText(x)]), ['_x', '(x)', '10', '1a', '9', 'A', 'a b', 'a-b', 'a.b', 'ab', 'b', 'Zeta']);
  });
}
