import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'apc.dart' show iniInt;

// SHOW HEALTH CHECK: looks through the show for problems that have caused
// trouble before, with fixes that can be applied and reverted.
//
//   errors: button plays a scene that doesn't exist, beats = 0, speed fader
//           that doesn't exist, two buttons on one APC pad, scene uses
//           fixtures that aren't in the show
//   warns:  MIDI outside the 8x8 pads, pad light on another pad, faders on
//           the same CC, buttons on top of each other, colour chases that
//           spin the wheel when they loop, 251s on another colour than the
//           140s, page button count off
//   info:   keyboard keys shared by several buttons, scenes no button uses
//
// What each fix changed (live.ini keys before and after, whole scene files
// before) is kept in <show>/health_fixes.json, so it can be reverted.
//
// Port of `health.ps1`.

/// Kept in the show folder: the fixes that can still be reverted.
const healthLogFile = 'health_fixes.json';

const _rigNote = " Tonight's Rig has trimmed this scene - put all heads back in that tab first, then the fix can be applied here.";

/// One step of a scene in the file's own text, as the old tool finds them.
final _stepRx = RegExp(r'\r?\n[ \t]*<Step\b(?:[^>]*/>|[^>]*>.*?</Step>)', dotAll: true);

/// The 140's colour name to the 251 colour that matches it: the 251 name,
/// its DMX value, and another 251 name that also counts as a match.
const _to251 = <String, (String, int?, String?)>{
  'white': ('white', null, null),
  'red': ('red', null, null),
  'yellow': ('yellow', 13, null),
  'green': ('green', 17, null),
  'pastel_sky_blue': ('blue', 21, 'cyan'),
  'purple': ('magenta', 36, 'lavender'),
  'dark_yellow': ('orange', 10, null),
  'blue': ('blue', 21, null),
  'magenta': ('magenta', 36, 'pink'),
  'light_green': ('green', 41, null),
  'natural_white': ('cto', 26, null),
  'cold_white': ('white', 2, 'lavender'),
  'uv': ('uv', 56, null),
};

/// One live.ini change of a fix. A null [value] removes the key.
typedef _IniOp = ({String sec, String key, String? value});

/// What a fix does to a scene file.
sealed class _FileOp {
  const _FileOp(this.path);

  final String path;
}

/// Play the steps forward then back (1..n, n-1..2).
class _PingPong extends _FileOp {
  const _PingPong(super.path);
}

/// Take out fixtures that are no longer in the show.
class _DropFixtures extends _FileOp {
  const _DropFixtures(super.path, this.ids);

  final List<String> ids;
}

/// Set 251 colour values, step by step.
class _Match251 extends _FileOp {
  const _Match251(super.path, this.sets);

  final List<({int step, String id, int value})> sets;
}

class _Fix {
  const _Fix(this.key, this.label, {this.ini = const [], this.file});

  final String key;
  final String label;
  final List<_IniOp> ini;
  final _FileOp? file;
}

class _Issue {
  const _Issue(this.level, this.kind, this.title, this.detail, [this.advice = '', this.fix]);

  final String level;
  final String kind;
  final String title;
  final String detail;
  final String advice;
  final _Fix? fix;
}

/// What a scan found.
class _Scan {
  _Scan(this.info, this.issues, this.scenes);

  final LiveInfo info;
  final List<_Issue> issues;

  /// Scene and movement files a button plays.
  final int scenes;
}

