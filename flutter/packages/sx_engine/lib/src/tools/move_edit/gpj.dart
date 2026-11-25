/// Reading and changing a ShowXpress Generator movement (`.gpj`) as text.
///
/// A `.gpj` is an ini file. A save never rebuilds it: it starts from the
/// file's own lines and changes only the values that were edited and the
/// block of `Point_N` lines of a section whose points were edited. Every
/// other line, each line's own ending and the byte order mark stay as found.
///
/// Port of the reading and editing half of `move_edit.ps1`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';

// ---------------------------------------------------------------- PowerShell number and text habits

/// `"$x"` of a value read from JSON: doubles as [psDoubleText] writes them,
/// booleans as `True`/`False`, null as ''.
String psText(Object? v) => switch (v) {
  null => '',
  bool b => b ? 'True' : 'False',
  int i => '$i',
  double d => psDoubleText(d),
  List l => l.map(psText).join(' '),
  _ => '$v',
};

final _intText = RegExp(r'^[\t\n\v\f\r ]*([+-]?[0-9]+)[\t\n\v\f\r ]*$');
final _floatText = RegExp(r'^[\t\n\v\f\r ]*([+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?)[\t\n\v\f\r ]*$');
final _specialText = RegExp(r'^[\t\n\v\f\r ]*([+-]?)(nan|infinity|∞)[\t\n\v\f\r ]*$', caseSensitive: false);

/// `[int]::TryParse(s)`: optional sign and spaces, ASCII digits, 32 bits.
int? netInt(String s) {
  final m = _intText.firstMatch(s);
  if (m == null) return null;
  final v = int.tryParse(m[1]!);
  return v == null || v < -2147483648 || v > 2147483647 ? null : v;
}

/// `[double]::TryParse(s, Float, InvariantCulture)`: '.' decimal point, no
/// thousands separator, an exponent, NaN and Infinity.
double? netDouble(String s) {
  final m = _floatText.firstMatch(s);
  if (m != null) return double.parse(m[1]!);
  final sp = _specialText.firstMatch(s);
  if (sp == null) return null;
  if (sp[2]!.toLowerCase() == 'nan') return double.nan;
  return sp[1] == '-' ? double.negativeInfinity : double.infinity;
}

/// `Format-Num $v $true`: how ShowXpress writes Shift, always with a decimal
/// point ("0.0", "12.5"), at most 4 decimals.
///
/// `[math]::Round($v, 4)` differs between the two .NETs, so this follows
/// [psFlavor]. Windows PowerShell 5.1 (.NET Framework) multiplies by 10000 as
/// a double and rounds that halves to even: 0.00005 becomes 0.0. PowerShell 7
/// (.NET 11) rounds the double's exact value: 0.00005 is a hair above half and
/// becomes 0.0001. Only values with more than 4 decimals can differ, and the
/// screen sends at most 2.
String formatShift(double v) {
  if (!v.isFinite) return netNumber(v);
  if (psFlavor == PsFlavor.winPs51) return _formatShift51(v);
  final q = _round4(v.abs());
  final digits = q.toString().padLeft(5, '0');
  var s = '${digits.substring(0, digits.length - 4)}.${digits.substring(digits.length - 4)}'.replaceFirst(RegExp(r'0{1,3}$'), '');
  if (v < 0 && q != BigInt.zero) s = '-$s';
  return s;
}

/// [formatShift] on .NET Framework: `Math.Round(v, 4)` is `Math.Round(v * 10000) / 10000`
/// for values under 1E+16 (others come back unchanged), then `ToString('0.0###')`
/// takes 15 significant digits and rounds them to 4 decimals, halves up.
String _formatShift51(double v) {
  final r = v.abs() >= 1e16 ? v.abs() : _roundEven(v.abs() * 10000) / 10000;
  final m = RegExp(r'^(\d)\.(\d+)e([+-]\d+)$').firstMatch(r.toStringAsExponential(14))!;
  final ds = BigInt.parse('${m[1]}${m[2]}'), k = int.parse(m[3]!) - 10; // r = ds * 10^(k - 4)
  var q = ds;
  if (k >= 0) {
    q = ds * BigInt.from(10).pow(k);
  } else {
    final d = BigInt.from(10).pow(-k);
    q = ds ~/ d;
    if ((ds - q * d) * BigInt.two >= d) q += BigInt.one;
  }
  final digits = q.toString().padLeft(5, '0');
  final s = '${digits.substring(0, digits.length - 4)}.${digits.substring(digits.length - 4)}'.replaceFirst(RegExp(r'0{1,3}$'), '');
  return v < 0 && q != BigInt.zero ? '-$s' : s;
}

