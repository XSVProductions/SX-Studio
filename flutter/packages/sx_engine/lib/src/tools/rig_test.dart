import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'rig.dart';

// RIG TEST: which 140 hangs where tonight. The RIG ID button lights every
// 140SR in its own look (#1-#8 solid colors, #9-#16 the same colors
// pulsing). The user taps each truss spot and picks the look seen there.
// Saving moves every head to its spot in ShowXpress's 2D view
// (Editor/2DView/fixtures.ini). Heads that aren't hung go in a block in the
// middle of the page.
//
// Port of `rig_test.ps1`.

const _sceneName = 'RIG ID.scex';

/// Tilt 242/48: beams angled down, a bit past the dance floor center.
const _idTilt = (242, 48);

/// The look each 140 gets, by (number - 1) % 8. Names and swatches are how
/// each wheel filter really looks on the 140SR.
const _looks = [
  (n: 'White', v: 1, hex: 'ffffff'),
  (n: 'Deep red', v: 5, hex: 'c80000'),
  (n: 'Light green', v: 41, hex: 'b4ff8c'),
  (n: 'Yellow', v: 9, hex: 'ffee00'),
  (n: 'Green', v: 13, hex: '00c83c'),
  (n: 'Sky blue', v: 17, hex: '8fdcff'),
  (n: 'Blue', v: 31, hex: '1e3cff'),
  (n: 'Purple', v: 36, hex: 'b030ff'),
];

/// Shutter value for the pulsing looks (what SLOW STROBE uses on this rig).
const _flashShutter = 195;

/// Blinder at the top center of the 2D page, uplight at the bottom center.
const _centerX = 439;
const _centerFix = [(rx: 'blinder', y: 0), (rx: 'uplight', y: 640)];

/// Every truss spot, two per tower.
final List<RtSlot> rtSlots = [
  for (final s in trussSpots)
    for (final side in ['l', 'r'])
      RtSlot(
        key: '${s.key}-$side',
        tower: s.key,
        towerName: s.name,
        side: side == 'l' ? 'left' : 'right',
        x: s.x + (side == 'r' ? s.gap : 0),
        y: s.y,
        extra: s.extra,
      ),
];

({String n, int v, String hex}) _look(Mover h) => _looks[(h.num - 1) % 8];

/// `Editor/2DView/fixtures.ini`, kept as lines so everything else is written
/// back as found (byte order mark and line ending too).
class _TwoD {
  _TwoD(this.path, this.bom, this.nl, this.lines, this.text);

  factory _TwoD.read(ShowEnv env) {
    final path = env.path('Editor/2DView/fixtures.ini');
    if (!File(path).existsSync()) {
      throw ToolError('Editor/2DView/fixtures.ini not found - open the 2D view in ShowXpress once, then try again. NOTHING was changed.');
    }
    final b = File(path).readAsBytesSync();
    final bom = hasBom(b);
    final t = utf8.decode(bom ? Uint8List.sublistView(b, 3) : b, allowMalformed: true);
    return _TwoD(path, bom, t.contains('\r\n') ? '\r\n' : '\n', t.split(RegExp(r'\r?\n')), t);
  }

  final String path;
  final bool bom;
  final String nl;
  final List<String> lines;
  final String text;