/// Sorts like PowerShell's `Sort-Object` on text: case ignored, and
/// punctuation before digits before letters, in the order .NET's culture
/// rules put them (`_ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ & # % ` ^ + < = > | ~ $`).
int psTextCompare(String a, String b) {
  const punct = '\t\n\v\f\r _-,;:!?.\'"()[]{}@*/\\&#%`^+<=>|~\$';
  int weight(int c) {
    final i = punct.indexOf(String.fromCharCode(c));
    if (i >= 0) return i;
    if (c >= 0x30 && c <= 0x39) return 100 + c;
    if (c >= 0x61 && c <= 0x7a) return 200 + c;
    if (c >= 0x41 && c <= 0x5a) return 200 + c + 32;
    return 1000 + c;
  }

  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    final d = weight(a.codeUnitAt(i)) - weight(b.codeUnitAt(i));
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// A text key for [psSorted] that compares like [psTextCompare].
class _PsText implements Comparable<_PsText> {
  _PsText(this.s);

  final String s;

  @override
  int compareTo(_PsText other) => psTextCompare(s, other.s);
}

/// Groups [items] by a text key that ignores case. Like a PowerShell
/// hashtable, each group keeps the key as it was first seen.
Map<String, (String, List<T>)> _groupBy<T>(Iterable<T> items, String Function(T) keyOf) {
  final groups = <String, (String, List<T>)>{};
  for (final x in items) {
    final k = keyOf(x);
    groups.putIfAbsent(k.toLowerCase(), () => (k, <T>[])).$2.add(x);
  }
  return groups;
}

String _where(LiveButton b) => '${b.pageName} page, line ${b.keys['line'] ?? ''} col ${b.keys['column'] ?? ''}';

String _pad(int n) => 'row ${8 - n ~/ 8} col ${n % 8 + 1}';

/// Looks through the show. Port of the scan part of `health.ps1`.
_Scan _scanShow(ShowEnv env) {
  final info = LiveInfo.read(env);
  final issues = <_Issue>[];
  void add(String level, String kind, String title, String detail, [String advice = '', _Fix? fix]) =>
      issues.add(_Issue(level, kind, title, detail, advice, fix));

  // Scenes Tonight's Rig holds trimmed get no scene fixes (the rig keeps its own copy).
  final rigFiles = <String>{};
  final rig = env.file('rig_state.json');
  if (rig.existsSync()) {
    try {
      final j = jsonDecode(readText(rig.path));
      final scenes = j is Map ? j['scenes'] : null;
      if (scenes is Map) rigFiles.addAll(scenes.keys.map((k) => '$k'.toLowerCase()));
    } on FormatException {
      // The old tool ignored a broken rig_state.json too.
    }
  }

  // Fixtures in the show.
  final fixturesIni = env.path('fixtures.ini');
  if (!File(fixturesIni).existsSync()) throw ToolError("Could not find file '$fixturesIni'.");
  final idRx = RegExp(r'^id = (\d+)', caseSensitive: false);
  final showIds = {for (final l in readLines(fixturesIni)) ?idRx.firstMatch(l)?[1]};
  final movers = showMovers(env);
  final modelOf = {for (final m in movers) m.id: m.model};
  final defs = FixtureDefs(env);

  // Buttons to scenes. Keyed by full path in lowercase, last button wins.
  final used = <String, LiveButton>{};
  final realPath = <String, String>{};
  for (final b in info.buttons) {
    if (b.name.isEmpty) continue;
    final path = scenePath(env, b.name);
    if (path == null) {
      add(
        'error',
        'scene',
        '${b.title}: scene file missing',
        "Plays '${b.name}', which isn't in the show any more (${_where(b)}). Renamed or deleted?",
        "Pick the scene again in the button's settings in ShowXpress, or delete the button.",
      );
      continue;
    }
    final lk = p.normalize(p.absolute(path)).toLowerCase();
    used[lk] = b;
    realPath[lk] = path;
  }

  // Scenes that use fixtures that are not in the show.
  for (final MapEntry(key: lk, value: b) in used.entries) {
    final rp = realPath[lk]!, txt = readText(rp), fn = p.basename(rp), gpj = lk.endsWith('.gpj');
    final ids = (gpj ? RegExp(r'^ID = (\d+)', multiLine: true) : RegExp(r'<Fixture id="(\d+)"')).allMatches(txt).map((m) => m[1]!);
    final miss = ids.toSet().where((id) => !showIds.contains(id)).toList();
    if (miss.isEmpty) continue;
    final title = '${b.title}: ${miss.length} fixture(s) not in the show';
    final d = "Scene '$fn' still uses fixtures that were deleted from the show (ids ${miss.join(', ')}).";
    if (gpj) {
      add('error', 'fixtures', title, d, 'Open the scene in the Generator and take the missing fixtures out.');
    } else if (rigFiles.contains(fn.toLowerCase())) {
      add('error', 'fixtures', title, d + _rigNote, 'Take the missing fixtures out of the scene.');
    } else {
      add(
        'error',
        'fixtures',
        title,
        d,
        'Take the missing fixtures out of the scene. Nothing else in it changes.',
        _Fix('fixtures|${b.sec}', 'Remove the missing fixtures', file: _DropFixtures(rp, miss)),
      );
    }
  }

  // Beat and speed settings.
  for (final b in info.buttons) {
    final k = b.keys;
    if (k.containsKey('beats') && k['beats']!.trim() == '0') {
      add(
        'error',
        'beat',
        '${b.title}: beats = 0',
        "ShowXpress can't use this - the button runs as a fast strobe (${_where(b)}).",
        "Set Beat/Step/Trigger again in the button's speed dialog in ShowXpress.",
      );
    }
    if (k.containsKey('bpm_trigger') && RegExp(r'^\d+$').hasMatch(k['bpm_trigger']!)) {
      add(
        'warn',
        'beat',
        '${b.title}: odd beat trigger setting',
        "bpm_trigger = ${k['bpm_trigger']} isn't what ShowXpress writes (it uses flash_mode) (${_where(b)}).",
        "Set it again in the button's speed dialog in ShowXpress.",
      );
    }
    if (k.containsKey('masterspeedfader')) {
      final f = iniInt(k['masterspeedfader']);
      if (f < 0 || f >= info.faders.length) {
        final title = "${b.title}: speed fader $f doesn't exist";
        if (info.faders.isNotEmpty) {
          final c0 = info.faders[0].caption;
          add(
            'error',
            'speed',
            title,
            'There are only ${info.faders.length} master faders (${_where(b)}).',
            'Let it follow the first master fader ($c0). You can pick another one in the Speed Faders tab afterwards.',
            _Fix('speed|${b.sec}', 'Use $c0', ini: [(sec: b.sec, key: 'masterspeedfader', value: '0')]),
          );
        } else {
          add('error', 'speed', title, 'The show has no master faders.', 'Add master faders in ShowXpress, or remove the speed fader from the button.');
        }
      }
    }
  }

  // APC mini and MIDI.
  final taken = <int>{};
  for (final b in info.buttons) {
    if (iniInt(b.keys['trigger_midi_type'], 0) != 0) continue;
    final n = iniInt(b.keys['trigger_midi_note']);
    if (n >= 0 && n <= 63) taken.add(n);
  }
  final byNote = <String, List<LiveButton>>{};
  for (final b in info.buttons) {
    final k = b.keys;
    if (!k.containsKey('trigger_midi_note')) continue;
    final n = iniInt(k['trigger_midi_note']), t = iniInt(k['trigger_midi_type'], 0);
    if (t != 0 || n < 0 || n > 63) {
      final midiKey = RegExp(r'^trigger_midi(out)?_', caseSensitive: false);
      final keys = psSorted<String>(k.keys.where(midiKey.hasMatch), [(x) => _PsText(x)]);
      add(
        'warn',
        'midi',
        '${b.title}: mapped outside the 8x8 pads',
        'MIDI ${t == 0 ? 'note' : 'type $t'} $n - not one of the 64 pads; the round and track buttons are meant to stay unmapped (${_where(b)}).',
        'Remove the MIDI mapping from this button. You can give it a pad in the APC mini tab afterwards.',
        _Fix('midiout|${b.sec}', 'Remove the mapping', ini: [for (final key in keys) (sec: b.sec, key: key, value: null)]),
      );
      continue;
    }
    byNote.putIfAbsent('${k['trigger_midi_device'] ?? ''}/${k['trigger_midi_channel'] ?? ''}/$n'.toLowerCase(), () => []).add(b);
    if (k.containsKey('trigger_midiout_note') && iniInt(k['trigger_midiout_note']) != n) {
      add(
        'warn',
        'midi',
        '${b.title}: pad light is on a different pad',
        'Triggered by note $n (${_pad(n)}) but lights note ${k['trigger_midiout_note']}.',
        'Light the pad that triggers it.',
        _Fix('midilight|${b.sec}', 'Light its own pad', ini: [(sec: b.sec, key: 'trigger_midiout_note', value: '$n')]),
      );
    }
  }
  for (final key in psSorted<String>(byNote.keys, [(x) => _PsText(x)])) {
    final bs = psSorted<LiveButton>(byNote[key]!, [(b) => b.page, (b) => iniInt(b.keys['line'], 0), (b) => iniInt(b.keys['column'], 0)]);
    if (bs.length < 2) continue;
    final n = int.parse(key.split('/')[2]);
    var moves = <String>[];
    final ops = <_IniOp>[];
    for (final x in bs.skip(1)) {
      var best = -1;
      var bd = 1e9;
      for (var q = 0; q < 64; q++) {
        if (taken.contains(q)) continue;
        final dr = q ~/ 8 - n ~/ 8, dc = q % 8 - n % 8, d = dr * dr * 1.01 + dc * dc;
        if (d < bd) {
          bd = d;
          best = q;
        }
      }
      if (best < 0) {
        moves = [];
        break;
      }
      taken.add(best);
      moves.add('${x.title} to ${_pad(best)}');
      ops.add((sec: x.sec, key: 'trigger_midi_note', value: '$best'));
      if (x.keys.containsKey('trigger_midiout_note')) ops.add((sec: x.sec, key: 'trigger_midiout_note', value: '$best'));
    }
    final title = 'Pad ${_pad(n)} plays ${bs.length} buttons';
    final d = '${bs.map((b) => '${b.title} (${b.pageName})').join(', ')} - one press fires all of them.';
    if (moves.isNotEmpty) {
      add(
        'error',
        'midi',
        title,
        d,
        'Keep ${bs[0].title} on this pad and move ${moves.join(', ')} (the nearest free pad).',
        _Fix('pad|$n', 'Move to a free pad', ini: ops),
      );
    } else {
      add('error', 'midi', title, d, "There's no free pad left - take one off in the APC mini tab.");
    }
  }
  final faderNote = RegExp(r'^fader(\d+)_midi_note$', caseSensitive: false);
  final ccs = _groupBy(info.live.keys.where(faderNote.hasMatch), (k) => info.live[k] ?? '');
  for (final (cc, faders) in ccs.values) {
    if (faders.length < 2) continue;
    final names = faders.map((k) => k.replaceAll(RegExp('_midi_note', caseSensitive: false), ''));
    add('warn', 'midi', 'Faders share CC $cc', '${names.join(', ')} move together.', 'Learn the MIDI of one of the faders again in ShowXpress.');
  }

  // Keyboard keys and layout.
  final keys = _groupBy(info.buttons.where((b) => (b.keys['trigger_keyboard'] ?? '').isNotEmpty), (b) => b.keys['trigger_keyboard']!);
  for (final (kb, bs) in keys.values) {
    if (bs.length < 2) continue;
    add(
      'info',
      'keys',
      "Keyboard key '$kb' fires ${bs.length} buttons together",
      "${bs.map((b) => '${b.title} (${b.pageName})').join(', ')}. Fine if that's on purpose.",
    );
  }
  final spots = _groupBy(info.buttons, (b) => '${b.page}/${b.keys['line'] ?? ''}/${b.keys['column'] ?? ''}');
  for (final (_, bs) in spots.values) {
    if (bs.length < 2) continue;
    add(
      'warn',
      'layout',
      'Buttons on top of each other',
      '${bs.map((b) => b.title).join(' and ')} share one spot (${_where(bs[0])}) - only one can be seen/clicked.',
      'Drag one of them to a free spot in ShowXpress.',
    );
  }
  for (final MapEntry(key: pg, value: name) in info.pages.entries) {
    final nb = iniInt(info.ini.keys('page$pg')['nb_buttons']), real = info.buttons.where((b) => b.page == pg).length;
    if (nb >= 0 && nb != real) {
      add(
        'warn',
        'layout',
        '$name page: button count off',
        'live.ini says $nb buttons but has $real.',
        "Check that page in ShowXpress for a button that's missing or hidden.",
      );
    }
  }

  // Colour chases that jump back across the wheel when they loop.
  final stepsOf = <String, List<SceneStep>>{};
  List<SceneStep> steps(String lk) => stepsOf.putIfAbsent(lk, () => sceneSteps(defs, realPath[lk]!, modelOf));
  for (final MapEntry(key: lk, value: b) in used.entries) {
    if (!lk.endsWith('.scex')) continue;
    final st = steps(lk);
    if (st.length < 3) continue;
    final bad = <String>[];
    String? ex;
    for (final m in movers) {
      final seq = [
        for (final s in st)
          if (s.colors.containsKey(m.id)) defs.colorSlot(m.model, s.colors[m.id]!),
      ].where((x) => x >= 0).toList();
      if (seq.length < 3 || seq.toSet().length < 3) continue;
      var maxIn = 0;
      for (var i = 1; i < seq.length; i++) {
        maxIn = max(maxIn, (seq[i] - seq[i - 1]).abs());
      }
      final wrap = (seq.first - seq.last).abs();
      if (wrap >= 3 && wrap > maxIn) {
        bad.add(m.label);
        if (ex == null) {
          final nm = [for (final r in defs.of(m.model)['color'] ?? const <ChannelRange>[]) r.name.replaceAll('_', ' ')];
          ex = '${nm[seq.last]} back to ${nm[seq.first]}';
        }
      }
    }
    if (bad.isEmpty) continue;
    final rp = realPath[lk]!, fn = p.basename(rp), n = st.length;
    final title = '${b.title}: colour wheel spins on loop';
    final d =
        'At the end of the loop ${bad.length} head(s) jump $ex, so the wheel visibly runs through every colour in between '
        '(${bad.take(6).join(', ')}${bad.length > 6 ? '...' : ''}).';
    final adv =
        'Play the steps forward then back (1 to $n, then ${n - 1} back to 2) instead of jumping from the last step to the first, '
        'so the wheel only ever moves to a neighbouring colour. Every step stays as long as it is now; one loop becomes ${2 * n - 2} steps instead of $n.';
    if (rigFiles.contains(fn.toLowerCase())) {
      add('warn', 'color', title, d + _rigNote, adv);
    } else if (_stepRx.allMatches(readText(rp)).length != n) {
      add('warn', 'color', title, d, adv);
    } else {
      add('warn', 'color', title, d, adv, _Fix('color|${b.sec}', 'Play it back and forth', file: _PingPong(rp)));
    }
  }

  // 251s on another colour than the 140s in the same step. The two wheels
  // are laid out differently, so the same DMX value is another colour
  // (13 is green on a 140 and yellow on a 251).
  String? colorName(String model, int v) {
    final i = defs.colorSlot(model, v);
    return i < 0 ? null : defs.of(model)['color']![i].name;
  }

  for (final MapEntry(key: lk, value: b) in used.entries) {
    if (!lk.endsWith('.scex')) continue;
    final sets = <({int step, String id, int value})>[];
    String? ex;
    var si = 0;
    for (final s in steps(lk)) {
      si++;
      final u = {
        for (final m in movers)
          if (m.is140 && s.colors.containsKey(m.id)) ?colorName(m.model, s.colors[m.id]!),
      };
      if (u.length != 1 || u.first.isEmpty || !_to251.containsKey(u.first)) continue;
      final want = _to251[u.first]!;
      final ok = [want.$1, ?want.$3];
      for (final m in movers) {
        if (m.is140 || !s.colors.containsKey(m.id)) continue;
        final v = s.colors[m.id]!;
        if (v >= 60) continue;
        final cur = colorName(m.model, v);
        if (cur != null && ok.any((o) => psEq(o, cur))) continue;
        // White and red sit at the same numbers on both wheels: copy the 140's value.
        final nv = want.$2 ?? movers.where((q) => q.is140 && s.colors.containsKey(q.id)).map((q) => s.colors[q.id]!).first;
        sets.add((step: si, id: m.id, value: nv));
        ex ??= 'step $si: 140s ${u.first.replaceAll('_', ' ')}, 251s ${cur ?? ''}';
      }
    }
    if (sets.isEmpty) continue;
    final rp = realPath[lk]!, fn = p.basename(rp);
    final nSteps = sets.map((x) => x.step).toSet().length;
    final title = "${b.title}: 251s don't match the 140s";
    final d =
        "The 251s show a different colour from the 140s in $nSteps step(s) ($ex). The two wheels are laid out differently, so the same number isn't the same colour.";
    const adv =
        'Put the 251s on the matching colour of their own wheel (sky blue -> blue, purple -> magenta, dark yellow -> orange, natural white -> CTO). '
        'Only the 251 colour channel changes.';
    if (rigFiles.contains(fn.toLowerCase())) {
      add('warn', 'color251', title, d + _rigNote, adv);
    } else {
      add('warn', 'color251', title, d, adv, _Fix('color251|${b.sec}', 'Match the 251s', file: _Match251(rp, sets)));
    }
  }

  // Scene files no button uses.
  final unused = <String>[];
  for (final (dir, ext) in [('scenes', '.scex'), ('Editor/Generator/projects', '.gpj')]) {
    final d = Directory(env.path(dir));
    if (!d.existsSync()) continue;
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith(ext)) continue;
      if (!used.containsKey(p.normalize(p.absolute(f.path)).toLowerCase())) unused.add(p.basenameWithoutExtension(f.path));
    }
  }
  if (unused.isNotEmpty) {
    add('info', 'unused', "${unused.length} scenes aren't on any button", psSorted<String>(unused, [(x) => _PsText(x)]).join(', '));
  }
  return _Scan(info, issues, used.length);
}