/// .NET's `Math.Round(double)`: to a whole number, halves to even.
double _roundEven(double x) {
  final f = x.floorToDouble(), diff = x - f;
  if (diff < 0.5) return f;
  if (diff > 0.5) return f + 1;
  return f % 2 == 0 ? f : f + 1;
}

/// [v] (not negative) times 10000, rounded from its exact binary value, halves to even.
BigInt _round4(double v) {
  final bits = (ByteData(8)..setFloat64(0, v)).getUint64(0);
  final e = (bits >> 52) & 0x7FF;
  var m = BigInt.from(bits & 0xFFFFFFFFFFFFF);
  if (e != 0) m += BigInt.one << 52;
  final exp = (e == 0 ? 1 : e) - 1075; // v = m * 2^exp
  final n = m * BigInt.from(10000);
  if (exp >= 0) return n << exp;
  final d = BigInt.one << -exp;
  final q = n ~/ d, r2 = (n - q * d) * BigInt.two;
  if (r2 > d || (r2 == d && q.isOdd)) return q + BigInt.one;
  return q;
}

String bytesSha(List<int> b) => sha256.convert(b).toString();

// ---------------------------------------------------------------- reading

/// A case-insensitive map that keeps the order keys were first set, like a
/// PowerShell `[ordered]@{}`. Setting a key again keeps its place.
typedef CiMap<V> = CanonicalizedMap<String, String, V>;

CiMap<V> _ci<V>() => CanonicalizedMap<String, String, V>((k) => k.toLowerCase());

/// The bytes of a movement file and, when they are plain UTF-8, its text.
class GpjFile {
  GpjFile._(this.bytes, this.bom, this.text, this.why, this.sha);

  /// Port of `Read-MoveBytes`.
  factory GpjFile.read(Uint8List b) {
    final bom = b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;
    String? t;
    var why = '';
    try {
      t = const Utf8Decoder(allowMalformed: false).convert(b, bom ? 3 : 0);
    } on FormatException {
      why = 'the file is not plain UTF-8 text';
    }
    if (t != null && !const ListEquality<int>().equals(gpjBytes(t, bom), b)) {
      why = 'the file does not read back the same way';
      t = null;
    }
    return GpjFile._(b, bom, t, why, bytesSha(b));
  }

  final Uint8List bytes;
  final bool bom;
  final String? text;
  final String why;
  final String sha;
}

/// Text to bytes, with a byte order mark when [bom]. Port of `ConvertTo-Bytes`.
Uint8List gpjBytes(String text, bool bom) => Uint8List.fromList([
  if (bom) ...[0xEF, 0xBB, 0xBF],
  ...utf8.encode(text),
]);

/// A line and its own ending ('\r\n', '\n', '\r' or '' for the last line).
typedef GpjLine = (String, String);

/// Port of `Split-Lines`. Joining the lines back gives [t] exactly.
List<GpjLine> splitLines(String t) {
  final r = <GpjLine>[];
  var i = 0;
  while (i < t.length) {
    var j = i;
    while (j < t.length && t.codeUnitAt(j) != 13 && t.codeUnitAt(j) != 10) {
      j++;
    }
    if (j == t.length) {
      r.add((t.substring(i), ''));
      break;
    }
    final end = t.codeUnitAt(j) == 13 && j + 1 < t.length && t.codeUnitAt(j + 1) == 10 ? '\r\n' : t[j];
    r.add((t.substring(i, j), end));
    i = j + end.length;
  }
  return r;
}

String joinLines(Iterable<GpjLine> lines) {
  final sb = StringBuffer();
  for (final (a, b) in lines) {
    sb
      ..write(a)
      ..write(b);
  }
  return sb.toString();
}

