import 'dart:convert';
import 'dart:io';

import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// The scene the tests put on a button: 4 steps where one 140 goes white,
/// red, yellow, green (so the wheel spins back on the loop), one 251 sits on
/// the wrong colour of its own wheel, and a fixture that isn't in the show.
String _scene(Mover m140, Mover m251) {
  String fx(Mover m) => '    <Fixture id="${m.id}" name="${m.name}" model="${m.model}"/>';
  String step(int c140, int c251) =>
      '    <Step length="100">\r\n'
      '      <Fixture id="${m140.id}">\r\n        <Channel index="5" name="color" value="$c140"/>\r\n        <Channel index="15" name="dimmer" value="255"/>\r\n      </Fixture>\r\n'
      '      <Fixture id="${m251.id}">\r\n        <Channel index="5" name="color" value="$c251"/>\r\n      </Fixture>\r\n'
      '      <Fixture id="999">\r\n        <Channel index="1" name="dimmer" value="255"/>\r\n      </Fixture>\r\n'
      '    </Step>';
  return '<?xml version="1.0" encoding="UTF-8"?>\r\n\r\n<Scene>\r\n  <Fixtures>\r\n${fx(m140)}\r\n${fx(m251)}\r\n  </Fixtures>\r\n  <Steps>\r\n'
      '${[step(0, 4), step(4, 0), step(8, 8), step(12, 12)].join('\r\n')}\r\n  </Steps>\r\n</Scene>\r\n';
}

const _testScene = 'HEALTH TEST.scex';

/// The buttons the tests break, picked from the real show.
class _Picks {
  _Picks(String show) {
    final env = ShowEnv(show);
    final info = LiveInfo.read(env);
    movers = showMovers(env);
    final pads = info.buttons.where((b) => iniInt(b.keys['trigger_midi_type'], 0) == 0 && iniInt(b.keys['trigger_midi_note']) >= 0).toList();
    padOff = pads[0];
    padLight = pads[1];
    padDup = pads[2];
    padTarget = pads[3];
    farPad = pads[4];
    offGrid = pads[5];
    final rest = info.buttons.where((b) => !pads.take(6).contains(b) && b.name.isNotEmpty).toList();
    scene = rest[0];
    missing = rest[1];
    beat = rest[2];
    speed = rest[3];
    final page = rest[4].page;
    final samePage = rest.where((b) => b.page == page).toList();
    spotA = samePage[0];
    spotB = samePage[1];
    faders = info.live.keys.where((k) => RegExp(r'^fader\d+_midi_note$').hasMatch(k)).toList();
    final logFile = File('$show/$healthLogFile');
    final log = logFile.existsSync() ? jsonDecode(readText(logFile.path)) : null;
    oldIds = {
      if (log is List)
        for (final e in log)
          if (e is Map) '${e['id']}',
    };
  }

  late final List<Mover> movers;
  late final LiveButton padOff, padLight, padDup, padTarget, farPad, offGrid, scene, missing, beat, speed, spotA, spotB;
  late final List<String> faders;

  /// Fixes already in the show's own log.
  late final Set<String> oldIds;

  Mover get m140 => movers.firstWhere((m) => m.is140);
  Mover get m251 => movers.firstWhere((m) => !m.is140);
}

/// Breaks the show in every way the Health Check knows.
void _breakShow(ShowEnv env, _Picks k) {
  File(env.path('scenes/$_testScene')).writeAsStringSync('\uFEFF${_scene(k.m140, k.m251)}');
  final ini = LiveIni.read(env);
  final live = ini.keys('live');
  ini
    ..setKey(k.scene.sec, 'name', _testScene)
    ..setKey(k.missing.sec, 'name', 'NOT IN THE SHOW.scex')
    ..setKey(k.beat.sec, 'beats', '0')
    ..setKey(k.beat.sec, 'bpm_trigger', '3')
    ..setKey(k.speed.sec, 'masterspeedfader', '9')
    ..setKey(k.padOff.sec, 'trigger_midi_note', '70')
    ..setKey(k.padLight.sec, 'trigger_midiout_note', '${(iniInt(k.padLight.keys['trigger_midi_note']) + 1) % 64}')
    ..setKey(k.padDup.sec, 'trigger_midi_note', k.padTarget.keys['trigger_midi_note']!)
    ..setKey(k.spotB.sec, 'line', k.spotA.keys['line'] ?? '1')
    ..setKey(k.spotB.sec, 'column', k.spotA.keys['column'] ?? '1')
    ..setKey('page${k.spotA.page}', 'nb_buttons', '99');
  if (k.faders.length > 1) ini.setKey('live', k.faders[1], live[k.faders[0]]!);
  ini.save();
}