// ---------------------------------------------------------------- the fix log

/// Applied fixes, as stored. Each entry is kept as read so that saving the
/// log again writes the others back unchanged.
List<Map<String, Object?>> _readLog(ShowEnv env) {
  final f = env.file(healthLogFile);
  if (!f.existsSync()) return [];
  final Object? j;
  try {
    j = jsonDecode(readText(f.path));
  } on FormatException {
    throw ToolError("$healthLogFile in the show folder can't be read - NOTHING was changed.");
  }
  return [
    for (final x in j is List ? j : [j])
      if (x is Map) x.cast<String, Object?>(),
  ];
}

/// The log as the old tool wrote it (PowerShell 7's `ConvertTo-Json`).
/// An empty log is written as `[]`, not deleted, so a Google Drive import
/// can't bring back an old copy.
String _logText(List<Map<String, Object?>> log) => const JsonEncoder.withIndent('  ').convert(log).replaceAll('\n', Platform.isWindows ? '\r\n' : '\n');

String _s(Object? v) => switch (v) {
  null => '',
  bool b => b ? 'True' : 'False',
  _ => '$v',
};

List<Object?> _list(Object? v) => v == null ? const [] : (v is List ? v : [v]);

Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

/// Writes files in order. If one fails, the ones already written are put
/// back as they were and the error is passed on.
void _writeAll(List<(String, void Function())> writes) {
  final undo = <void Function()>[];
  try {
    for (final (path, write) in writes) {
      final f = File(path);
      final before = f.existsSync() ? f.readAsBytesSync() : null;
      write();
      undo.add(() => before == null ? f.deleteSync() : writeBytesSafely(path, before));
    }
  } catch (_) {
    for (final u in undo.reversed) {
      try {
        u();
      } on FileSystemException {
        // Keep putting back the rest.
      }
    }
    rethrow;
  }
}