/// A `[Fixture_N]` section.
class GpjHead {
  GpjHead(this.k, this.sec);

  final int k;
  final String sec;
  final keys = _ci<String>();

  /// Key to the line it is on.
  final at = _ci<int>();
}

/// A channel section (`[Pan/Tilt/uPan/uTilt]`, `[dimmer]`...).
class GpjSec {
  GpjSec(this.name, this.last);

  final String name;
  final keys = _ci<String>();
  final at = _ci<int>();
  final pts = <MovePt>[];

  /// The line each point is on.
  final ptAt = <int>[];

  /// True when the points (or a key) are written in a way the editor leaves alone.
  var ptBad = false;

  /// The section's last `key = value` line (or its header).
  int last;
}

/// A movement read from its text, with where each value sits. [why] is a
/// reason it can't be changed here ('' when it can).
class GpjMove {
  GpjMove._(this.lines);

  /// Port of `Read-Move`.
  factory GpjMove.read(String t) {
    final m = GpjMove._(splitLines(t));
    final seen = psMap<bool>();
    final section = RegExp(r'^\[(.+)\]$');
    final fixture = RegExp(r'^Fixture_(\d+)$', caseSensitive: false);
    final point = RegExp(r'^Point_(\d+)$', caseSensitive: false);
    final pointValue = RegExp(r'^(-?\d+),(-?\d+)$');
    var kind = '';
    GpjHead? head;
    GpjSec? sec;
    for (var i = 0; i < m.lines.length; i++) {
      var l = m.lines[i].$1;
      if (i == 0) l = l.replaceFirst(RegExp('^﻿+'), '');
      final sm = section.firstMatch(l);
      if (sm != null) {
        final nm = sm[1]!;
        if (seen.containsKey(nm)) m.why = 'the section [$nm] is in the file twice';
        seen[nm] = true;
        final fm = fixture.firstMatch(nm);
        if (psEq(nm, 'Params')) {
          kind = 'p';
        } else if (fm != null) {
          kind = 'h';
          head = GpjHead(int.parse(fm[1]!), nm);
          m.heads.add(head);
        } else {
          kind = 's';
          sec = GpjSec(nm, i);
          m.secs.add(sec);
        }
        continue;
      }
      if (kind.isEmpty) continue;
      final e = l.indexOf(' = ');
      if (e < 1) continue;
      final k = l.substring(0, e), v = l.substring(e + 3);
      if (kind == 'p') {
        m.params[k] = v;
        continue;
      }
      if (kind == 's') {
        final s = sec!;
        s.last = i;
        final pm = point.firstMatch(k);
        if (pm != null) {
          final vm = pointValue.firstMatch(v);
          if (vm != null && int.parse(pm[1]!) == s.pts.length) {
            s.pts.add((int.parse(vm[1]!), int.parse(vm[2]!)));
            s.ptAt.add(i);
          } else {
            s.ptBad = true;
          }
          continue;
        }
        if (s.keys.containsKey(k)) s.ptBad = true; // a key twice: don't touch this section
        s.keys[k] = v;
        s.at[k] = i;
      } else {
        final h = head!;
        // The old tool sets ptBad on a head object, which has no such
        // property: PowerShell stops with this error. Kept as it was.
        if (h.keys.containsKey(k)) {
          throw ToolError(
            'Exception setting "ptBad": "The property \'ptBad\' cannot be found on this object. Verify that the property exists and can be set."',
          );
        }
        h.keys[k] = v;
        h.at[k] = i;
      }
    }
    for (final s in m.secs) {
      // The points have to be one block of lines (Point_0, Point_1, ... one after the other).
      for (var j = 1; j < s.ptAt.length; j++) {
        if (s.ptAt[j] != s.ptAt[j - 1] + 1) s.ptBad = true;
      }
    }
    if (m.heads.isEmpty && m.why.isEmpty) m.why = 'it has no heads';
    return m;
  }

  final List<GpjLine> lines;
  final params = _ci<String>();
  final heads = <GpjHead>[];
  final secs = <GpjSec>[];
  var why = '';
}

/// A movement file opened: its bytes, and the movement when it could be read.
class OpenMove {
  OpenMove(this.file, this.m);

