/// PowerShell habits the old tools rely on, reproduced so the Dart ports give
/// the same answers. Read `CLAUDE.md` ("PowerShell traps") before porting a tool.
library;

import 'package:collection/collection.dart';

/// The two PowerShells the old tools ran under, where they give different
/// answers for the same script.
enum PsFlavor {
  /// Windows PowerShell 5.1 on .NET Framework: what the owner's laptop runs.
  winPs51,

  /// PowerShell 7 on .NET Core.
  ps7,
}

/// Which PowerShell the port copies where 5.1 and 7 differ in something the
/// user sees or that lands in a show file. The app ships with
/// [PsFlavor.winPs51]. Only tests may set it: the parity harness sets it to
/// match the PowerShell it compares against, before the Dart side runs.
var psFlavor = PsFlavor.winPs51;

/// `"$d"`, `[string]$d` and `'{0}' -f $d` of a double. Windows PowerShell 5.1
/// gives 15 significant digits (`110`), PowerShell 7 the shortest text that
/// reads back the same (`110.00000000000001`). Follows [psFlavor].
String psDoubleText(double d) => psFlavor == PsFlavor.winPs51 ? netNumber(d, digits: 15) : netNumber(d);

/// .NET's text for a double: [digits] significant digits (`G15`, .NET
/// Framework's `ToString()`), or the shortest that reads back the same when
/// null (`R`, .NET Core's `ToString()` and JSON writers). `1E+20`, `1E-05`,
/// `0.0001`. Negative zero is `0` with [digits] (.NET Framework) and `-0`
/// without (.NET Core).
String netNumber(double d, {int? digits}) {
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == 0) return d.isNegative && digits == null ? '-0' : '0';
  final e = digits == null ? d.abs().toStringAsExponential() : d.abs().toStringAsExponential(digits - 1);
  final m = RegExp(r'^(\d)(?:\.(\d+))?e([+-]\d+)$').firstMatch(e)!;
  var ds = '${m[1]}${m[2] ?? ''}'.replaceFirst(RegExp(r'0+$'), '');
  if (ds.isEmpty) ds = '0';
  final exp = int.parse(m[3]!);
  final sign = d < 0 ? '-' : '';
  // .NET switches to an exponent from 1E+15 up and from 1E-05 down.
  if (exp >= 15 || exp < -4) {
    final mant = ds.length > 1 ? '${ds[0]}.${ds.substring(1)}' : ds;
    return '$sign${mant}E${exp < 0 ? '-' : '+'}${exp.abs().toString().padLeft(2, '0')}';
  }
  if (exp < 0) return '${sign}0.${'0' * (-exp - 1)}$ds';
  if (ds.length <= exp + 1) return '$sign$ds${'0' * (exp + 1 - ds.length)}';
  return '$sign${ds.substring(0, exp + 1)}.${ds.substring(exp + 1)}';
}

