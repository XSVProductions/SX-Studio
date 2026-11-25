import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'color.dart' show xmlEscape;

// ONE-CLICK LOOKS: makes NEW ShowXpress scenes (.scex) from templates
// (contrast pairs, color chase, strobe, prism fan). The screen works out the
// steps (see `buildLook` in sx_api) so it can show them first. This tool only
// checks them and writes the new file.
//
// Rules (user): ShowXpress must still open every file written. live.ini is
// never touched. A look is always a NEW file: an existing scene is never
// overwritten or changed.
//
// Port of `looks.ps1`.

const _maxSteps = 256;

/// A fixture from fixtures.ini. [qty] above 1 is a group with no ids of its own.
typedef _Head = ({String id, String name, String model, int addr, int qty});

/// One channel of a fixture definition. [name] is how a scene writes it (a
/// repeated name gets `#2`, `#3`...), [base] the name in lowercase.
typedef _Chan = ({int ix, String name, String base, List<({String n, int lo, int hi})> ranges});

void _requireScenes(ShowEnv env) {
  if (!Directory(env.path('scenes')).existsSync()) throw ToolError('The show has no scenes folder (${env.root}). NOTHING was changed.');
}

/// fixtures.ini, in its own order. Port of `Get-Heads`.
List<_Head> _heads(ShowEnv env) {
  final f = env.file('fixtures.ini');
  if (!f.existsSync()) throw ToolError('The show has no fixtures.ini. NOTHING was changed.');
  final out = <_Head>[];
  final section = RegExp(r'^\s*\['), address = RegExp(r'^address = (\d+)', caseSensitive: false), id = RegExp(r'^id = (\S+)\s*$', caseSensitive: false);
  final name = RegExp(r'^name = (.*?)\s*$', caseSensitive: false), model = RegExp(r'^model = (.*?)\s*$', caseSensitive: false);
  final qty = RegExp(r'^quantity = (\d+)', caseSensitive: false);
  _Head? cur;
  void add() {
    final c = cur;
    if (c != null && c.id.isNotEmpty && c.model.isNotEmpty) out.add(c);
  }

  for (final l in readLines(f.path)) {
    if (section.hasMatch(l)) {
      add();
      cur = (id: '', name: '', model: '', addr: 0, qty: 1);
      continue;
    }
    final c = cur;
    if (c == null) continue;
    if (address.firstMatch(l) case final m?) {
      cur = (id: c.id, name: c.name, model: c.model, addr: int.parse(m[1]!), qty: c.qty);
    } else if (id.firstMatch(l) case final m?) {
      cur = (id: m[1]!, name: c.name, model: c.model, addr: c.addr, qty: c.qty);
    } else if (name.firstMatch(l) case final m?) {
      cur = (id: c.id, name: m[1]!, model: c.model, addr: c.addr, qty: c.qty);
    } else if (model.firstMatch(l) case final m?) {
      cur = (id: c.id, name: c.name, model: m[1]!, addr: c.addr, qty: c.qty);
    } else if (qty.firstMatch(l) case final m?) {
      cur = (id: c.id, name: c.name, model: c.model, addr: c.addr, qty: int.parse(m[1]!));
    }
  }
  add();
  return out;
}

/// Fixture definitions as looks read them, once per model.
///
/// Not the shared `FixtureDefs`: looks keep every channel (repeated names
/// too) and only take a range line that has `,lo,hi` in it.
class _Defs {
  _Defs(this.env);

  final ShowEnv env;
  final _cache = psMap<List<_Chan>>();

  /// Port of `Get-Def`.
  List<_Chan> of(String model) => _cache.putIfAbsent(model, () {
    final ch = <_Chan>[];
    final f = env.file('fixtures/$model.txt');
    if (!f.existsSync()) return ch;
    final seen = <String, int>{};
    final channel = RegExp(r'^Channel = (.+?)\s*$', caseSensitive: false), hasRange = RegExp(r',\d+,\d+');
    final range = RegExp(r'([^,]+?),(\d+),(\d+)');
    for (final l in readLines(f.path)) {
      if (channel.firstMatch(l) case final m?) {
        final n = m[1]!, k = n.toLowerCase();
        final count = seen[k] = (seen[k] ?? 0) + 1;
        ch.add((ix: ch.length, name: count > 1 ? '$n#$count' : n, base: k, ranges: []));
        continue;
      }
      if (ch.isNotEmpty && l.trim().isNotEmpty && ch.last.ranges.isEmpty && hasRange.hasMatch(l)) {
        ch.last.ranges.addAll([for (final r in range.allMatches(l)) (n: r[1]!.trim().toLowerCase(), lo: int.parse(r[2]!), hi: int.parse(r[3]!))]);
      }
    }
    return ch;
  });
}

