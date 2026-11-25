/// .NET habits the SX Player's C# relies on, so the Dart port computes the
/// same frames. The PowerShell side has its own helpers in `ps_compat.dart`.
library;

import '../ps_compat.dart';

/// C# `int.TryParse(s, out v)`: optional white space around an optional sign
/// and digits, inside the 32-bit range. Null when that fails.
int? csInt(String s) {
  final m = RegExp(r'^\s*([+-]?\d+)\s*$').firstMatch(s);
  if (m == null) return null;
  final v = int.tryParse(m[1]!);
  if (v == null || v < -2147483648 || v > 2147483647) return null;
  return v;
}

/// C# `double.TryParse(s, NumberStyles.Float, InvariantCulture, out v)`.
/// Null when that fails.
double? csDouble(String s) {
  final t = s.trim();
  if (t.isEmpty || !RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$|^[+-]?Infinity$|^NaN$').hasMatch(t)) return null;
  return double.tryParse(t);
}

/// C# `Math.Round(v)`: halves go to the even number.
double csRound0(double v) => psRound(v).toDouble();

/// C# `Math.Round(v, digits)`, which scales, rounds half to even, and scales back.
double csRound(double v, int digits) {
  var p = 1.0;
  for (var i = 0; i < digits; i++) {
    p *= 10;
  }
  return psRound(v * p) / p;
}

/// C# `(long)Math.Floor(v)`.
int csFloor(double v) => v.floor();

/// `v.ToString("0.###", InvariantCulture)` read back as a number, which is how
/// the old status file carried fader positions and the beat.
double csFixed(double v, int digits) => double.parse(v.toStringAsFixed(digits));
