import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'rig.dart';

// SKIP FLASH: picks which movers the live button SKIP FLASH uses tonight. The
// scene flashes one head per step, so a head that isn't hung leaves a dark
// gap. Apply rebuilds the scene with just the picked heads.
//
// Kept from the scene: the first step's length and, per model, the channels
// of the first lit head and of the first dark head it finds. Every head of a
// model gets those same values (see the note on [_templates]).
//
// Port of `skip_flash.ps1`.

/// Flash order by head number. The 140 order is the user's original 16-head scene.
const skipOrder140 = [2, 12, 14, 7, 9, 6, 16, 3, 1, 13, 11, 8, 10, 4, 5, 15];
const skipOrder251 = [1, 4, 2, 5, 3, 6];
const _buttonTitle = 'SKIP FLASH';
const _defaultCs = 2;

/// One channel of a fixture in a step.
typedef _Ch = ({int index, String name, int value, String? fade});

/// The scene file behind the live button titled SKIP FLASH (any page), else
/// `scenes/SKIP FLASH.scex`.
String _findScene(ShowEnv env) {
  var isBtn = false;
  String? name, title;
  final header = RegExp(r'^\[page\d+_button\d+\]$', caseSensitive: false);
  final nameRx = RegExp(r'^name = (.+\.scex)\s*$', caseSensitive: false), titleRx = RegExp(r'^title = (.*?)\s*$', caseSensitive: false);
  bool found() {
    final t = title, n = name;
    return isBtn && t != null && psEq(t, _buttonTitle) && n != null && n.isNotEmpty;
  }

  for (final l in readLines(env.path('Live/live.ini'))) {
    if (l.startsWith('[')) {
      if (found()) break;
      isBtn = header.hasMatch(l);
      name = null;
      title = null;
      continue;
    }
    if (isBtn) {
      final n = nameRx.firstMatch(l), t = titleRx.firstMatch(l);
      if (n != null) name = n[1];
      if (t != null) title = t[1];
    }
  }
  final file = found() ? name! : '$_buttonTitle.scex';
  final path = env.path('scenes/$file');
  if (!File(path).existsSync()) throw ToolError('Scene for the SKIP FLASH button not found ($file). NOTHING was changed.');
  return path;
}

/// Lit and dark channel values per model, taken from the scene. Fallback:
/// a white flash, every other channel 0.
///
/// This is where the old tool flattens the scene: per model it keeps the
/// channels of the FIRST lit head and the FIRST dark head it meets, and the
/// rebuilt scene gives every head of that model exactly those. Kept as is
/// for parity.
Map<String, ({List<_Ch> lit, List<_Ch> dark})> _templates(XmlElement scene, Map<String, String> modelOf) {
  List<_Ch> tpl(List<(int, String)> names, bool on) => [
    for (final (i, n) in names) (index: i, name: n, value: on && (n == 'dimmer' || n == 'shutter') ? 255 : 0, fade: null),
  ];
  const chans = {
    model140: [(5, 'color'), (15, 'dimmer'), (16, 'shutter'), (17, 'mode'), (18, 'movement_macro')],
    model251: [(5, 'color'), (15, 'dimmer'), (16, 'shutter'), (17, 'control'), (18, 'movement_macro')],
  };
  // keyed like a PowerShell hashtable: a model name in another case still matches
  final lit = psMap<List<_Ch>>()..addAll({for (final e in chans.entries) e.key: tpl(e.value, true)});
  final dark = psMap<List<_Ch>>()..addAll({for (final e in chans.entries) e.key: tpl(e.value, false)});
  final fromScene = <String>{};
  for (final s in scene.findElements('Steps').expand((x) => x.findElements('Step'))) {
    for (final fx in s.findElements('Fixture')) {
      final mo = modelOf[fx.getAttribute('id') ?? ''];
      if (mo == null) continue;
      final ch = <_Ch>[
        for (final c in fx.findElements('Channel'))
          (index: psInt(c.getAttribute('index')), name: c.getAttribute('name') ?? '', value: psInt(c.getAttribute('value')), fade: c.getAttribute('fade')),
      ];
      final dim = ch.where((c) => psEq(c.name, 'dimmer')).toList();
      final kind = dim.isNotEmpty && dim.first.value > 0 ? 'lit' : 'dark';
      final key = '${mo.toLowerCase()}/$kind';
      if (!fromScene.contains(key) && ch.isNotEmpty) {
        (kind == 'lit' ? lit : dark)[mo] = ch;
        fromScene.add(key);
      }
    }
  }
  return psMap<({List<_Ch> lit, List<_Ch> dark})>()..addAll({for (final mo in chans.keys) mo: (lit: lit[mo]!, dark: dark[mo]!)});
}

/// Picked movers in flash order: 140s in the skip order, 251s spread evenly
/// in between.
List<Mover> _flashOrder(List<Mover> picked) {
  List<Mover> pick(bool is140, List<int> ord) {
    final g = picked.where((m) => m.is140 == is140).toList();
    return [for (final n in ord) ...g.where((m) => m.num == n), ...g.where((m) => !ord.contains(m.num))];
  }

  final a = pick(true, skipOrder140), b = pick(false, skipOrder251), out = <Mover>[];
  var i = 0, j = 0;
  while (i < a.length || j < b.length) {
    final takeA = j >= b.length || (i < a.length && (i + .5) / a.length <= (j + .5) / b.length);
    out.add(takeA ? a[i++] : b[j++]);
  }
  return out;
}