/// The first range of [c] whose name matches [rx] and that is a real range.
({String n, int lo, int hi})? _range(_Chan c, String rx) {
  final re = RegExp(rx, caseSensitive: false);
  for (final r in c.ranges) {
    if (re.hasMatch(r.n) && r.hi >= r.lo && r.hi > 0) return r;
  }
  return null;
}

/// `[int]((lo + hi + 1) / 2)`: the middle of a range, halves to even.
int _mid(int lo, int hi) => psRound((lo + hi + 1) / 2);

final _killRx = RegExp(
  r'^(shutter|strobe|strobe_dimmer|strobe_effect|effect_macro|macro|auto_program|virtual color wheel|color temp presets|movement_macro|control)$',
  caseSensitive: false,
);

/// What a look can use on [model]. Port of `Get-Caps`.
ModelCaps _caps(_Defs defs, String model) {
  final d = defs.of(model);
  _Chan? first(String n) => d.where((c) => c.base == n).firstOrNull;
  List<int> all(String n) => [for (final c in d.where((c) => c.base == n)) c.ix];
  int ixOf(String n) => first(n)?.ix ?? -1;

  final col = first('color');
  final slots = <WheelSlot>[];
  if (col != null) {
    final stop = RegExp('index|rotate|stop|scroll|random|rainbow', caseSensitive: false);
    for (final r in col.ranges) {
      if (stop.hasMatch(r.n)) break;
      if (r.hi < r.lo) continue;
      slots.add(WheelSlot(r.n.replaceFirst(RegExp(r'^.*/'), ''), _mid(r.lo, r.hi)));
    }
  }

  // the shutter: open = an "open" range (255 if that is open), closed = a
  // "closed" range. One with no open range (a strobe-only channel) is a
  // strobe channel, kept at its "off" value
  Shutter? shut;
  final kill = <(int, int)>[];
  for (final x in d) {
    if (!_killRx.hasMatch(x.base)) continue;
    final op = x.ranges.where((r) => r.n == 'open' && r.hi >= r.lo).toList();
    if (x.base == 'shutter' && op.isNotEmpty && shut == null) {
      final ov = op.any((r) => r.hi == 255) ? 255 : op[0].hi;
      shut = Shutter(x.ix, ov, _range(x, r'^closed$')?.lo ?? 0);
      continue;
    }
    if (RegExp('movement_macro|control', caseSensitive: false).hasMatch(x.base)) continue; // leave alone (moves / resets the head)
    kill.add((x.ix, _range(x, r'^(no[ _]?function|no[ _]?effect|off|stop|close|closed)$')?.lo ?? 0));
  }

  (int, int)? span(_Chan c, String rx) => switch (_range(c, rx)) {
    final r? => (r.lo, r.hi),
    null => null,
  };
  final prisms = [
    for (final x in d.where((c) => RegExp('prism', caseSensitive: false).hasMatch(c.base)))
      () {
        final on = x.ranges.where((r) => !RegExp(r'no[ _]?function|stop|rotate', caseSensitive: false).hasMatch(r.n) && r.lo > 0).firstOrNull;
        return Prism(ix: x.ix, name: x.name, on: on == null ? 128 : _mid(on.lo, on.hi), r: span(x, 'right_rotate'), l: span(x, 'left_rotate'));
      }(),
  ];
  final gr = first('gobo_rotate');

  return ModelCaps(
    chans: [for (final c in d) LookChannel(c.ix, c.name)],
    pan: first('pan') != null,
    slots: slots,
    wheel: col != null && slots.isNotEmpty ? col.ix : -1,
    rgb: {
      for (final k in const ['red', 'green', 'blue', 'white', 'amber', 'uv']) k: all(k),
    },
    dim: ixOf('dimmer'),
    shut: shut,
    kill: kill,
    prisms: prisms,
    grot: gr == null ? null : GoboRotate(ix: gr.ix, r: span(gr, 'right_rotate'), l: span(gr, 'left_rotate')),
    gobos: [for (final c in d.where((c) => RegExp(r'^gobo\d*$', caseSensitive: false).hasMatch(c.base))) c.ix],
    zoom: ixOf('zoom'),
    focus: ixOf('focus'),
    frost: ixOf('frost'),
    gobo: ixOf('gobo'),
  );
}

