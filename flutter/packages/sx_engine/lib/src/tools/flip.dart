import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'rig.dart';

// REVERSE HEADS: SX Studio's own pan and tilt reverse, instead of the setting
// in a fixture's own menu. For a switched head, every scene's pan/fine pan
// (or tilt/fine tilt) value v becomes 255 - v, and every movement's
// ReversePan/ReverseTilt flips between 0 and 1. Doing it again puts every
// value back. Tonight's Rig's kept full scenes are switched too.
//
// Port of `flip.ps1`.

/// Every head and which axes SX Studio reverses now. Writes nothing.
FlipPreview flipPreview(ShowEnv env) {
  final (movers, cur) = _read(env);
  return FlipPreview(
    show: env.root,
    heads: [
      for (final m in movers) FlipHead(id: m.id, label: m.label, is140: m.is140, pan: cur.heads[m.id]?.pan ?? false, tilt: cur.heads[m.id]?.tilt ?? false),
    ],
  );
}

(List<Mover>, FlipState) _read(ShowEnv env) {
  if (!env.file('Live/live.ini').existsSync()) throw ToolError("Show not found at '${env.root}'. NOTHING was changed.");
  final movers = showMovers(env);
  if (movers.isEmpty) throw ToolError('No 140SR/251SR fixtures found in the show. NOTHING was changed.');
  return (movers, FlipState.read(env));
}

/// Sets which heads SX Studio reverses. [flip] is the full list: a head left
/// out goes back to normal. Returns the report text.
String flipApply(ShowEnv env, Map<String, Flip> flip) {
  final (movers, cur) = _read(env);
  env.requireSxClosed();
  final byId = {for (final m in movers) m.id: m};
  final want = <String, Flip>{};
  for (final MapEntry(key: id, value: f) in flip.entries) {
    if (!byId.containsKey(id)) throw ToolError("Unknown head '$id'. NOTHING was changed.");
    if (f.pan || f.tilt) want[id] = f;
  }

  // what has to switch = wanted XOR what the show has now
  final delta = <String, Flip>{};
  for (final m in movers) {
    final a = cur.heads[m.id], b = want[m.id];
    final dp = (a?.pan ?? false) != (b?.pan ?? false), dt = (a?.tilt ?? false) != (b?.tilt ?? false);
    if (dp || dt) delta[m.id] = (pan: dp, tilt: dt);
  }
  if (delta.isEmpty) return '  nothing to change - the show already has these heads reversed';

  // every scene and movement in the show, so nothing gets out of step
  final writes = <String, String>{};
  var nScene = 0, nMove = 0, nVal = 0;
  for (final d in [env.path('scenes'), env.path('Editor/Generator/projects')]) {
    if (!Directory(d).existsSync()) continue;
    for (final f in Directory(d).listSync().whereType<File>()) {
      final ext = p.extension(f.path).toLowerCase();
      if (ext != '.scex' && ext != '.gpj') continue;
      final t = readText(f.path);
      final (text, n) = ext == '.gpj' ? _switchGpj(t, delta) : _switchScene(t, delta);
      if (n > 0 && !psEq(text, t)) {
        writes[p.normalize(f.path)] = text;
        nVal += n;
        if (ext == '.gpj') {
          nMove++;
        } else {
          nScene++;
        }
      }
    }
  }

  // Tonight's Rig keeps the full version of trimmed chase scenes: switch those too
  final rsFile = env.file('rig_state.json');
  final rs = readRigStateFile(rsFile);
  Map<String, Object?>? rsOut;
  var nRig = 0;
  if (rs != null) {
    final sc = <String, Object?>{};
    final scenes = rs['scenes'];
    if (scenes is Map) {
      for (final MapEntry(:key, :value) in scenes.entries) {
        var orig = _str(value is Map ? value['original'] : null), wr = _str(value is Map ? value['written'] : null);
        final path = p.normalize(env.path('scenes/$key'));
        if (File(path).existsSync() && psEq(textSha(readText(path)), wr)) {
          final o2 = _switchScene(orig, delta).$1;
          final fileNow = writes[path] ?? readText(path);
          if (!psEq(o2, orig)) nRig++;
          orig = o2;
          wr = textSha(fileNow);
        }
        sc['$key'] = {'original': orig, 'written': wr};
      }
    }
    final h = rs['hung'];
    final hung = h is List ? (h.isEmpty ? null : [for (final x in h) _str(x)]) : (h == null || h == '' || h == false ? null : [_str(h)]);
    rsOut = {'hung': hung, 'scenes': sc};
  }

  final out = RigWrites();
  writes.forEach(out.add);
  if (rsOut != null) out.add(rsFile.path, rigPsJson(rsOut), bom: false);
  final statePath = env.path('flip_state.json');
  if (want.isNotEmpty) {
    final heads = <String, Object?>{
      for (final m in movers)
        if (want[m.id] case final w?) m.id: {'label': m.label, 'pan': w.pan, 'tilt': w.tilt},
    };
    out.add(statePath, rigPsJson({'saved': _sortable(env.now()), 'heads': heads}), bom: false);
  } else if (File(statePath).existsSync() && readText(statePath) != rigEmptyState) {
    out.add(statePath, rigEmptyState, bom: false);
  }
  out.commit();

  return [
    for (final m in movers)
      if (delta.containsKey(m.id))
        () {
          final w = want[m.id];
          final now = [if (w?.pan ?? false) 'pan', if (w?.tilt ?? false) 'tilt'];
          return '  CHANGED  ${m.label}: ${now.isNotEmpty ? '${now.join(' + ')} reversed by SX Studio' : 'back to normal (not reversed)'}';
        }(),
    "  $nScene scenes + $nMove movements updated ($nVal values)${nRig > 0 ? ", $nRig kept full chase scene(s) of Tonight's Rig too" : ''}",
  ].join('\n');
}

