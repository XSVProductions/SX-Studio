import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../dmx/dmx_output.dart';
import '../ps_compat.dart';
import '../show/text_files.dart';
import 'cs_compat.dart';

// The show files the SX Player plays: scenes (.scex) and movements (.gpj),
// and the patch that says where each light sits on the DMX line.
//
// Port of the "patch + scenes" and "movements (.gpj)" parts of `SxPlayer` in
// `player.ps1`.

/// A scene or movement can't be played. [message] is shown to the user.
class PlayerError implements Exception {
  PlayerError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// fixtures.ini read for the player: fixture id to DMX address (1-based).
///
/// Port of `Set-PlayerPatch`. Only `address = N` and `id = N` lines count,
/// an id after its section's address, and address 0 is ignored.
Map<String, int> readPlayerPatch(String fixturesIni) {
  final patch = <String, int>{};
  int? a;
  final addressRx = RegExp(r'^address = (\d+)\s*$', caseSensitive: false);
  final idRx = RegExp(r'^id = (\d+)\s*$', caseSensitive: false);
  for (final l in readLines(fixturesIni)) {
    if (l.startsWith('[')) {
      a = null;
      continue;
    }
    final am = addressRx.firstMatch(l);
    if (am != null) {
      a = int.parse(am[1]!);
      continue;
    }
    final im = idRx.firstMatch(l);
    if (im != null && a != null && a != 0) patch[im[1]!] = a;
  }
  return patch;
}

/// A scene ready to play.
class Scene {
  Scene._(this.path, this.stamp, this.len, this.total, this.chans, this.val, this.fade, this.unpatched);

  final String path;
  final DateTime stamp;

  /// Step lengths in ms, at least 10 each.
  final List<int> len;

  /// All steps together, ms.
  final int total;

  /// DMX channel (0-based) of each channel the scene uses.
  final List<int> chans;

  /// `val[step][k]` is the value of `chans[k]` in that step.
  final List<Uint8List> val;
  final List<List<bool>> fade;

  /// Fixtures in the scene that are not in fixtures.ini.
  final int unpatched;
}

/// One section of a movement: the pan/tilt path, or a value graph.
class MoveSection {
  MoveSection(this.name);

  final String name;

  /// 0 = jump point to point, 1 = straight lines, 2 = smooth curve.
  int tr = 2;

  /// One cycle, ms.
  double dur = 20000;

  /// How far behind each head runs, % of a cycle per head.
  double shift = 0;
  List<double> x = const [], y = const [];
}

/// One head of a movement (`[Fixture_n]`).
class MoveHead {
  /// DMX address, 0-based.
  int a0 = 0;

  /// The head's number in the list, for Shift.
  int k = 0;

  /// Channel name (any case) to its index on the fixture.
  final ix = psMap<int>();
  bool rp = false, rt = false;
  double op = 0, ot = 0, zp = 1, zt = 1;
}

/// A movement ready to play.
class Move {
  Move._(this.path, this.stamp);

  final String path;
  final DateTime stamp;
  MoveSection? pt;
  final vals = <MoveSection>[];
  final heads = <MoveHead>[];

  /// Centre of the pan/tilt path, for Zoom.
  double cx = 0, cy = 0;
  int unpatched = 0;

  /// Points on the pan/tilt path.
  int points = 0;
}

/// Loads scenes and movements once and keeps them until the file changes.
/// Paths compare ignoring case, like the old player's caches.
class PlayerFiles {
  PlayerFiles(this.patch);

  /// Fixture id to DMX address (1-based).
  final Map<String, int> patch;
  final _scenes = psMap<Scene>();
  final _moves = psMap<Move>();

