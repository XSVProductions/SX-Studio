import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';

// TONIGHT'S COLOR: one color for the night (the couple's decor color) on two
// ShowXpress buttons.
//
//   TONIGHTS COLOR (MOVER COLORS page)  scene "TONIGHTS COLOR MOVERS": every
//       140SR / 251SR on the nearest slot of its color wheel. Color channel
//       only, so it goes on top of any movement scene.
//   TONIGHTS COLOR (UPLIGHTS page)      scene "TONIGHTS COLOR UPLIGHT": every
//       uplight in the exact color (not the Ovation, it stays white).
//
// The last color is kept in <show>/tonights_color.json.
//
// Port of `color.ps1`.

const _moverScene = 'TONIGHTS COLOR MOVERS.scex', _upScene = 'TONIGHTS COLOR UPLIGHT.scex';
const _buttons = [(page: 'MOVER COLORS', scene: _moverScene), (page: 'UPLIGHTS', scene: _upScene)];

WheelColor _w(String name, int value, String hex) => WheelColor(name: name, value: value, hex: hex);

/// The 140SR's color wheel: name, DMX value (middle of its range), how it looks.
/// 21 and 36: the fixture file says purple and magenta, but on the real heads
/// 21 reads PINK and 36 reads PURPLE (user 2026-11-21).
final wheel140 = [
  _w('White', 1, 'ffffff'), _w('Red', 5, 'ff0000'), _w('Yellow', 9, 'ffee00'), _w('Green', 13, '00ff00'), _w('Pastel sky blue', 17, '7fd4ff'), //
  _w('Pink', 21, 'ff3fa4'), _w('Dark yellow', 26, 'ffb000'), _w('Blue', 31, '0030ff'), _w('Purple', 36, '8a2be2'), _w('Light green', 41, '90ff90'),
  _w('Natural white', 46, 'fff1dc'), _w('Cold white', 51, 'e6f2ff'), _w('UV', 56, '5a00ff'),
];

/// The 251SR's color wheel.
final wheel251 = [
  _w('White', 1, 'ffffff'), _w('Red', 5, 'ff0000'), _w('Orange', 9, 'ff7a00'), _w('Yellow', 13, 'ffee00'), _w('Green', 17, '00ff00'), //
  _w('Blue', 21, '0030ff'), _w('CTO (warm)', 26, 'ffc27a'), _w('Cyan', 31, '00ffff'), _w('Magenta', 36, 'ff00ff'), _w('Green 2', 41, '40ff70'),
  _w('Pink', 46, 'ff7ab8'), _w('Lavender', 51, 'b48cff'), _w('UV', 56, '5a00ff'),
];

/// A fixture listed in the show's scenes.
typedef _Fixture = ({String id, String name, String model});

/// An uplight: a fixture with red, green and blue channels. [chs] are its
/// channel names, lowercase.
typedef Wash = ({String id, String name, String model, List<String> chs});

String _decodeEntities(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'), (m) {
  final e = m[1]!;
  if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
  if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
  return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}[e]!;
});

/// .NET's `SecurityElement.Escape`, which the old tools use for XML attributes.
String xmlEscape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

/// `scenes/*.scex`, by name.
List<File> _sceneFiles(ShowEnv env) {
  final dir = Directory(env.path('scenes'));
  if (!dir.existsSync()) return const [];
  final files = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.scex')).toList();
  return psSorted<File>(files, [(f) => p.basename(f.path)]);
}