String _str(Object? v) => v == null ? '' : '$v';

/// `(Get-Date).ToString('s')`.
String _sortable(DateTime t) => t.toIso8601String().substring(0, 19);

final _fixtureBlock = RegExp(r'(<Fixture id="(\d+)">)(.*?)(</Fixture>)', dotAll: true);
final _channelTag = RegExp(r'<Channel\b[^>]*>');
final _axisName = RegExp(r'name="(u?pan|u?tilt)"', caseSensitive: false);
final _valueAttr = RegExp(r'value="(\d+)"', caseSensitive: false);

/// Every step block of a switched head in a scene: pan/upan and/or
/// tilt/utilt value v becomes 255 - v. Returns the text and how many values.
(String, int) _switchScene(String text, Map<String, Flip> delta) {
  var n = 0;
  final out = text.replaceAllMapped(_fixtureBlock, (m) {
    final d = delta[m[2]!];
    if (d == null) return m[0]!;
    final body = m[3]!.replaceAllMapped(_channelTag, (c) {
      final s = c[0]!;
      final ax = _axisName.firstMatch(s);
      if (ax == null) return s;
      final pan = ax[1]!.toLowerCase().endsWith('pan');
      final v = _valueAttr.firstMatch(s);
      if (!(pan ? d.pan : d.tilt) || v == null) return s;
      final x = int.parse(v[1]!);
      if (x > 255) return s;
      n++;
      return s.replaceAll(RegExp(r'value="\d+"', caseSensitive: false), 'value="${255 - x}"');
    });
    return '${m[1]}$body${m[4]}';
  });
  return (out, n);
}

final _gpjSection = RegExp(r'^\[Fixture_\d+\]$', caseSensitive: false);
final _gpjId = RegExp(r'^ID = (\d+)$', caseSensitive: false);
final _gpjReverse = RegExp(r'^Reverse(Pan|Tilt) = (\d+)$', caseSensitive: false);

/// The `[Fixture_n]` section of a switched head in a movement: ReversePan /
/// ReverseTilt 0 becomes 1 and back. A missing line counts as 0 and is added.
(String, int) _switchGpj(String text, Map<String, Flip> delta) {
  final nl = text.contains('\r\n') ? '\r\n' : '\n';
  final out = <String>[];
  String? id;
  var inFx = false, n = 0;
  var seen = psMap<bool>();
  bool wants(String id, String ax) => ax.toLowerCase() == 'pan' ? delta[id]!.pan : delta[id]!.tilt;
  void close() {
    final i = id;
    if (!inFx || i == null || i.isEmpty || !delta.containsKey(i)) return;
    for (final ax in ['Pan', 'Tilt']) {
      if (wants(i, ax) && !(seen[ax] ?? false)) {
        var at = out.length;
        while (at > 0 && out[at - 1].trim().isEmpty) {
          at--;
        }
        out.insert(at, 'Reverse$ax = 1');
        n++;
      }
    }
  }

  for (var ln in text.split(RegExp(r'\r?\n'))) {
    if (ln.startsWith('[')) {
      close();
      inFx = _gpjSection.hasMatch(ln);
      id = null;
      seen = psMap<bool>();
      out.add(ln);
      continue;
    }
    if (inFx) {
      final m = _gpjId.firstMatch(ln);
      if (m != null) id = m[1];
    }
    final i = id;
    if (inFx && i != null && delta.containsKey(i)) {
      final m = _gpjReverse.firstMatch(ln);
      if (m != null) {
        final ax = m[1]!;
        seen[ax] = true;
        if (wants(i, ax)) {
          ln = 'Reverse$ax = ${m[2] == '0' ? 1 : 0}';
          n++;
        }
      }
    }
    out.add(ln);
  }
  close();
  return (out.join(nl), n);
}