  /// Port of `Load`.
  Scene scene(String path) {
    final st = _stamp(path);
    final c = _scenes[path];
    if (c != null && c.stamp == st) return c;
    final XmlDocument x;
    try {
      x = XmlDocument.parse(readText(path));
    } on XmlException catch (e) {
      throw PlayerError(e.message);
    }
    final root = x.rootElement;
    final steps = [
      if (root.name.local == 'Scene')
        for (final ss in root.childElements.where((e) => e.name.local == 'Steps')) ...ss.childElements.where((e) => e.name.local == 'Step'),
    ];
    final ns = steps.length;
    if (ns == 0) throw PlayerError('the scene has no steps');
    final col = <int, int>{};
    final chans = <int>[];
    final sv = <Map<int, int>>[];
    final sf = <Map<int, bool>>[];
    final unp = <String>{};
    final len = List<int>.filled(ns, 0);
    var total = 0;
    for (var i = 0; i < ns; i++) {
      final s = steps[i];
      final cs = csInt(s.getAttribute('length') ?? '') ?? 100;
      len[i] = math.max(10, cs * 10);
      total += len[i];
      final v = <int, int>{}, f = <int, bool>{};
      for (final fx in s.childElements.where((e) => e.name.local == 'Fixture')) {
        final id = fx.getAttribute('id') ?? '';
        final a = patch[id];
        if (a == null) {
          unp.add(id);
          continue;
        }
        for (final ch in fx.childElements.where((e) => e.name.local == 'Channel')) {
          final ix = csInt(ch.getAttribute('index') ?? ''), val = csInt(ch.getAttribute('value') ?? '');
          if (ix == null || val == null) continue;
          final d = a - 1 + ix;
          if (d < 0 || d >= dmxFrameSize) continue;
          if (!col.containsKey(d)) {
            col[d] = chans.length;
            chans.add(d);
          }
          v[d] = val.clamp(0, 255);
          f[d] = ch.getAttribute('fade') == '1';
        }
      }
      sv.add(v);
      sf.add(f);
    }
    final vals = <Uint8List>[], fades = <List<bool>>[];
    for (var i = 0; i < ns; i++) {
      final vi = Uint8List(chans.length);
      final fi = List<bool>.filled(chans.length, false);
      for (var k = 0; k < chans.length; k++) {
        final d = chans[k];
        final v = sv[i][d];
        // a channel missing from a step keeps the step before's value (the show's chases always have every channel)
        if (v != null) {
          vi[k] = v;
          fi[k] = sf[i][d]!;
        } else {
          vi[k] = i > 0 ? vals[i - 1][k] : 0;
        }
      }
      vals.add(vi);
      fades.add(fi);
    }
    return _scenes[path] = Scene._(path, st, len, total, chans, vals, fades, unp.length);
  }