/// The show's scene file names, sorted.
List<String> _sceneNames(ShowEnv env) => psSorted<String>(
  [
    for (final f in Directory(env.path('scenes')).listSync().whereType<File>())
      if (p.basename(f.path).toLowerCase().endsWith('.scex')) p.basename(f.path),
  ],
  [(s) => s],
);

/// The show's heads and what each model can do. Writes nothing.
LookRig looksRig(ShowEnv env) {
  _requireScenes(env);
  final heads = _heads(env);
  final defs = _Defs(env);
  final models = <String, ModelCaps>{};
  final seen = <String>{};
  for (final h in heads) {
    // Select-Object -Unique is case-sensitive, the [ordered] map it fills is not
    if (seen.add(h.model) && !models.keys.any((k) => psEq(k, h.model))) models[h.model] = _caps(defs, h.model);
  }
  bool usable(_Head h) => h.qty == 1 && defs.of(h.model).isNotEmpty;
  return LookRig(
    show: env.root,
    sxOpen: env.sxRunning(),
    heads: [for (final h in heads.where(usable)) LookHead(id: h.id, name: h.name, model: h.model, addr: h.addr)],
    skipped: [for (final h in heads.where((h) => !usable(h))) h.name],
    models: models,
    scenes: _sceneNames(env),
  );
}

final _nameRx = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$', caseSensitive: false);

/// [n] as PowerShell prints a number: whole numbers without a decimal point.
String _psNumber(num n) => n == n.truncate() ? '${n.truncate()}' : '$n';

