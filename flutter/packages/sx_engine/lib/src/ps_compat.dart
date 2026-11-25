/// PowerShell habits the old tools rely on, reproduced so the Dart ports give
/// the same answers. Read `CLAUDE.md` ("PowerShell traps") before porting a tool.
library;

import 'package:collection/collection.dart';

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
/// names with punctuation, that is why.
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
