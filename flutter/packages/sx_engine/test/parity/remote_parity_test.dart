// Old versus new for the ShowXpress remote (State, Press, Release, Off).
//
// Both clients talk to the same fake ShowXpress remote (FakeSxRemote), so the
// test compares the lines each one sent, the JSON each one answered, and what
// is pressed afterwards. The old tool runs outside its test mode (test mode
// never touches the network). Two PowerShell aliases stand in for the parts
// that need a real ShowXpress: Find-Show returns the show copy, and
// Test-SxRunning says whether "ShowXpress is open".

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import '../fake_sx_remote.dart';
import 'parity.dart';

String _q(String s) => "'${s.replaceAll("'", "''")}'";

Future<OldRun> _runOld(String show, Map<String, Object> args, {required bool open}) async {
  final call = StringBuffer('& ${_q(p.join(oldSrcPath!, 'sx_remote.ps1'))}');
  args.forEach((k, v) => call.write(v == true ? ' -$k' : ' -$k ${_q('$v')}'));
  final cmd =
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ErrorActionPreference='Stop'; "
      "function global:SxFakeOpen { \$${open ? 'true' : 'false'} }; function global:SxFakeShow { ${_q(show)} }; "
      'Set-Alias -Name Test-SxRunning -Value SxFakeOpen -Scope Global; Set-Alias -Name Find-Show -Value SxFakeShow -Scope Global; '
      "try { $call } catch { [Console]::Error.WriteLine('SXERR:' + \$_.Exception.Message); exit 3 }";
  final r = await Process.run(pwshPath!, ['-NoProfile', '-NonInteractive', '-Command', cmd], stdoutEncoding: utf8, stderrEncoding: utf8);
  final err = const LineSplitter().convert(r.stderr as String).where((l) => l.startsWith('SXERR:')).map((l) => l.substring(6)).join('\n');
  return OldRun(r.exitCode, r.stdout as String, r.stderr as String, r.exitCode == 0 ? null : err);
}