/// Checks a look and writes it as a new scene. Returns the report text.
///
/// The old tool tested "already in the show" with `Test-Path`, which ignores
/// capitals on Windows and the Mac but not on Linux. This always ignores
/// them, so OLD.scex blocks "old.scex" everywhere.
String looksMake(ShowEnv env, LookDraft look) {
  _requireScenes(env);
  final name = look.name.trim();
  final bare = name.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), '');
  if (!_nameRx.hasMatch(name) || name.startsWith('.') || RegExp(r'\s\.scex$', caseSensitive: false).hasMatch(name)) {
    throw ToolError("'$name' can't be a scene name. NOTHING was changed.");
  }
  final path = env.path('scenes/$name');
  if (_sceneNames(env).any((s) => psEq(s, name))) {
    throw ToolError("A scene called '$bare' is already in the show. Pick another name - NOTHING was changed.");
  }
  final heads = _heads(env);
  final byId = <String, _Head>{
    for (final h in heads)
      if (h.qty == 1) h.id: h,
  };
  final defs = _Defs(env);
  final steps = look.steps;
  if (steps.isEmpty) throw ToolError('The look has no steps. NOTHING was changed.');
  if (steps.length > _maxSteps) throw ToolError('A look can have at most $_maxSteps steps. NOTHING was changed.');

  // every step: the same heads, each with the same channels
  final plan = <({int len, Map<String, Map<int, (int, bool)>> fx})>[];
  Map<String, Set<int>>? shape;
  for (final s in steps) {
    final len = s.len;
    if (len == null || len < 1 || len > 360000) throw ToolError("A step's time must be 0.01 s to 1 hour. NOTHING was changed.");
    final fx = <String, Map<int, (int, bool)>>{};
    for (final MapEntry(key: id, value: channels) in s.f.entries) {
      final h = byId[id];
      if (h == null) throw ToolError("Head $id isn't in the show's fixtures. NOTHING was changed.");
      final d = defs.of(h.model);
      final chs = <int, (int, bool)>{};
      for (final c in channels) {
        if (c.length < 2) throw ToolError('Bad channel for head $id. NOTHING was changed.');
        final ix = psInt(c[0]), v = psInt(c[1]), fd = c.length > 2 && psInt(c[2]) == 1;
        if (ix < 0 || ix >= d.length) throw ToolError('Head ${h.name} has no channel $ix. NOTHING was changed.');
        if (v < 0 || v > 255) throw ToolError('A channel value must be 0-255. NOTHING was changed.');
        if (chs.containsKey(ix)) throw ToolError('Channel $ix of ${h.name} is in a step twice. NOTHING was changed.');
        chs[ix] = (v, fd);
      }
      if (chs.isNotEmpty) fx[id] = chs;
    }
    if (fx.isEmpty) throw ToolError('A step of the look has no channels. NOTHING was changed.');
    final sh = {for (final e in fx.entries) e.key: e.value.keys.toSet()};
    if (shape == null) {
      shape = sh;
    } else if (!_sameShape(shape, sh)) {
      throw ToolError('Every step of a look must set the same heads and channels. NOTHING was changed.');
    }
    plan.add((len: len, fx: fx));
  }

  // the text, the way ShowXpress writes a scene (UTF-8, no BOM, LF)
  final used = [for (final h in heads.where((h) => plan[0].fx.containsKey(h.id))) h];
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n\n<Scene>\n  <Fixtures>\n');
  for (final h in used) {
    sb.write('    <Fixture id="${xmlEscape(h.id)}" name="${xmlEscape(h.name)}" model="${xmlEscape(h.model)}"/>\n');
  }
  sb.write('  </Fixtures>\n  <Steps>\n');
  for (final s in plan) {
    sb.write('    <Step length="${s.len}">\n');
    for (final h in used) {
      final d = defs.of(h.model), chs = s.fx[h.id]!;
      sb.write('      <Fixture id="${xmlEscape(h.id)}">\n');
      for (final ix in chs.keys.toList()..sort()) {
        final (v, fade) = chs[ix]!;
        sb.write('        <Channel index="$ix" name="${xmlEscape(d[ix].name)}" value="$v"${fade ? ' fade="1"' : ''}/>\n');
      }
      sb.write('      </Fixture>\n');
    }
    sb.write('    </Step>\n');
  }
  sb.write('  </Steps>\n</Scene>\n');
  final text = sb.toString();

  // check it reads back as the same look before it is written
  if (!_readsBack(text, plan, used.length)) throw ToolError("The new scene didn't check out. NOTHING was written.");

  // A new file only: create it exclusively, so a scene that appeared meanwhile is never replaced.
  final file = File(path);
  try {
    file.createSync(exclusive: true);
  } on FileSystemException {
    if (file.existsSync()) throw ToolError("A scene called '$bare' is already in the show. NOTHING was changed.");
    rethrow;
  }
  try {
    final raf = file.openSync(mode: FileMode.writeOnly);
    try {
      raf.writeFromSync(utf8.encode(text));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    file.deleteSync(); // never leave half a scene
    rethrow;
  }
  final sec = _psNumber(plan.fold<int>(0, (a, s) => a + s.len) / 100);
  final n = plan.length, hn = used.length;
  return [
    '  Made the scene $bare: $n step${n != 1 ? 's' : ''}, $hn head${hn != 1 ? 's' : ''}, $sec s.',
    "  It's a new file in the show's scenes folder - no other scene and no live button was changed.",
    '{"made":${jsonEncode(name)}}',
  ].join('\n');
}

bool _sameShape(Map<String, Set<int>> a, Map<String, Set<int>> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] != null && b[e.key]!.length == e.value.length && b[e.key]!.containsAll(e.value));

bool _readsBack(String text, List<({int len, Map<String, Map<int, (int, bool)>> fx})> plan, int heads) {
  final XmlElement scene;
  try {
    scene = XmlDocument.parse(text).rootElement;
  } on XmlException {
    return false;
  }
  final rs = scene.findElements('Steps').expand((s) => s.findElements('Step')).toList();
  if (rs.length != plan.length || scene.findElements('Fixtures').expand((f) => f.findElements('Fixture')).length != heads) return false;
  for (var i = 0; i < plan.length; i++) {
    if (int.tryParse(rs[i].getAttribute('length') ?? '') != plan[i].len) return false;
    for (final f in rs[i].findElements('Fixture')) {
      for (final c in f.findElements('Channel')) {
        final want = plan[i].fx[f.getAttribute('id')]?[int.tryParse(c.getAttribute('index') ?? '')];
        if (want == null || int.tryParse(c.getAttribute('value') ?? '') != want.$1) return false;
      }
    }
  }
  return true;
}