  /// Port of `LoadMove`. A .gpj is an ini file: `[section]` then `key = value`.
  Move move(String path) {
    final st = _stamp(path);
    final c = _moves[path];
    if (c != null && c.stamp == st) return c;
    final secs = <(String, Map<String, String>)>[];
    Map<String, String>? cur;
    for (final raw in readLines(path)) {
      final l = _trimStartBom(raw.trim());
      if (l.startsWith('[') && l.endsWith(']') && l.length >= 2) {
        cur = psMap<String>();
        secs.add((l.substring(1, l.length - 1), cur));
        continue;
      }
      final e = l.indexOf(' = ');
      if (cur == null || e < 1) continue;
      cur[l.substring(0, e).trim()] = l.substring(e + 3).trim();
    }
    final m = Move._(path, st);
    final unp = <String>{};
    for (final (name, s) in secs) {
      if (name.startsWith('Fixture_')) {
        final id = s['ID'];
        if (id == null) continue;
        final a = patch[id];
        if (a == null) {
          unp.add(id);
          continue;
        }
        final h = MoveHead()
          ..a0 = a - 1
          ..k = csInt(name.substring(8)) ?? m.heads.length;
        final chs = s['Channels'];
        if (chs != null) {
          final cs = chs.split(',');
          for (var i = 0; i < cs.length; i++) {
            final ch = cs[i].trim();
            if (ch.isNotEmpty && !h.ix.containsKey(ch)) h.ix[ch] = i;
          }
        }
        h
          ..rp = _d(s, 'ReversePan', 0) != 0
          ..rt = _d(s, 'ReverseTilt', 0) != 0
          ..op = _d(s, 'OffsetPan', 0)
          ..ot = _d(s, 'OffsetTilt', 0)
          ..zp = math.pow(1 + _d(s, 'ZoomPan', 0) / 100.0, 2).toDouble()
          ..zt = math.pow(1 + _d(s, 'ZoomTilt', 0) / 100.0, 2).toDouble();
        m.heads.add(h);
        continue;
      }
      if (name == 'Params' || _d(s, 'Selected', 0) == 0) continue;
      final pts = <(int, double, double)>[];
      for (final MapEntry(:key, :value) in s.entries) {
        if (!key.startsWith('Point_')) continue;
        final n = csInt(key.substring(6));
        if (n == null) continue;
        final xy = value.split(',');
        if (xy.length != 2) continue;
        final x = csDouble(xy[0]), y = csDouble(xy[1]);
        if (x != null && y != null) pts.add((n, x, y));
      }
      if (pts.isEmpty) continue;
      // List.Sort in .NET is not stable, but point numbers never repeat in a real file
      pts.sort((p, q) => p.$1.compareTo(q.$1));
      final sc = MoveSection(name)
        ..tr = _d(s, 'Transition', 2).truncate()
        ..dur = math.max(100.0, _d(s, 'Duration', 200) * 100)
        ..shift = _d(s, 'Shift', 0)
        ..x = [for (final p in pts) p.$2]
        ..y = [for (final p in pts) p.$3];
      if (name == 'Pan/Tilt/uPan/uTilt') {
        m.pt = sc;
      } else {
        // a value graph: in cycle order (a stable sort, as .NET's is for up to 16 points)
        final o = List<int>.generate(sc.x.length, (i) => i);
        mergeSortBy(o, (i) => sc.x[i]);
        sc
          ..x = [for (final i in o) sc.x[i]]
          ..y = [for (final i in o) sc.y[i]];
        m.vals.add(sc);
      }
    }
    if (m.heads.isEmpty) throw PlayerError(unp.isNotEmpty ? "none of its heads are in the show's fixture list" : 'it has no heads');
    final pt = m.pt;
    if (pt == null && m.vals.isEmpty) throw PlayerError('nothing in it is ticked to play');
    if (pt != null) {
      var x0 = double.maxFinite, x1 = -double.maxFinite, y0 = double.maxFinite, y1 = -double.maxFinite;
      for (var i = 0; i < pt.x.length; i++) {
        x0 = math.min(x0, pt.x[i]);
        x1 = math.max(x1, pt.x[i]);
        y0 = math.min(y0, pt.y[i]);
        y1 = math.max(y1, pt.y[i]);
      }
      m
        ..cx = (x0 + x1) / 2
        ..cy = (y0 + y1) / 2
        ..points = pt.x.length;
    }
    m.unpatched = unp.length;
    return _moves[path] = m;
  }
}

/// The file's time stamp, or .NET's "file not found" message.
DateTime _stamp(String path) {
  final f = File(path);
  if (!f.existsSync()) throw PlayerError("Could not find file '$path'.");
  return f.lastModifiedSync();
}

String _trimStartBom(String s) {
  var i = 0;
  while (i < s.length && s.codeUnitAt(i) == 0xFEFF) {
    i++;
  }
  return s.substring(i);
}

double _d(Map<String, String> s, String k, double def) {
  final v = s[k];
  return v == null ? def : (csDouble(v) ?? def);
}

/// A stable sort of [list] by [key].
void mergeSortBy<T>(List<T> list, double Function(T) key) {
  final keyed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  keyed.sort((a, b) {
    final c = key(a.$2).compareTo(key(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = keyed[i].$2;
  }
}

double _frac(double v) => v - v.floorToDouble();

/// Catmull-Rom, for value graphs.
double _cr(double p0, double p1, double p2, double p3, double t) =>
    0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);

/// The pan/tilt curve: like Catmull-Rom but with tangents 0.75 x (next -
/// previous) instead of 0.5. Measured 2026-11-23 on ShowXpress's own Art-Net
/// output (AROUND ROOM / FIGURE 8 / ZIG ZAG): 0.75 fits to ~10/65535, 0.5
/// swung ~9% short.
const ptTension = 0.75;

double _card(double p0, double p1, double p2, double p3, double t) {
  final m1 = ptTension * (p2 - p0), m2 = ptTension * (p3 - p1), t2 = t * t, t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2;
}

int _c16(double v) => csRound0(math.max(0.0, math.min(65535.0, v))).toInt();

void _put(Uint8List f, MoveHead h, String ch, int v) {
  final ix = h.ix[ch];
  if (ix == null) return;
  final d = h.a0 + ix;
  if (d >= 0 && d < dmxFrameSize) f[d] = v.clamp(0, 255);
}

/// A value graph at x (0..65535).
double _valAt(MoveSection v, double x) {
  final n = v.x.length;
  if (n == 1 || x <= v.x[0]) return v.y[0];
  if (x >= v.x[n - 1]) return v.y[n - 1];
  var j = 0;
  while (j < n - 2 && x >= v.x[j + 1]) {
    j++;
  }
  if (v.tr == 0) return v.y[j];
  final w = v.x[j + 1] - v.x[j];
  final t = w > 0 ? (x - v.x[j]) / w : 0.0;
  if (v.tr == 1) return v.y[j] + (v.y[j + 1] - v.y[j]) * t;
  return _cr(v.y[math.max(0, j - 1)], v.y[j], v.y[j + 1], v.y[math.min(n - 1, j + 2)], t);
}

/// Writes movement [m] at [el] ms after it was pressed into frame [f].
/// Returns the first head's pan/tilt point (0-based), for the status.
///
/// Port of `Eval`.
int evalMove(Move m, double el, Uint8List f) {
  var first = -1;
  for (final h in m.heads) {
    final p = m.pt;
    if (p != null) {
      final n = p.x.length;
      final s = _frac(el / p.dur - h.k * p.shift / 100.0) * n;
      final i = math.min(n - 1, s.floor());
      final t = s - i;
      double px, py;
      if (p.tr == 0 || n == 1) {
        px = p.x[i];
        py = p.y[i];
      } else if (p.tr == 1) {
        final j = (i + 1) % n;
        px = p.x[i] + (p.x[j] - p.x[i]) * t;
        py = p.y[i] + (p.y[j] - p.y[i]) * t;
      } else {
        final a = (i - 1 + n) % n, b = (i + 1) % n, c = (i + 2) % n;
        px = _card(p.x[a], p.x[i], p.x[b], p.x[c], t);
        py = _card(p.y[a], p.y[i], p.y[b], p.y[c], t);
      }
      if (first < 0) first = i;
      px = m.cx + (px - m.cx) * h.zp + h.op;
      py = m.cy + (py - m.cy) * h.zt + h.ot;
      if (h.rp) px = 65535 - px;
      if (h.rt) py = 65535 - py;
      final pv = _c16(px), tv = _c16(py);
      _put(f, h, 'pan', pv >> 8);
      _put(f, h, 'upan', pv & 255);
      _put(f, h, 'tilt', tv >> 8);
      _put(f, h, 'utilt', tv & 255);
    }
    for (final v in m.vals) {
      if (!h.ix.containsKey(v.name)) continue;
      final x = _frac(el / v.dur - h.k * v.shift / 100.0) * 65535;
      _put(f, h, v.name, _c16(_valAt(v, x)) >> 8);
    }
  }
  return math.max(0, first);
}