  /// Port of `Open-Move`.
  factory OpenMove.read(Uint8List bytes) {
    final f = GpjFile.read(bytes);
    return OpenMove(f, f.text == null ? null : GpjMove.read(f.text!));
  }

  final GpjFile file;
  final GpjMove? m;

  String get why => file.why.isNotEmpty ? file.why : (m?.why ?? '');
}

/// `Get-D`: a number from a key, or [def] when it is missing or not a number.
double _d(CiMap<String> keys, String k, double def) {
  final v = keys[k];
  if (v == null) return def;
  return netDouble(v) ?? def;
}

const headKeys = ['OffsetPan', 'OffsetTilt', 'ZoomPan', 'ZoomTilt'];
const secKeys = ['Selected', 'Transition', 'Duration', 'Shift'];

/// A head as the model has it (Open adds the label, model and DMX address).
class ModelHead {
  ModelHead(this.k, this.id, this.name, this.dmx, this.chans, this.rp, this.rt, this.op, this.ot, this.zp, this.zt, this.has);

  final int k;
  final String id, name, dmx;
  final List<String> chans;
  final int rp, rt;
  double op, ot, zp, zt;
  final List<String> has;

  Object? key() => [k, id, name, dmx, chans, rp, rt, op, ot, zp, zt, has];
}

/// The plain model of a movement, for the page and for the self-check (the
/// same function reads the old and the new file). Port of `Get-Model`.
class MoveModel {
  MoveModel(this.heads, this.secs);

  factory MoveModel.of(GpjMove m) => MoveModel(
    [
      for (final h in m.heads)
        ModelHead(
          h.k,
          h.keys['ID'] ?? '',
          h.keys['Name'] ?? '',
          h.keys['DMX'] ?? '',
          [
            for (final c in (h.keys['Channels'] ?? '').split(','))
              if (c.trim().isNotEmpty) c.trim(),
          ],
          psRound(_d(h.keys, 'ReversePan', 0)),
          psRound(_d(h.keys, 'ReverseTilt', 0)),
          _d(h.keys, 'OffsetPan', 0),
          _d(h.keys, 'OffsetTilt', 0),
          _d(h.keys, 'ZoomPan', 0),
          _d(h.keys, 'ZoomTilt', 0),
          [
            for (final k in headKeys)
              if (h.keys.containsKey(k)) k,
          ],
        ),
    ],
    [
      for (final s in m.secs)
        MoveSection(
          name: s.name,
          sel: psRound(_d(s.keys, 'Selected', 0)),
          tr: psRound(_d(s.keys, 'Transition', 2)),
          dur: _d(s.keys, 'Duration', 200),
          shift: _d(s.keys, 'Shift', 0),
          curve: s.keys['CurveName'] ?? '',
          pts: [...s.pts],
          locked: s.ptBad,
          has: [
            for (final k in secKeys)
              if (s.keys.containsKey(k)) k,
          ],
        ),
    ],
  );

  final List<ModelHead> heads;
  final List<MoveSection> secs;

  /// `Get-ModelJson`: what two models are compared by.
  String key() => jsonEncode([
    [for (final h in heads) h.key()],
    [for (final s in secs) s.toJson()],
  ]);

  MoveSection? sec(String name) => secs.firstWhereOrNull((s) => psEq(s.name, name));
}

// ---------------------------------------------------------------- the change, done on the text

/// Replace [n] lines from [at] with [lines].
typedef GpjEdit = ({int at, int n, List<GpjLine> lines});

/// What a change does to a file: its new bytes, and what changed in words.
class MoveResult {
  MoveResult(this.bytes, this.what, this.ptsChanged, this.newPts);

  final Uint8List bytes;
  final String what;

  /// True when the pan/tilt shape changed.
  final bool ptsChanged;
  final List<MovePt> newPts;
}

/// Reads a JSON value the way PowerShell reads a property of a
/// `ConvertFrom-Json` object: the name ignores case.
Object? prop(Object? o, String name) {
  if (o is! Map) return null;
  if (o.containsKey(name)) return o[name];
  for (final e in o.entries) {
    if (e.key is String && psEq(e.key as String, name)) return e.value;
  }
  return null;
}