void main() {
  if (paritySkip != null) {
    test('remote parity', () {}, skip: paritySkip);
    return;
  }

  late Directory tmp;
  late String show;
  late FakeSxRemote sx;
  late List<FakeButton> buttons;

  // Titles from the show: three ordinary ones and one on the SETUP page.
  late String a, b, c, setupTitle;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_remote_');
    show = p.join(tmp.path, 'TheLightingController', 'LightShows', p.basename(realShowPath!));
    Directory(p.join(show, 'Live')).createSync(recursive: true);
    File(p.join(realShowPath!, 'Live', 'live.ini')).copySync(p.join(show, 'Live', 'live.ini'));
    sx = await FakeSxRemote.start(password: '');
    File(paramIniPath(ShowEnv(show))).writeAsStringSync('[Network]\r\nLIVEMOBILEENABLE = yes\r\nLIVEMOBILEPORT = ${sx.port}\r\n');
    remoteEnable(ShowEnv(show), random: Random(1));
    final setup = RemoteConfig.read(ShowEnv(show));
    expect(setup.ready, isTrue);
    sx.close();
    sx = await FakeSxRemote.start(password: setup.password);
    File(paramIniPath(ShowEnv(show))).writeAsStringSync('[Network]\r\nLIVEMOBILEENABLE = yes\r\nLIVEMOBILEPORT = ${sx.port}\r\n');

    final seen = <String>{};
    buttons = [
      for (final x in psSorted<LiveButton>(setup.info.buttons, [(x) => x.page, (x) => x.btn]))
        if (x.title.isNotEmpty) FakeButton(x.pageName, x.title),
    ];
    final plain = [
      for (final x in buttons)
        if (!isSetupPage(x.page) && seen.add(x.title.toLowerCase())) x.title,
    ];
    (a, b, c) = (plain[0], plain[1], plain[2]);
    setupTitle = buttons.firstWhere((x) => isSetupPage(x.page)).title;
  });

  tearDown(() async {
    await sx.close();
    tmp.deleteSync(recursive: true);
  });

  /// Runs the old tool, then the port, from the same pressed buttons, and
  /// compares lines sent, JSON answered and buttons pressed afterwards.
  Future<OldRun> same(Map<String, Object> args, Future<RemoteState> Function(ShowEnv env) dart, {List<String> pressed = const [], bool open = true}) async {
    void arrange() {
      sx.buttons = [for (final x in buttons) FakeButton(x.page, x.title, pressed: pressed.contains(x.title))];
      sx.log.clear();
    }

    arrange();
    final old = await _runOld(show, args, open: open);
    final oldLog = [...sx.log], oldPressed = sx.pressed;

    arrange();
    String? error;
    Object? mine;
    try {
      mine = jsonDecode(jsonEncode(await dart(ShowEnv(show, sxRunning: () => open))));
    } on ToolError catch (e) {
      error = e.message;
    }
    expect(error, old.error, reason: 'error (old stderr: ${old.stderr.trim()})');
    if (error == null) expect(mine, old.json, reason: 'JSON answer');
    expect(sx.log, oldLog, reason: 'lines sent to ShowXpress');
    expect(sx.pressed, oldPressed, reason: 'pressed afterwards');
    return old;
  }

  test('State', () => same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state), pressed: [a, setupTitle]));

  test('State with beat messages in between', () {
    sx.noise = true;
    return same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state), pressed: [b]);
  });

  test('Press', () => same({'Action': 'Press', 'Titles': '$a|$b'}, (env) => remoteAction(env, RemoteAction.press, titles: [a, b]), pressed: [a, c]));

  test(
    'Press solo releases everything else',
    () =>
        same({'Action': 'Press', 'Titles': a, 'Solo': true}, (env) => remoteAction(env, RemoteAction.press, titles: [a], solo: true), pressed: [b, setupTitle]),
  );

  test(
    'Press idle skips when the show plays',
    () => same(
      {'Action': 'Press', 'Titles': a, 'Solo': true, 'Idle': true},
      (env) => remoteAction(env, RemoteAction.press, titles: [a], solo: true, idle: true),
      pressed: [b, c],
    ),
  );

  test(
    'Press idle presses when only SETUP plays',
    () => same(
      {'Action': 'Press', 'Titles': a, 'Solo': true, 'Idle': true},
      (env) => remoteAction(env, RemoteAction.press, titles: [a], solo: true, idle: true),
      pressed: [setupTitle],
    ),
  );

  test(
    'Press with titles to release, and one that is not in the show',
    () => same(
      {'Action': 'Press', 'Titles': '$a|NOT IN THE SHOW', 'Release': '$b|$c|$a'},
      (env) => remoteAction(env, RemoteAction.press, titles: [a, 'NOT IN THE SHOW'], release: [b, c, a]),
      pressed: [b],
    ),
  );

  test('Press with different case', () {
    final lower = a.toLowerCase();
    return same({'Action': 'Press', 'Titles': lower}, (env) => remoteAction(env, RemoteAction.press, titles: [lower]));
  });

  test('Release', () => same({'Action': 'Release', 'Titles': '$a|$c'}, (env) => remoteAction(env, RemoteAction.release, titles: [a, c]), pressed: [a, b]));

  test('Off', () => same({'Action': 'Off'}, (env) => remoteAction(env, RemoteAction.off), pressed: [a, b, setupTitle]));

  test('ShowXpress closed', () => same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state), open: false));

  test('ShowXpress has no show loaded', () {
    buttons = [];
    return same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state));
  });

  test('ShowXpress refuses the password', () async {
    sx.refuse = true;
    final old = await same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state));
    expect(old.error, startsWith('ShowXpress refused SX Studio (ERROR|BAD_PASSWORD)'));
  });

  test('ShowXpress not answering', () async {
    await sx.close();
    final old = await same({'Action': 'State'}, (env) => remoteAction(env, RemoteAction.state));
    expect(old.json, containsPair('error', startsWith("ShowXpress isn't answering")));
  });

  test('remote switched off', () {
    File(paramIniPath(ShowEnv(show))).writeAsStringSync('[Network]\r\nLIVEMOBILEENABLE = no\r\n');
    return same({'Action': 'Press', 'Titles': a}, (env) => remoteAction(env, RemoteAction.press, titles: [a]));
  });
}