/// Puts buttons and a fader on a second MIDI controller (device 1), which
/// the APC mini checks leave alone. [Picks.padDup] joins [Picks.padTarget] on
/// one pad, and [Picks.farPad] moves to device 1 on the pad the fix would
/// otherwise skip as taken. [Picks.offGrid] goes to device 1 off the grid, and
/// two faders share a CC on different controllers. Returns the pad the fix
/// should pick.
int _secondController(ShowEnv env, _Picks k) {
  final n = iniInt(k.padTarget.keys['trigger_midi_note']);
  var ini = LiveIni.read(env)
    ..setKey(k.padDup.sec, 'trigger_midi_note', '$n')
    ..setKey(k.farPad.sec, 'trigger_midi_device', '1')
    ..setKey(k.offGrid.sec, 'trigger_midi_device', '1')
    ..setKey(k.offGrid.sec, 'trigger_midi_note', '70');
  if (k.faders.length > 1) {
    ini
      ..setKey('live', k.faders[1], ini.keys('live')[k.faders[0]]!)
      ..setKey('live', k.faders[1].replaceFirst('_note', '_device'), '1');
  }
  ini.save();
  // The nearest pad no APC mini button is on.
  final taken = {
    for (final b in LiveInfo.read(env).buttons)
      if (iniInt(b.keys['trigger_midi_device'], 0) == 0 && iniInt(b.keys['trigger_midi_type'], 0) == 0) iniInt(b.keys['trigger_midi_note']),
  };
  var best = -1;
  var bd = 1e9;
  for (var q = 0; q < 64; q++) {
    final dr = q ~/ 8 - n ~/ 8, dc = q % 8 - n % 8, d = dr * dr * 1.01 + dc * dc;
    if (!taken.contains(q) && d < bd) (bd, best) = (d, q);
  }
  ini = LiveIni.read(env)..setKey(k.farPad.sec, 'trigger_midi_note', '$best');
  ini.save();
  return best;
}

/// Applies a fix with the port and gives it the id [id], so both sides of a
/// revert or keep test see the same log.
void _applyFix(ShowEnv env, String key, String id) {
  healthFix(env, key);
  final f = File(env.path(healthLogFile));
  final log = jsonDecode(f.readAsStringSync()) as List;
  final last = (log.last as Map)['id'] as String;
  f.writeAsStringSync(f.readAsStringSync().replaceFirst('"id": "$last"', '"id": "$id"'));
}

/// When the last fix leaves the log, the old tool deleted the file and the
/// port writes `[]` (a deleted file let a Google Drive import bring a stale
/// copy back). Checks that, then removes the file so the rest compares.
void _emptiedLog(ShowEnv env, int had) {
  if (had != 1) return;
  final f = File(env.path(healthLogFile));
  expect(f.readAsStringSync(), '[]');
  f.deleteSync();
}