/// `@($x | Where-Object { $_ })`: a JSON value as a list, without nulls and other false values.
List<Object?> psList(Object? v) {
  final l = v is List ? v : [v];
  return [
    for (final x in l)
      if (!(x == null || x == false || x == 0 || x == '' || (x is List && x.isEmpty))) x,
  ];
}

/// Checks [ch] against the file and works out the line edits. Port of `Test-Changes`.
List<GpjEdit> _testChanges(OpenMove o, Map<String, Object?> ch, String? own) {
  final m = o.m!;
  final edits = <GpjEdit>[];
  final secBy = psMap<GpjSec>();
  for (final s in m.secs) {
    secBy[s.name] = s;
  }
  final headBy = <int, GpjHead>{};
  for (final h in m.heads) {
    headBy[h.k] = h;
  }
  final done = psMap<bool>();

  void setKey(CiMap<int> at, String k, String v, String what) {
    final i = at[k];
    if (i == null) throw ToolError("$what has no '$k' line, so it can't be changed here - change it once in ShowXpress. NOTHING was changed.");
    final old = m.lines[i].$1, pre = old.substring(0, old.indexOf(' = ') + 3);
    if (old.substring(pre.length) != v) {
      edits.add((at: i, n: 1, lines: [('$pre$v', m.lines[i].$2)]));
    }
  }

  for (final c in psList(prop(ch, 'secs'))) {
    final nm = psText(prop(c, 'name'));
    final s = secBy[nm];
    if (s == null) throw ToolError("The movement has no channel '$nm'. NOTHING was changed.");
    if (done.containsKey('s|$nm')) throw ToolError("'$nm' was sent twice. NOTHING was changed.");
    done['s|$nm'] = true;
    final what = "Channel '$nm'";
    final sel = prop(c, 'sel'), tr = prop(c, 'tr'), dur = prop(c, 'dur'), shift = prop(c, 'shift'), pts = prop(c, 'pts');
    if (sel != null) {
      final t = psText(sel).toLowerCase();
      if (!['0', '1', 'true', 'false'].contains(t)) throw ToolError('$what : Selected has to be on or off. NOTHING was changed.');
      setKey(s.at, 'Selected', t == '1' || t == 'true' ? '1' : '0', what);
    }
    if (tr != null) {
      final t = psText(tr);
      // .NET's `$` also matches before a final line break.
      if (!RegExp(r'^[012]\n?$').hasMatch(t)) throw ToolError('$what : the transition has to be points, lines or curves. NOTHING was changed.');
      setKey(s.at, 'Transition', t, what);
    }
    if (dur != null) {
      final d = netInt(psText(dur));
      if (d == null || d < 1 || d > 360000) throw ToolError('$what : the cycle has to be 0.1 s to 10 hours. NOTHING was changed.');
      setKey(s.at, 'Duration', '$d', what);
    }
    if (shift != null) {
      final d = netDouble(psText(shift));
      if (d == null || d < 0 || d > 100) throw ToolError('$what : the shift has to be 0 to 100 %. NOTHING was changed.');
      setKey(s.at, 'Shift', formatShift(d), what);
    }
    if (pts != null) {
      if (s.ptBad) throw ToolError("$what : its points are written in a way SX Studio doesn't change - edit them in ShowXpress. NOTHING was changed.");
      final list = [
        for (final p in pts is List ? pts : [pts]) p is List ? p : [p],
      ];
      if (list.isEmpty || list.length > 256) throw ToolError('$what : a movement needs 1 to 256 points. NOTHING was changed.');
      var nl = s.ptAt.isNotEmpty ? m.lines[s.ptAt[0]].$2 : m.lines[s.last].$2;
      if (nl.isEmpty) nl = o.file.text!.contains('\r\n') ? '\r\n' : '\n';
      final add = <GpjLine>[];
      for (var j = 0; j < list.length; j++) {
        final p = list[j];
        final x = p.length == 2 ? netInt(psText(p[0])) : null, y = p.length == 2 ? netInt(psText(p[1])) : null;
        if (x == null || y == null || x < 0 || x > 65535 || y < 0 || y > 65535) {
          throw ToolError('$what : point ${j + 1} is not two numbers 0..65535. NOTHING was changed.');
        }
        add.add(('Point_$j = $x,$y', nl));
      }
      if (s.ptAt.isNotEmpty) {
        // Keep the block's own last ending.
        add[add.length - 1] = (add.last.$1, m.lines[s.ptAt.last].$2);
        var same = s.ptAt.length == add.length;
        for (var j = 0; same && j < add.length; j++) {
          if (m.lines[s.ptAt[j]].$1 != add[j].$1) same = false;
        }
        if (!same) edits.add((at: s.ptAt[0], n: s.ptAt.length, lines: add));
      } else {
        // No points yet: after the section's last line (which gets a line ending if it was the file's last line).
        final i = s.last, l = m.lines[i];
        final lines = <GpjLine>[(l.$1, l.$2.isNotEmpty ? l.$2 : nl), ...add];
        if (l.$2.isEmpty) lines[lines.length - 1] = (lines.last.$1, '');
        edits.add((at: i, n: 1, lines: lines));
      }
    }
  }

  for (final c in psList(prop(ch, 'heads'))) {
    final kv = prop(c, 'k');
    final k = netInt(psText(kv));
    if (k == null || !headBy.containsKey(k)) throw ToolError('The movement has no head number ${psText(kv)}. NOTHING was changed.');
    if (done.containsKey('h|$k')) throw ToolError('Head $k was sent twice. NOTHING was changed.');
    done['h|$k'] = true;
    final h = headBy[k]!;
    final what = 'Head ${h.keys['Name'] ?? ''}';
    for (final (p, key, lo, hi) in const [
      ('op', 'OffsetPan', -65535, 65535),
      ('ot', 'OffsetTilt', -65535, 65535),
      ('zp', 'ZoomPan', -99, 900),
      ('zt', 'ZoomTilt', -99, 900),
    ]) {
      final v = prop(c, p);
      if (v == null) continue;
      if (own != null) {
        throw ToolError(
          '$what : Aim Movers sets the aim and size of the heads in this movement${own == 'room' ? ' (Room)' : ''} - change them there. NOTHING was changed.',
        );
      }
      final d = netInt(psText(v));
      if (d == null || d < lo || d > hi) throw ToolError('$what : $key has to be a whole number $lo..$hi. NOTHING was changed.');
      setKey(h.at, key, '$d', what);
    }
    for (final q in const ['rp', 'rt']) {
      if (prop(c, q) != null) throw ToolError('$what : Reverse is set by Reverse heads in SX Studio, not here. NOTHING was changed.');
    }
  }
  // No two edits on the same lines.
  final sorted = psSorted<GpjEdit>(edits, [(e) => e.at]);
  for (var j = 1; j < sorted.length; j++) {
    if (sorted[j].at < sorted[j - 1].at + sorted[j - 1].n) throw ToolError('Self-check failed (two changes on the same line). NOTHING was changed.');
  }
  return sorted;
}