class _Skip {
  _Skip._(this.movers, this.path, this.text, this.scene, this.inScene, this.stepCs);

  factory _Skip.read(ShowEnv env) {
    if (!env.file('Live/live.ini').existsSync()) throw ToolError("Show not found at '${env.root}'. NOTHING was changed.");
    final movers = showMovers(env);
    if (movers.isEmpty) throw ToolError('No 140SR/251SR fixtures found in the show. NOTHING was changed.');
    final path = _findScene(env);
    final text = readText(path);
    final scene = XmlDocument.parse(text).rootElement;
    final inScene = <String>{for (final f in scene.findElements('Fixtures').expand((x) => x.findElements('Fixture'))) f.getAttribute('id') ?? ''};
    final steps = scene.findElements('Steps').expand((x) => x.findElements('Step')).toList();
    var stepCs = _defaultCs;
    final len = steps.isEmpty ? '' : steps.first.getAttribute('length') ?? '';
    if (RegExp(r'^\d+$').hasMatch(len)) stepCs = int.parse(len);
    return _Skip._(movers, path, text, scene, inScene, stepCs);
  }

  final List<Mover> movers;
  final String path;
  final String text;
  final XmlElement scene;
  final Set<String> inScene;
  final int stepCs;
}

/// What the Skip Flash screen shows. Writes nothing.
SkipPreview skipPreview(ShowEnv env) {
  final s = _Skip.read(env);
  final known = {for (final m in s.movers) m.id};
  final order = _flashOrder([
    for (final m in s.movers)
      if (s.inScene.contains(m.id)) m,
  ]);
  return SkipPreview(
    show: env.root,
    scene: p.basenameWithoutExtension(s.path),
    stepCs: s.stepCs,
    unknown: s.inScene.where((id) => !known.contains(id)).length,
    heads: [for (final m in s.movers) SkipHead(id: m.id, label: m.label, num: m.num, is140: m.is140, on: s.inScene.contains(m.id))],
    order: [for (final m in order) m.label],
    order140: skipOrder140,
    order251: skipOrder251,
  );
}

/// `[Security.SecurityElement]::Escape`.
String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

/// Rebuilds the SKIP FLASH scene with just [heads]. Returns the report text.
String skipApply(ShowEnv env, List<String> heads) {
  final s = _Skip.read(env);
  env.requireSxClosed();
  final ids = rigHeadIds(heads);
  final modelOf = {for (final m in s.movers) m.id: m.model};
  final bad = ids.where((i) => !modelOf.containsKey(i)).toList();
  if (bad.isNotEmpty) throw ToolError('Unknown head(s): ${bad.join(', ')}. NOTHING was changed.');
  final picked = [
    for (final m in s.movers)
      if (ids.any((i) => psEq(i, m.id))) m,
  ];
  if (picked.length < 2) throw ToolError('Pick at least 2 heads - with 1 head SKIP FLASH would just stay on. NOTHING was changed.');
  final order = _flashOrder(picked);
  final tpl = _templates(s.scene, modelOf);

  final text = s.text;
  final nl = text.contains('\r\n') ? '\r\n' : '\n';
  final l = <String>['  <Fixtures>'];
  for (final m in picked) {
    l.add('    <Fixture id="${m.id}" name="${_esc(m.name)}" model="${_esc(m.model)}"/>');
  }
  l.addAll(['  </Fixtures>', '  <Steps>']);
  for (final lit in order) {
    l.add('    <Step length="${s.stepCs}">');
    for (final m in picked) {
      l.add('      <Fixture id="${m.id}">');
      final t = tpl[m.model]!;
      for (final c in m.id == lit.id ? t.lit : t.dark) {
        l.add('        <Channel index="${c.index}" name="${_esc(c.name)}" value="${c.value}"${c.fade != null ? ' fade="${c.fade}"' : ''}/>');
      }
      l.add('      </Fixture>');
    }
    l.add('    </Step>');
  }
  l.add('  </Steps>');
  // keep everything before <Fixtures> and after </Steps> exactly as it was
  final i1 = text.indexOf('<Fixtures>'), i2 = text.lastIndexOf('</Steps>');
  if (i1 < 0 || i2 < 0) throw ToolError("SKIP FLASH scene doesn't look like a normal scene file. NOTHING was changed.");
  final pre = text.substring(0, text.lastIndexOf('\n', i1) + 1);
  final post = text.substring(i2 + '</Steps>'.length);
  final rebuilt = pre + l.join(nl) + post;

  final out = <String>[];
  if (psEq(rebuilt, text)) {
    out.add('  SKIP FLASH already uses exactly these heads - nothing to change.');
  } else {
    (RigWrites()..add(s.path, rebuilt)).commit();
    out.add('  SKIP FLASH scene rebuilt: ${p.basename(s.path)}');
  }
  final n140 = picked.where((m) => m.is140).length;
  out
    ..add('  heads: ${picked.length}  ($n140 x 140SR, ${picked.length - n140} x 251SR)')
    ..add('  flash order: ${order.map((m) => m.label).join(' > ')}')
    ..add('  loop: ${(order.length * s.stepCs / 100).toStringAsFixed(2)} s  (${order.length} steps x ${s.stepCs} cs)');
  return out.join('\n');
}