void main() {
  parityTest('check the real show', script: 'health.ps1', args: {'Action': 'Check'}, dart: healthCheck);

  group('with problems', () {
    if (paritySkip != null) return;
    final k = _Picks(realShowPath!);
    void broken(ShowEnv env) => _breakShow(env, k);

    // A new fix gets a random id and the current time in the log. Mask those, and only those.
    final masked = ParityOptions(
      rewriteFile: (path, bytes) {
        if (path != healthLogFile) return bytes;
        var t = utf8.decode(bytes);
        t = t.replaceAllMapped(RegExp(r'"id": "([0-9a-f]{8})"'), (m) => k.oldIds.contains(m[1]) || m[1] == 'abcd1234' ? m[0]! : '"id": "<new>"');
        t = t.replaceAll(RegExp(r'"time": "\d{4}-\d\d-\d\d \d\d:\d\d"'), '"time": "<time>"');
        return utf8.encode(t);
      },
    );

    // The old tool lists faders that share a CC in hashtable order, which
    // .NET randomizes per run. Compare that one list sorted.
    final faderOrder = ParityOptions(
      rewriteJson: (j) {
        for (final i in (j as Map)['issues'] as List) {
          final d = (i as Map)['detail'] as String;
          if (!'${i['title']}'.startsWith('Faders share CC')) continue;
          final names = d.substring(0, d.indexOf(' move together.')).split(', ')..sort();
          i['detail'] = '${names.join(', ')} move together.';
        }
        return j;
      },
    );

    parityTest(
      'check finds every kind of problem',
      script: 'health.ps1',
      args: {'Action': 'Check'},
      setup: broken,
      options: faderOrder,
      dart: (env) {
        final r = healthCheck(env);
        expect({
          for (final i in r.issues) i.kind,
        }, containsAll(['scene', 'fixtures', 'beat', 'speed', 'midi', 'keys', 'layout', 'color', 'color251', 'unused']));
        expect(r.issues.where((i) => i.fix != null).map((i) => i.fix!.key.split('|').first).toSet(), {
          'speed',
          'midiout',
          'midilight',
          'pad',
          'color',
          'color251',
          'fixtures',
        });
        return r;
      },
    );

    void fix(String name, String key, {void Function(ShowEnv env)? setup}) => parityTest(
      name,
      script: 'health.ps1',
      args: {'Action': 'Fix', 'FixId': key},
      setup: setup ?? broken,
      options: masked,
      dart: (env) {
        final r = healthFix(env, key);
        expect(r, contains(': fixed ('));
        return r;
      },
    );

    var freed = -1;
    parityTest(
      'check leaves a second controller alone',
      script: 'health.ps1',
      args: {'Action': 'Check'},
      setup: (env) => freed = _secondController(env, k),
      dart: (env) {
        final r = healthCheck(env);
        final fixes = r.issues.map((i) => i.fix?.key).toSet();
        expect(fixes, isNot(contains('midiout|${k.offGrid.sec}')));
        expect(r.issues.where((i) => i.title.startsWith('Faders share CC')), isEmpty);
        final pad = r.issues.firstWhere((i) => i.fix?.key == 'pad|${k.padTarget.keys['trigger_midi_note']}');
        expect(pad.advice, contains('row ${8 - freed ~/ 8} col ${freed % 8 + 1}'));
        return r;
      },
    );
    fix('fix: two buttons on one pad, next to a second controller', 'pad|${k.padTarget.keys['trigger_midi_note']}', setup: (env) => _secondController(env, k));

    fix('fix: speed fader that does not exist', 'speed|${k.speed.sec}');
    fix('fix: mapping outside the pads', 'midiout|${k.padOff.sec}');
    fix('fix: pad light on another pad', 'midilight|${k.padLight.sec}');
    fix('fix: two buttons on one pad', 'pad|${k.padTarget.keys['trigger_midi_note']}');
    fix('fix: colour wheel back and forth', 'color|${k.scene.sec}');
    fix('fix: 251 colours', 'color251|${k.scene.sec}');
    fix('fix: fixtures not in the show', 'fixtures|${k.scene.sec}');
    fix('fix: key in other case still found', 'SPEED|${k.speed.sec}');
    fix('refuses a fix that is not there', 'speed|page99_button99');
    fix(
      'refuses a scene fix while the rig holds the scene',
      'color|${k.scene.sec}',
      setup: (env) {
        broken(env);
        File(env.path('rig_state.json')).writeAsStringSync('{"hung":[],"scenes":{"$_testScene":{"written":"x"}}}');
      },
    );

    // Revert and keep. Each starts from a fix the port applied, with a fixed id.
    void after(String name, Map<String, Object> args, String key, {void Function(ShowEnv env)? then}) => parityTest(
      name,
      script: 'health.ps1',
      args: {...args, 'FixId': 'abcd1234'},
      options: masked,
      setup: (env) {
        broken(env);
        _applyFix(env, key, 'abcd1234');
        then?.call(env);
      },
      dart: (env) => switch (args['Action']) {
        'Keep' => healthKeep(env, 'abcd1234'),
        _ => switch (healthRevert(env, 'abcd1234', force: args['Force'] == true)) {
          RevertDone(:final report) => report,
          RevertConflict(:final conflict) => {'conflict': conflict},
        },
      },
    );

    after('revert: speed fader', {'Action': 'Revert'}, 'speed|${k.speed.sec}');
    after('revert: removed mapping comes back in place', {'Action': 'Revert'}, 'midiout|${k.padOff.sec}');
    after('revert: two buttons on one pad', {'Action': 'Revert'}, 'pad|${k.padTarget.keys['trigger_midi_note']}');
    after('revert: scene file', {'Action': 'Revert'}, 'color|${k.scene.sec}');
    void editIni(ShowEnv env) {
      LiveIni.read(env)
        ..setKey(k.speed.sec, 'masterspeedfader', '1')
        ..save();
    }

    void editScene(ShowEnv env) => File(env.path('scenes/$_testScene')).writeAsStringSync('<Scene/>');
    void dropButton(ShowEnv env) {
      final ini = LiveIni.read(env);
      ini.lines[ini.findSection(k.speed.sec)!.$1] = '[gone_button]';
      ini.save();
    }

    after('revert refuses: live.ini changed again', {'Action': 'Revert'}, 'speed|${k.speed.sec}', then: editIni);
    after('revert refuses: scene edited again', {'Action': 'Revert'}, 'color|${k.scene.sec}', then: editScene);
    after('revert refuses: scene gone', {'Action': 'Revert'}, 'color|${k.scene.sec}', then: (env) => File(env.path('scenes/$_testScene')).deleteSync());
    after('revert refuses: button gone', {'Action': 'Revert'}, 'speed|${k.speed.sec}', then: dropButton);
    after('revert with force after a change', {'Action': 'Revert', 'Force': true}, 'speed|${k.speed.sec}', then: editIni);
    after('revert with force after a scene edit', {'Action': 'Revert', 'Force': true}, 'color|${k.scene.sec}', then: editScene);
    after('revert with force, button gone', {'Action': 'Revert', 'Force': true}, 'speed|${k.speed.sec}', then: dropButton);
    after('keep', {'Action': 'Keep'}, 'speed|${k.speed.sec}');
    after('refuses an id that is not in the log', {'Action': 'Revert'}, 'speed|${k.speed.sec}', then: (env) => healthKeep(env, 'abcd1234'));

    // The fix that was already in the owner's log, written by the Windows app.
    for (final id in k.oldIds) {
      parityTest(
        "revert the show's own fix $id",
        script: 'health.ps1',
        args: {'Action': 'Revert', 'FixId': id},
        dart: (env) {
          final r = healthRevert(env, id);
          if (r is RevertConflict) return {'conflict': r.conflict};
          _emptiedLog(env, k.oldIds.length);
          return (r as RevertDone).report;
        },
      );
    }
  });

  // Keeping the last fix empties the log. See [_emptiedLog].
  group('emptied log', () {
    if (paritySkip != null) return;
    final ids = _Picks(realShowPath!).oldIds;
    if (ids.length != 1) return;
    parityTest(
      'keep the last fix writes an empty log',
      script: 'health.ps1',
      args: {'Action': 'Keep', 'FixId': ids.single},
      dart: (env) {
        final r = healthKeep(env, ids.single);
        _emptiedLog(env, 1);
        return r;
      },
    );
  });
}