/// Port of `Get-ChangedText`.
String _changedText(List<GpjLine> l, List<GpjEdit> edits) {
  final out = <GpjLine>[];
  var i = 0;
  for (final e in edits) {
    while (i < e.at) {
      out.add(l[i++]);
    }
    out.addAll(e.lines);
    i += e.n;
  }
  while (i < l.length) {
    out.add(l[i++]);
  }
  return joinLines(out);
}

/// The same changes made on the plain model, the second, independent way.
/// Port of `Get-ExpectedModel`.
MoveModel _expectedModel(OpenMove o, Map<String, Object?> ch) {
  final mo = MoveModel.of(o.m!);
  for (final c in psList(prop(ch, 'secs'))) {
    final name = psText(prop(c, 'name'));
    final i = mo.secs.indexWhere((s) => psEq(s.name, name));
    final s = mo.secs[i];
    final sel = prop(c, 'sel'), tr = prop(c, 'tr'), dur = prop(c, 'dur'), shift = prop(c, 'shift'), pts = prop(c, 'pts');
    mo.secs[i] = MoveSection(
      name: s.name,
      sel: sel == null ? s.sel : (['1', 'true'].contains(psText(sel).toLowerCase()) ? 1 : 0),
      tr: tr == null ? s.tr : psInt(psText(tr).trim()),
      dur: dur == null ? s.dur : netInt(psText(dur))!.toDouble(),
      shift: shift == null ? s.shift : netDouble(formatShift(netDouble(psText(shift))!))!,
      curve: s.curve,
      pts: pts == null
          ? s.pts
          : [
              for (final p in pts is List ? pts : [pts]) (netInt(psText((p as List)[0]))!, netInt(psText(p[1]))!),
            ],
      locked: s.locked,
      has: s.has,
    );
  }
  for (final c in psList(prop(ch, 'heads'))) {
    final k = netInt(psText(prop(c, 'k')));
    final h = mo.heads.firstWhere((h) => h.k == k);
    for (final p in const ['op', 'ot', 'zp', 'zt']) {
      final v = prop(c, p);
      if (v == null) continue;
      final d = netInt(psText(v))!.toDouble();
      switch (p) {
        case 'op':
          h.op = d;
        case 'ot':
          h.ot = d;
        case 'zp':
          h.zp = d;
        default:
          h.zt = d;
      }
    }
  }
  return mo;
}