/// PowerShell's `-eq` on strings ignores case.
bool psEq(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// A map whose keys ignore case, like a PowerShell `@{}` hashtable.
///
/// Dart keeps insertion order. PowerShell hashtables have no order, so never
/// rely on order when comparing with old output.
Map<String, V> psMap<V>() => CanonicalizedMap<String, String, V>((k) => k.toLowerCase());

/// `[int]` casts and `[Math]::Round` round halves to the even number
/// (2.5 becomes 2, 3.5 becomes 4). Dart's `round()` goes away from zero.
int psRound(num v) {
  final floor = v.floor();
  final diff = v - floor;
  if (diff < 0.5) return floor;
  if (diff > 0.5) return floor + 1;
  return floor.isEven ? floor : floor + 1;
}

/// `[int]$x` for a value read from a file or JSON. Null and '' are 0, text
/// that is not a number throws like PowerShell does.
int psInt(Object? v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return psRound(v);
  if (v is bool) return v ? 1 : 0;
  final s = '$v'.trim();
  if (s.isEmpty) return 0;
  final i = int.tryParse(s);
  if (i != null) return i;
  final d = double.tryParse(s);
  if (d != null) return psRound(d);
  throw FormatException('Cannot convert "$v" to a whole number.');
}

/// `Sort-Object` with several keys. Stable, and strings compare ignoring case.
///
/// PowerShell compares strings by culture rules, which this only approximates
/// (lowercase, then code units). If a parity test shows a different order for
/// names with punctuation, that is why. Sort by a [PsText] key instead.
List<T> psSorted<T>(Iterable<T> items, List<Comparable Function(T)> keys) {
  int cmp(T a, T b) {
    for (final key in keys) {
      final ka = key(a), kb = key(b);
      final c = (ka is String && kb is String) ? ka.toLowerCase().compareTo(kb.toLowerCase()) : ka.compareTo(kb);
      if (c != 0) return c;
    }
    return 0;
  }

  final list = items.toList();
  mergeSort(list, compare: cmp);
  return list;
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

  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = weight(a.codeUnitAt(i)) - weight(b.codeUnitAt(i));
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// A text key for [psSorted] that compares like [psTextCompare].
class PsText implements Comparable<PsText> {
  PsText(this.s);

  final String s;

  @override
  int compareTo(PsText other) => psTextCompare(s, other.s);
}

/// `yyyy-MM-ddTHH:mm:ss` in local time: .NET's `ToString('s')`, which the old
/// tools use for the times they save. It never follows the machine's culture.
String sortableTime(DateTime t) => t.toIso8601String().substring(0, 19);

/// PowerShell's `-like` with `*` and `?`, ignoring case.
bool psLike(String s, String pattern) {
  final rx = StringBuffer('^');
  for (final ch in pattern.split('')) {
    rx.write(switch (ch) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(ch),
    });
  }
  rx.write(r'$');
  return RegExp(rx.toString(), caseSensitive: false, dotAll: true).hasMatch(s);
}

/// The text PowerShell 7's `ConvertTo-Json` writes for [value]: two-space
/// indent, `"key": value`, LF line ends, and its string escapes. Maps keep
/// their order, so pass them in the order the old tool would write.
///
/// Doubles are refused: .NET writes them its own way (`netNumber` in
/// `tools/move_edit/gpj.dart`). The move editor's `psJsonPretty` is the same
/// writer with doubles, and can switch to this one once `netNumber` lives here.
String psJson(Object? value) {
  final b = StringBuffer();
  void write(Object? v, String indent) {
    final inner = '$indent  ';
    switch (v) {
      case null:
        b.write('null');
      case bool x:
        b.write('$x');
      case int x:
        b.write('$x');
      case String s:
        b.write(_psJsonString(s));
      case List<Object?> l when l.isEmpty:
        b.write('[]');
      case List<Object?> l:
        b.write('[\n');
        for (final (i, e) in l.indexed) {
          b.write(inner);
          write(e, inner);
          b.write(i < l.length - 1 ? ',\n' : '\n');
        }
        b.write('$indent]');
      case Map<String, Object?> m when m.isEmpty:
        b.write('{}');
      case Map<String, Object?> m:
        b.write('{\n');
        for (final (i, e) in m.entries.indexed) {
          b.write('$inner${_psJsonString(e.key)}: ');
          write(e.value, inner);
          b.write(i < m.length - 1 ? ',\n' : '\n');
        }
        b.write('$indent}');
      default:
        throw ArgumentError('psJson: ${v.runtimeType}');
    }
  }

  write(value, '');
  return b.toString();
}

/// A string as Newtonsoft.Json (inside `ConvertTo-Json`) escapes it.
String _psJsonString(String s) {
  final b = StringBuffer('"');
  for (final c in s.runes) {
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x08:
        b.write(r'\b');
      case 0x09:
        b.write(r'\t');
      case 0x0A:
        b.write(r'\n');
      case 0x0C:
        b.write(r'\f');
      case 0x0D:
        b.write(r'\r');
      case < 0x20 || 0x85 || 0x2028 || 0x2029:
        b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      default:
        b.writeCharCode(c);
    }
  }
  b.write('"');
  return b.toString();
}