String _why(Object e) => e is FileSystemException ? '${e.message}: ${e.path}' : '$e';

// ---------------------------------------------------------------- actions

/// The Health Check. Writes nothing.
HealthReport healthCheck(ShowEnv env) {
  final scan = _scanShow(env);
  const order = {'error': 0, 'warn': 1, 'info': 2};
  final sorted = psSorted<_Issue>(scan.issues, [(i) => order[i.level]!, (i) => _PsText(i.kind), (i) => _PsText(i.title)]);
  return HealthReport(
    show: env.root,
    buttons: scan.info.buttons.length,
    scenes: scan.scenes,
    issues: [
      for (final i in sorted)
        HealthIssue(
          level: i.level,
          kind: i.kind,
          title: i.title,
          detail: i.detail,
          advice: i.advice,
          fix: i.fix == null ? null : HealthFix(key: i.fix!.key, label: i.fix!.label),
        ),
    ],
    applied: [
      for (final e in _readLog(env)) AppliedFix(id: _s(e['id']), title: _s(e['title']), label: _s(e['label']), time: _s(e['time']), what: _s(e['what'])),
    ],
  );
}

/// Applies the fix with key [fixId] (`kind|target`). Returns the report text.
String healthFix(ShowEnv env, String fixId) {
  final scan = _scanShow(env);
  env.requireSxClosed();
  final iss = scan.issues.where((i) => i.fix != null && psEq(i.fix!.key, fixId)).firstOrNull;
  if (iss == null) throw ToolError("That problem isn't there any more (already fixed?). Press Check again. NOTHING was changed.");
  final fx = iss.fix!;
  final rnd = Random.secure();
  final now = env.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final entry = <String, Object?>{
    'id': [for (var i = 0; i < 4; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join(),
    'key': fx.key,
    'title': iss.title,
    'label': fx.label,
    'what': iss.advice,
    'time': '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}',
    'ini': <Object?>[],
    'files': <Object?>[],
  };
  final out = <String>[];

  // The scene file first: if anything here throws, nothing has been written.
  final writes = <(String, void Function())>[];
  final file = fx.file;
  if (file != null) {
    final path = file.path, bytes = File(path).readAsBytesSync(), bom = hasBom(bytes), t = readText(path), fn = p.basename(path);
    final String next;
    switch (file) {
      case _PingPong():
        final ms = _stepRx.allMatches(t).toList(), n = ms.length;
        if (n < 3) throw ToolError('The scene has fewer than 3 steps. NOTHING was changed.');
        final end = ms[n - 1].end;
        next = t.substring(0, end) + [for (var i = n - 2; i >= 1; i--) ms[i][0]!].join() + t.substring(end);
        out.add('  $fn: $n steps -> ${2 * n - 2} (back and forth)');
      case _DropFixtures(:final ids):
        var s = t, cnt = 0;
        for (final id in ids) {
          final rx = RegExp('\\r?\\n[ \\t]*<Fixture id="${RegExp.escape(id)}"(?:[^>]*/>|[^>]*>.*?</Fixture>)', dotAll: true);
          cnt += rx.allMatches(s).length;
          s = s.replaceAll(rx, '');
        }
        if (!_isXml(s)) throw ToolError('Taking the fixtures out would break the scene file. NOTHING was changed.');
        next = s;
        out.add('  $fn: removed ${ids.length} missing fixture(s) ($cnt entries)');
      case _Match251(:final sets):
        final ms = _stepRx.allMatches(t).toList(), sb = StringBuffer();
        var pos = 0, cnt = 0;
        for (var i = 0; i < ms.length; i++) {
          var st = ms[i][0]!;
          for (final x in sets.where((x) => x.step == i + 1)) {
            final rx = RegExp('(<Fixture id="${RegExp.escape(x.id)}">(?:(?!</Fixture>).)*?<Channel index="\\d+" name="color" value=")\\d+(")', dotAll: true);
            final st2 = st.replaceFirstMapped(rx, (m) => '${m[1]}${x.value}${m[2]}');
            if (st2 != st) cnt++;
            st = st2;
          }
          sb
            ..write(t.substring(pos, ms[i].start))
            ..write(st);
          pos = ms[i].end;
        }
        sb.write(t.substring(pos));
        next = sb.toString();
        if (!_isXml(next)) throw ToolError('Changing the colours would break the scene file. NOTHING was changed.');
        out.add('  $fn: $cnt 251 colour value(s) matched to the 140s');
    }
    if (psEq(next, t)) throw ToolError('Nothing to change in the scene. NOTHING was changed.');
    entry['files'] = [
      {
        'file': p.relative(p.normalize(p.absolute(path)), from: p.normalize(p.absolute(env.root))).replaceAll(r'\', '/'),
        'bom': bom,
        'original': t,
        'written': textSha(next),
      },
    ];
    writes.add((path, () => writeTextSafely(path, next, bom: bom)));
  }

  if (fx.ini.isNotEmpty) {
    final ini = scan.info.ini;
    final recs = <Object?>[];
    for (final op in fx.ini) {
      final se = ini.findSection(op.sec);
      if (se == null) throw ToolError('Button ${op.sec} is gone from live.ini. NOTHING was changed.');
      final order = <String>[
        for (var i = se.$1 + 1; i < se.$2; i++)
          if (ini.lines[i].indexOf(' =') > 0) ini.lines[i].substring(0, ini.lines[i].indexOf(' =')),
      ];
      final kv = ini.keys(op.sec);
      String? before;
      var prev = <String>[];
      if (kv.containsKey(op.key)) {
        before = kv[op.key];
        // `$order[0..IndexOf]`. IndexOf is exact, and a miss (-1) makes the
        // PowerShell range 0..-1, which is the first and the last key.
        final at = order.indexOf(op.key);
        final range = at < 0 ? [order.first, order.last] : order.sublist(0, at + 1);
        prev = range.where((k) => !psEq(k, op.key)).toList();
      }
      if (op.value == null) {
        ini.removeKeys(op.sec, '^${RegExp.escape(op.key)}\$');
      } else {
        ini.setKey(op.sec, op.key, op.value!, after: const ['line', 'column', 'name', 'title', 'imgpath', 'color', 'speed', 'bpm_trigger']);
      }
      recs.add({'sec': op.sec, 'key': op.key, 'before': before, 'after': op.value, 'prev': prev});
      out.add('  ${kv['title'] ?? ''}: ${op.key} ${before ?? '(none)'} -> ${op.value ?? '(removed)'}');
    }
    entry['ini'] = recs;
    writes.add((ini.path, () => ini.save()));
  }

  // The log goes last. If any write fails, the files written so far are put back.
  final log = _readLog(env)..add(entry);
  writes.add((env.path(healthLogFile), () => writeTextSafely(env.path(healthLogFile), _logText(log), bom: false)));
  try {
    _writeAll(writes);
  } on FileSystemException catch (e) {
    throw ToolError('Could not save the fix (${_why(e)}). NOTHING was changed.');
  }
  return ['  ${iss.title}: fixed (${fx.label})', ...out].join('\n');
}

bool _isXml(String s) {
  try {
    XmlDocument.parse(s);
    return true;
  } on XmlException {
    return false;
  }
}

/// Forgets the backup of an applied fix. It can't be reverted afterwards.
String healthKeep(ShowEnv env, String fixId) {
  final log = _readLog(env);
  final e = _findEntry(log, fixId);
  log.remove(e);
  writeTextSafely(env.path(healthLogFile), _logText(log), bom: false);
  return "  ${_s(e['title'])}: kept (${_s(e['label'])}) - the backup is gone, it can't be reverted now.";
}

Map<String, Object?> _findEntry(List<Map<String, Object?>> log, String fixId) {
  final e = log.where((x) => psEq(_s(x['id']), fixId)).firstOrNull;
  if (e == null) throw ToolError("That fix isn't in the list any more. Press Check again. NOTHING was changed.");
  return e;
}

/// What [healthRevert] did.
sealed class RevertOutcome {
  const RevertOutcome();
}

/// The fix was put back. [report] is the text report.
class RevertDone extends RevertOutcome {
  const RevertDone(this.report);

  final String report;
}

/// Nothing was changed: the show changed after the fix. [conflict] says how.
/// Revert again with force to put it back anyway.
class RevertConflict extends RevertOutcome {
  const RevertConflict(this.conflict);

  final List<String> conflict;
}

/// Puts back what an applied fix changed.
RevertOutcome healthRevert(ShowEnv env, String fixId, {bool force = false}) {
  final log = _readLog(env);
  final e = _findEntry(log, fixId);
  env.requireSxClosed();
  final iniRecs = _list(e['ini']).map(_map).toList(), fileRecs = _list(e['files']).map(_map).toList();
  LiveIni? ini;
  final conf = <String>[];
  if (iniRecs.isNotEmpty) {
    ini = LiveIni.read(env);
    for (final r in iniRecs) {
      final sec = _s(r['sec']), key = _s(r['key']);
      if (ini.findSection(sec) == null) {
        conf.add('button $sec is gone from live.ini');
        continue;
      }
      final k = ini.keys(sec), cur = k[key], after = r['after'];
      if (!psEq(cur ?? '', _s(after)) || (cur == null) != (after == null)) conf.add("$key of '${k['title'] ?? ''}' was changed again");
    }
  }
  for (final f in fileRecs) {
    final rel = _s(f['file']), file = env.file(rel);
    if (!file.existsSync()) {
      conf.add('$rel is gone');
    } else if (!psEq(textSha(readText(file.path)), _s(f['written']))) {
      conf.add('${p.basename(rel)} was edited after the fix');
    }
  }
  if (conf.isNotEmpty && !force) return RevertConflict(conf.toSet().toList());

  final out = <String>[];
  final writes = <(String, void Function())>[];
  if (ini != null) {
    for (final r in iniRecs.reversed) {
      final sec = _s(r['sec']), key = _s(r['key']);
      if (ini.findSection(sec) == null) continue;
      if (r['before'] == null) {
        ini.removeKeys(sec, '^${RegExp.escape(key)}\$');
      } else {
        ini.setKey(sec, key, _s(r['before']), after: [for (final x in _list(r['prev'])) _s(x)]);
      }
    }
    final liveIni = ini;
    writes.add((
      liveIni.path,
      () {
        if (liveIni.save()) out.add('  live.ini put back');
      },
    ));
  }
  for (final f in fileRecs) {
    final rel = _s(f['file']), path = env.path(rel), bom = f['bom'] == true;
    writes.add((
      path,
      () {
        writeTextSafely(path, _s(f['original']), bom: bom);
        out.add('  ${p.basename(rel)} put back');
      },
    ));
  }
  log.remove(e);
  writes.add((env.path(healthLogFile), () => writeTextSafely(env.path(healthLogFile), _logText(log), bom: false)));
  try {
    _writeAll(writes);
  } on FileSystemException catch (err) {
    throw ToolError('Could not revert the fix (${_why(err)}). NOTHING was changed.');
  }
  return RevertDone(['  ${_s(e['title'])}: reverted (${_s(e['label'])})', ...out].join('\n'));
}