String _ptsKey(MoveSection? s) => s == null ? 'null' : jsonEncode(s.toJson()['pts']);

/// The new bytes for [ch], after every check. Throws when anything doesn't add up.
/// [own] is the Aim Movers owner of the movement, if any. Port of `Get-NewBytes`.
MoveResult newBytes(OpenMove o, Map<String, Object?> ch, String? own) {
  final edits = _testChanges(o, ch, own);
  final nt = _changedText(o.m!.lines, edits);
  final re = GpjMove.read(nt);
  if (re.why.isNotEmpty || MoveModel.of(re).key() != _expectedModel(o, ch).key()) {
    throw ToolError("Self-check failed (the new movement doesn't read back as asked). NOTHING was changed.");
  }
  // Every line that wasn't edited is still there, in the same order.
  final keep = <int>{};
  for (final e in edits) {
    for (var j = 0; j < e.n; j++) {
      keep.add(e.at + j);
    }
  }
  final a = StringBuffer();
  for (var j = 0; j < o.m!.lines.length; j++) {
    if (!keep.contains(j)) a.write('${o.m!.lines[j].$1}${o.m!.lines[j].$2}\x00');
  }
  final edited = <int>{};
  var pos = 0, idx = 0;
  for (final e in edits) {
    idx += e.at - pos;
    for (var j = 0; j < e.lines.length; j++) {
      edited.add(idx + j);
    }
    idx += e.lines.length;
    pos = e.at + e.n;
  }
  final b = StringBuffer();
  for (var j = 0; j < re.lines.length; j++) {
    if (!edited.contains(j)) b.write('${re.lines[j].$1}${re.lines[j].$2}\x00');
  }
  if (a.toString() != b.toString()) throw ToolError("Self-check failed (a line that wasn't edited would change). NOTHING was changed.");

  // What changed, in words.
  final old = MoveModel.of(o.m!), now = MoveModel.of(re);
  final w = <String>[];
  for (final s in now.secs) {
    final os = old.sec(s.name)!;
    final d = [
      if (_ptsKey(os) != _ptsKey(s)) 'shape',
      if (os.sel != s.sel) s.sel != 0 ? 'on' : 'off',
      if (os.tr != s.tr) 'transition',
      if (os.dur != s.dur) 'cycle time',
      if (os.shift != s.shift) 'shift',
    ];
    if (d.isNotEmpty) w.add('${psEq(s.name, movePtSection) ? 'pan/tilt' : s.name} (${d.join(', ')})');
  }
  var nh = 0;
  for (var j = 0; j < now.heads.length; j++) {
    if (jsonEncode(old.heads[j].key()) != jsonEncode(now.heads[j].key())) nh++;
  }
  if (nh > 0) w.add('$nh head(s) aim/size');
  final oldPt = old.sec(movePtSection), newPt = now.sec(movePtSection);
  return MoveResult(gpjBytes(nt, o.file.bom), w.join('; '), _ptsKey(oldPt) != _ptsKey(newPt), newPt?.pts ?? const []);
}