/// Every fixture any scene lists, by name. Only fixtures still patched (id in
/// fixtures.ini): old scenes can still list deleted fixtures, and putting
/// those in a scene makes ShowXpress say "No compatible fixture found".
///
/// Port of `Get-ShowFixtures`.
List<_Fixture> _showFixtures(ShowEnv env) {
  final patched = <String>{};
  final ini = env.file('fixtures.ini');
  if (ini.existsSync()) {
    final idRx = RegExp(r'^id = (\d+)', caseSensitive: false);
    for (final l in readLines(ini.path)) {
      final m = idRx.firstMatch(l);
      if (m != null) patched.add(m[1]!);
    }
  }
  final seen = <String, _Fixture>{};
  final rx = RegExp(r'<Fixture id="(\d+)" name="([^"]*)" model="([^"]*)"');
  for (final f in _sceneFiles(env)) {
    for (final m in rx.allMatches(readText(f.path))) {
      final id = m[1]!;
      if (patched.isNotEmpty && !patched.contains(id)) continue;
      seen.putIfAbsent(id, () => (id: id, name: _decodeEntities(m[2]!), model: _decodeEntities(m[3]!)));
    }
  }
  return psSorted<_Fixture>(seen.values, [(f) => f.name]);
}

/// Fixtures with red, green and blue channels that are not movers, blinders
/// or the Ovation (it stays white): the uplights.
///
/// Port of `Get-Washes`.
List<Wash> showWashes(ShowEnv env) {
  final out = <Wash>[];
  final skip = RegExp('blinder|OPPSK|350W|Ovation', caseSensitive: false);
  final channel = RegExp(r'^Channel = (.+?)\s*$', caseSensitive: false);
  for (final f in _showFixtures(env)) {
    if (psEq(f.model, model140) || psEq(f.model, model251) || skip.hasMatch(f.model)) continue;
    final def = env.file('fixtures/${f.model}.txt');
    if (!def.existsSync()) continue;
    final chs = [
      for (final l in readLines(def.path))
        if (channel.firstMatch(l) case final m?) m[1]!.toLowerCase(),
    ];
    if (chs.contains('red') && chs.contains('green') && chs.contains('blue')) out.add((id: f.id, name: f.name, model: f.model, chs: chs));
  }
  return out;
}

/// The uplight mix for [hex]: the hue on red, green and blue at full
/// strength, the whiteness on the white LED, the brightness on the dimmer.
///
/// Calibrated on the real uplight (user 2026-11-23): plain maths made blush
/// f4a6b8 look wine red, because the red LED swamps a little blue and white.
/// The user's own BLUSH scene, tuned by eye, is R255 B150 W219, so pale colors
/// get more white (1-(1-w)^1.8) and more blue (ratio^(1-0.85w)), w being the
/// whiteness. Saturated colors (wine, emerald) stay as they are.
///
/// Port of `Get-WashMix`.
Map<String, int> washMix(String hex, {required bool hasWhite}) {
  final c = hexRgb(hex);
  final mx = c.reduce(math.max), mn = c.reduce(math.min);
  final v = {'dimmer': mx, 'red': 0, 'green': 0, 'blue': 0, 'white': 0};
  if (mx > 0) {
    if (!hasWhite) {
      v['red'] = psRound(c[0] * 255 / mx);
      v['green'] = psRound(c[1] * 255 / mx);
      v['blue'] = psRound(c[2] * 255 / mx);
    } else if (mx == mn) {
      v['white'] = 255;
    } else {
      final k = 1.0 / (mx - mn), w = mn / mx;
      v['red'] = psRound(255 * (c[0] - mn) * k);
      v['green'] = psRound(255 * (c[1] - mn) * k);
      v['blue'] = psRound(255 * math.pow((c[2] - mn) * k, 1 - 0.85 * w));
      v['white'] = psRound(255 * (1 - math.pow(1 - w, 1.8)));
    }
  }
  return v;
}

/// The channels an uplight scene sets for [hex]: (index, name, value). Effect
/// and strobe channels are set to 0. Port of `Get-WashValues`.
List<(int, String, int)> washValues(String hex, List<String> chs) {
  final v = washMix(hex, hasWhite: chs.contains('white'));
  final zero = RegExp(r'^(amber|uv|strobe.*|.*macro.*|.*effect.*)$', caseSensitive: false);
  return [
    for (final (i, ch) in chs.indexed)
      if (v.containsKey(ch)) (i, ch, v[ch]!) else if (zero.hasMatch(ch)) (i, ch, 0),
  ];
}