  /// Same rules as [LiveIni.findSection].
  (int, int)? find(String name) {
    final header = '[$name]';
    var start = -1, i = 0;
    for (; i < lines.length; i++) {
      if (start < 0) {
        if (psEq(lines[i], header)) start = i;
      } else if (lines[i].startsWith('[')) {
        break;
      }
    }
    if (start < 0) return null;
    var end = i;
    while (end > start + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return (start, end);
  }

  (int, int)? pos(String name) {
    final se = find(name);
    if (se == null) return null;
    final rx = RegExp(r'^Position = (-?\d+),(-?\d+)', caseSensitive: false);
    for (var i = se.$1 + 1; i < se.$2; i++) {
      final m = rx.firstMatch(lines[i]);
      if (m != null) return (int.parse(m[1]!), int.parse(m[2]!));
    }
    return null;
  }

  /// `Set-IniKey` with no `after` list: replace the key, or add it at the end of the section.
  void setPosition(String name, String value) {
    final se = find(name)!;
    for (var i = se.$1 + 1; i < se.$2; i++) {
      if (lines[i].startsWith('Position = ') || psEq(lines[i], 'Position =')) {
        lines[i] = 'Position = $value';
        return;
      }
    }
    lines.insert(se.$2, 'Position = $value');
  }
}

/// `rig_test.json`: when Rig Test last saved and whether the middle towers are used.
({String? saved, bool extra}) _state(ShowEnv env) {
  final j = readRigStateFile(env.file('rig_test.json'));
  if (!env.file('rig_test.json').existsSync()) return (saved: null, extra: false);
  final saved = j?['saved'], extra = j?['extra'];
  return (saved: saved == null ? '' : '$saved', extra: extra == true || (extra is num && extra != 0) || (extra is String && extra.isNotEmpty));
}

List<Mover> _heads(ShowEnv env) {
  if (!env.file('Live/live.ini').existsSync()) throw ToolError("Show not found at '${env.root}'. NOTHING was changed.");
  final heads = psSorted<Mover>(showMovers(env).where((m) => m.is140), [(m) => m.num]);
  if (heads.isEmpty) throw ToolError('No 140SR fixtures found in the show. NOTHING was changed.');
  return heads;
}

/// The live page called SETUP, first in file order.
int? _setupPage(LiveInfo info) {
  for (final e in info.pages.entries) {
    if (psEq(e.value.trim(), 'SETUP')) return e.key;
  }
  return null;
}

/// True for a RIG ID scene from before v1.4.10 (amber, a flash that didn't show).
bool _oldScene(ShowEnv env) {
  final f = env.file('scenes/$_sceneName');
  if (!f.existsSync()) return false;
  final t = readText(f.path);
  final c = RegExp('name="color" value="41"', caseSensitive: false), s = RegExp('name="shutter" value="$_flashShutter"', caseSensitive: false);
  return !(c.hasMatch(t) && s.hasMatch(t));
}

RtInstall _installState(ShowEnv env) {
  final info = LiveInfo.read(env);
  final btn = info.buttons.where((b) => psEq(b.name, _sceneName)).toList();
  return RtInstall(
    scene: env.file('scenes/$_sceneName').existsSync(),
    old: _oldScene(env),
    button: btn.isNotEmpty,
    setupPage: _setupPage(info),
    where: btn.isEmpty ? '' : '${btn.first.pageName}, line ${btn.first.keys['line'] ?? ''}, column ${btn.first.keys['column'] ?? ''}',
  );
}

/// The RIG ID scene: one step, every 140 in its look, aimed down. A head
/// SX Studio reverses gets its position reversed too.
String _idSceneText(ShowEnv env, List<Mover> heads) {
  final flip = FlipState.read(env);
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n\n<Scene>\n  <Fixtures>\n');
  for (final h in heads) {
    b.write('    <Fixture id="${h.id}" name="${h.name}" model="${h.model}"/>\n');
  }
  b.write('  </Fixtures>\n  <Steps>\n    <Step length="300">\n');
  for (final h in heads) {
    final (pan, tilt) = flip.sentPos(h.id, (22600, _idTilt.$1 * 256 + _idTilt.$2));
    final flash = h.num > 8;
    final ch = [
      (0, 'pan', pan ~/ 256, true),
      (1, 'upan', pan % 256, true),
      (2, 'tilt', tilt ~/ 256, true),
      (3, 'utilt', tilt % 256, true),
      (4, 'pantilt_speed', 0, false),
      (5, 'color', _look(h).v, false),
      (6, 'gobo', 0, false),
      (7, 'gobo#2', 0, false),
      (8, 'gobo_rotate', 0, false),
      (9, '8 facet prism', 0, false),
      (10, 'linear prism', 0, false),
      (13, 'zoom', 243, false),
      (14, 'frost', 0, false),
      (15, 'dimmer', 255, false),
      (16, 'shutter', flash ? _flashShutter : 255, false),
    ];
    b.write('      <Fixture id="${h.id}">\n');
    for (final (i, n, v, fade) in ch) {
      b.write('        <Channel index="$i" name="$n" value="$v"${fade ? ' fade="1"' : ''}/>\n');
    }
    b.write('      </Fixture>\n');
  }
  b.write('    </Step>\n  </Steps>\n</Scene>\n');
  return b.toString();
}

/// Each head's spot, read back from the 2D view: slot key to head id.
Map<String, String> _assigned(_TwoD ini, List<Mover> heads) {
  final assign = <String, String>{};
  for (final h in heads) {
    final p = ini.pos(h.name);
    if (p == null) continue;
    for (final s in rtSlots) {
      if (!assign.containsKey(s.key) && (p.$1 - s.x).abs() <= 40 && (p.$2 - s.y).abs() <= 40) {
        assign[s.key] = h.id;
        break;
      }
    }
  }
  return assign;
}

/// What the Rig Test screen shows. Writes nothing.
RtPreview rtPreview(ShowEnv env) {
  final heads = _heads(env);
  final st = _state(env);
  final assign = _assigned(_TwoD.read(env), heads);
  final extraUsed = rtSlots.any((s) => s.extra && assign.containsKey(s.key));
  return RtPreview(
    show: env.root,
    saved: st.saved,
    extra: st.extra || extraUsed,
    install: _installState(env),
    heads: [for (final h in heads) RtHead(id: h.id, num: h.num, label: h.label, look: _look(h).n, hex: _look(h).hex, flash: h.num > 8)],
    slots: rtSlots,
    assign: assign,
  );
}

/// Adds the RIG ID scene (or rewrites an old one) and its button on the
/// SETUP page. Returns the report text.
///
/// The old tool wrote the scene before it knew there was a SETUP page, then
/// refused with "NOTHING was changed". This checks first and writes both
/// files together.
String rtInstall(ShowEnv env) {
  final heads = _heads(env);
  env.requireSxClosed();
  final out = <String>[];
  final writes = RigWrites();
  final wasOld = _oldScene(env);
  final scenePath = env.path('scenes/$_sceneName');
  if (wasOld || !File(scenePath).existsSync()) {
    writes.add(scenePath, _idSceneText(env, heads), bom: false);
    out.add('  CHANGED  ${wasOld ? 'updated' : 'made'} the scene RIG ID (140 #1-#8 solid, #9-#16 the same colours pulsing)');
  }
  final ini = LiveIni.read(env);
  final info = LiveInfo.read(env, ini);
  if (!info.buttons.any((b) => psEq(b.name, _sceneName))) {
    final pg = _setupPage(info);
    if (pg == null) throw ToolError('No live page called SETUP found. NOTHING was changed.');
    final (line, column) = addLiveButton(ini, info, pg, _sceneName, 'RIG ID', cols: [for (var c = 3; c <= 10; c++) c, 1, 2]);
    writes.add(ini.path, ini.lines.join(ini.nl), bom: ini.bom);
    out.add('  CHANGED  added the RIG ID button to the SETUP page (line $line, column $column)');
  }
  writes.commit();
  if (out.isEmpty) out.add('  nothing to change - RIG ID is already there');
  return out.join('\n');
}

/// Saves where each head hangs to the 2D view. [assign] maps slot key
/// (`tl-l`...) to head id. Returns the report text, which ends with the
/// `RIGHEADS:` and `SKIPHEADS:` lines the server uses to update Tonight's
/// Rig and SKIP FLASH.
String rtApply(ShowEnv env, Map<String, String> assign, {required bool extra}) {
  final heads = _heads(env);
  final ini = _TwoD.read(env);
  if (env.sxRunning()) {
    throw ToolError('ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again. (ShowXpress rewrites the 2D view when it closes.)');
  }
  final byId = {for (final h in heads) h.id: h};
  final slotOf = <String, RtSlot>{};
  final want = <String, (int, int)>{};
  for (final MapEntry(key: k, value: id) in assign.entries) {
    final s = rtSlots.where((x) => psEq(x.key, k)).firstOrNull;
    if (s == null) throw ToolError("Unknown truss spot '$k'. NOTHING was changed.");
    if (id.isEmpty) continue;
    final h = byId[id];
    if (h == null) throw ToolError("Unknown head '$id'. NOTHING was changed.");
    if (s.extra && !extra) continue;
    if (slotOf.containsKey(id)) throw ToolError('${h.label} is in two spots. NOTHING was changed.');
    slotOf[id] = s;
    want[id] = (s.x, s.y);
  }
  if (slotOf.isEmpty) throw ToolError('Put at least one mover on a truss. NOTHING was changed.');

  // heads not hung: a block in the middle of the page, 4 across, in number order
  final spare = heads.where((h) => !slotOf.containsKey(h.id)).toList();
  final cols = spare.isEmpty ? 1 : (spare.length < 4 ? spare.length : 4), rows = (spare.length / 4).ceil();
  final x0 = psRound(503 - cols * 110 / 2), y0 = psRound(346 - rows * 105 / 2);
  for (final (i, h) in spare.indexed) {
    want[h.id] = (x0 + (i % 4) * 110, y0 + (i ~/ 4) * 105);
  }

  final lines = <String>[];
  for (final h in heads) {
    final xy = '${want[h.id]!.$1},${want[h.id]!.$2}';
    if (ini.find(h.name) != null) {
      ini.setPosition(h.name, xy);
    } else {
      var ix = ini.lines.length;
      while (ix > 0 && ini.lines[ix - 1].trim().isEmpty) {
        ix--;
      }
      ini.lines.insertAll(ix, ['[${h.name}]', 'Position = $xy']);
    }
    final s = slotOf[h.id];
    if (s != null) lines.add('  ${h.label}: ${s.towerName} tower, ${s.side} mover');
  }
  // blinder and uplight: top and bottom center of the page (their own sections, found by name)
  final header = RegExp(r'^\[(.+)\]\s*$');
  for (final cf in _centerFix) {
    for (final ln in [...ini.lines]) {
      final m = header.firstMatch(ln);
      if (m == null) continue;
      final nm = m[1]!;
      if (!RegExp(cf.rx, caseSensitive: false).hasMatch(nm)) continue;
      final old = ini.pos(nm), xy = '$_centerX,${cf.y}';
      if (old == null || '${old.$1},${old.$2}' != xy) {
        ini.setPosition(nm, xy);
        lines.add('  $nm: moved to the ${cf.y != 0 ? 'bottom' : 'top'} center');
      }
    }
  }
  if (spare.isNotEmpty) lines.add('  not hung (middle of the page): ${spare.map((h) => '#${h.num}').join(', ')}');

  final writes = RigWrites();
  final newText = ini.lines.join(ini.nl);
  final out = <String>[];
  if (!psEq(newText, ini.text)) {
    writes.add(ini.path, newText, bom: ini.bom);
    out.add('  2D view saved');
  } else {
    out.add('  nothing to change in the 2D view');
  }
  writes.add(
    env.path('rig_test.json'),
    rigPsJson({'saved': env.now().toIso8601String().substring(0, 19), 'extra': extra, 'hung': slotOf.keys.toList()}),
    bom: false,
  );
  writes.commit();
  out.addAll(lines);

  // full hung list for Tonight's Rig: these 140s + whichever 251s are ticked
  // there now (all of them if nothing is saved)
  final all251 = [
    for (final m in showMovers(env))
      if (!m.is140) m.id,
  ];
  final rigHung = RigState.read(env).hung;
  final h251 = rigHung == null ? all251 : all251.where((id) => rigHung.any((x) => psEq(x, id))).toList();
  out.add('RIGHEADS: ${[...slotOf.keys, ...h251].join(',')}');
  // SKIP FLASH: these 140s + only the 251s ticked as hung in Tonight's Rig (none if nothing saved there)
  out.add('SKIPHEADS: ${[...slotOf.keys, if (rigHung != null) ...h251].join(',')}');
  return out.join('\n');
}