void _requireShow(ShowEnv env) {
  if (!env.file('Live/live.ini').existsSync()) throw ToolError("Show not found at '${env.root}'. NOTHING was changed.");
}

/// The saved color, or null when none was ever saved.
Json? _state(ShowEnv env) {
  final f = env.file('tonights_color.json');
  if (!f.existsSync()) return null;
  final text = readText(f.path);
  if (text.trim().isEmpty) return null;
  try {
    final j = jsonDecode(text);
    return j is Map ? j.cast<String, Object?>() : null;
  } on FormatException {
    throw ToolError("tonights_color.json in the show folder can't be read. NOTHING was changed.");
  }
}

/// What the Tonight's Color screen shows. Writes nothing.
ColorPreview colorPreview(ShowEnv env) {
  _requireShow(env);
  final st = _state(env);
  final ws = showWashes(env);
  // DMX start addresses of the uplights, for the live preview on the real lights
  final addr = <String, int>{};
  final ini = env.file('fixtures.ini');
  if (ini.existsSync()) {
    final aRx = RegExp(r'^address = (\d+)', caseSensitive: false), idRx = RegExp(r'^id = (\d+)', caseSensitive: false);
    ({int a, String id})? cur;
    for (final l in readLines(ini.path)) {
      if (l.startsWith('[')) {
        cur = (a: 0, id: '');
        continue;
      }
      if (cur == null) continue;
      if (aRx.firstMatch(l) case final m?) cur = (a: int.parse(m[1]!), id: cur.id);
      if (idRx.firstMatch(l) case final m?) cur = (a: cur.a, id: m[1]!);
      if (cur.id.isNotEmpty && cur.a != 0) addr[cur.id] = cur.a;
    }
  }
  final info = LiveInfo.read(env);
  return ColorPreview(
    show: env.root,
    hex: st?.str('hex') ?? '',
    name: st?.str('name') ?? '',
    saved: st?.str('saved') ?? '',
    wheel140: wheel140,
    wheel251: wheel251,
    washes: [for (final w in ws) w.name],
    buttons: [
      for (final b in _buttons)
        ColorButton(
          page: b.page,
          scene: b.scene.replaceAll(RegExp(r'\.scex$', caseSensitive: false), ''),
          there: info.buttons.any((x) => psEq(x.name, b.scene)),
        ),
    ],
    washFix: [
      for (final w in ws)
        if (addr[w.id] case final a?) WashFixture(name: w.name, addr: a, chs: w.chs),
    ],
  );
}

/// A scene with one 3-second step, the way ShowXpress writes it.
String _sceneText(List<_Fixture> fixtures, List<(int, String, int)> Function(_Fixture f) channels) {
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n\n<Scene>\n  <Fixtures>\n');
  for (final f in fixtures) {
    sb.write('    <Fixture id="${f.id}" name="${xmlEscape(f.name)}" model="${xmlEscape(f.model)}"/>\n');
  }
  sb.write('  </Fixtures>\n  <Steps>\n    <Step length="300">\n');
  for (final f in fixtures) {
    sb.write('      <Fixture id="${f.id}">\n');
    for (final (i, name, v) in channels(f)) {
      sb.write('        <Channel index="$i" name="${xmlEscape(name)}" value="$v" fade="1"/>\n');
    }
    sb.write('      </Fixture>\n');
  }
  sb.write('    </Step>\n  </Steps>\n</Scene>\n');
  return sb.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

/// .NET's `ToString('s')`: `yyyy-MM-ddTHH:mm:ss`, the same on every machine.
String sortableTime(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// Writes [files] in order, each through [writeTextSafely]. When one fails,
/// the files already written are put back as they were, and the error goes on.
void writeAllOrNothing(List<({String path, String text, bool bom})> files) {
  final done = <(String, List<int>?)>[];
  try {
    for (final f in files) {
      final file = File(f.path);
      final before = file.existsSync() ? file.readAsBytesSync() : null;
      writeTextSafely(f.path, f.text, bom: f.bom);
      done.add((f.path, before));
    }
  } catch (_) {
    for (final (path, before) in done.reversed) {
      try {
        if (before == null) {
          File(path).deleteSync();
        } else {
          writeBytesSafely(path, before);
        }
      } on FileSystemException {
        // keep putting the others back
      }
    }
    rethrow;
  }
}

/// Puts tonight's color [color] (`rrggbb`, a leading # is fine) on the two
/// TONIGHTS COLOR scenes, adds their live buttons the first time, and keeps
/// the color in tonights_color.json. Returns the report text.
///
/// The old tool wrote each file straight away, state last. This writes them in
/// the same order but puts the earlier ones back if a later one fails.
String colorApply(ShowEnv env, String color, {String name = ''}) {
  _requireShow(env);
  env.requireSxClosed();
  final hex = color.trim().replaceFirst(RegExp('^#+'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) throw ToolError("Not a colour: '$color'. NOTHING was changed.");
  final movers = showMovers(env), washes = showWashes(env);
  final n140 = nearestWheel(wheel140, hex)!, n251 = nearestWheel(wheel251, hex)!;

  final writes = <({String path, String text, bool bom})>[];
  final out = <String>[];
  writes.add((
    path: env.path('scenes/$_moverScene'),
    text: _sceneText([
      for (final m in movers) (id: m.id, name: m.name, model: m.model),
    ], (f) => [(5, 'color', psEq(f.model, model140) ? n140.value : n251.value)]),
    bom: false,
  ));
  out.add('  CHANGED  TONIGHTS COLOR MOVERS: 140s on ${n140.name}, 251s on ${n251.name}');
  if (washes.isNotEmpty) {
    final chsOf = {for (final w in washes) w.id: w.chs};
    writes.add((
      path: env.path('scenes/$_upScene'),
      text: _sceneText([for (final w in washes) (id: w.id, name: w.name, model: w.model)], (f) => washValues(hex, chsOf[f.id]!)),
      bom: false,
    ));
    out.add('  CHANGED  TONIGHTS COLOR UPLIGHT: #$hex on ${washes.map((w) => w.name).join(', ')}');
  } else {
    out.add('  no uplights found - only the movers scene was made');
  }

  // buttons, the first time: first free cell on the MOVER COLORS / UPLIGHTS page
  final ini = LiveIni.read(env);
  var info = LiveInfo.read(env, ini);
  var added = false;
  for (final b in _buttons) {
    if (b.scene == _upScene && washes.isEmpty) continue;
    if (info.buttons.any((x) => psEq(x.name, b.scene))) continue;
    final title = b.scene.replaceAll(RegExp(r'\.scex$', caseSensitive: false), '');
    // The old tool walked an unordered hashtable and kept the last match, so
    // with two pages of the same name either could win. This takes the highest page number.
    int? pg;
    for (final k in info.pages.keys.toList()..sort()) {
      if (psEq(info.pages[k]!.trim(), b.page)) pg = k;
    }
    if (pg == null) {
      out.add('  no live page called ${b.page} - add a button for $title yourself');
      continue;
    }
    final cell = addLiveButton(ini, info, pg, b.scene, 'TONIGHTS COLOR');
    info = LiveInfo.read(env, ini);
    added = true;
    out.add('  CHANGED  added the TONIGHTS COLOR button to the ${b.page} page (line ${cell.$1}, column ${cell.$2})');
  }
  if (added) writes.add((path: ini.path, text: ini.lines.join(ini.nl), bom: ini.bom));

  // ConvertTo-Json as PowerShell 7 writes it: two-space indent, LF, no final line break
  final state = {'hex': hex, 'name': name, 'saved': sortableTime(env.now()), 'mover140': n140.name, 'mover251': n251.name};
  writes.add((path: env.path('tonights_color.json'), text: const JsonEncoder.withIndent('  ').convert(state), bom: false));
  writeAllOrNothing(writes);
  return out.join('\n');
}
