import 'gpj.dart';

/// Writes a decoded JSON value the way PowerShell 7's `ConvertTo-Json` does
/// (Newtonsoft, indented by two spaces, `"key": value`, LF line ends, doubles
/// always with a decimal point or an exponent).
///
/// Used to write back another tab's state file the old tools rewrote with
/// `ConvertFrom-Json | ... | ConvertTo-Json`, so the bytes match.
/// Windows PowerShell 5.1 lays the same JSON out differently (wider indents,
/// CRLF); the old app on Windows wrote that layout. Both read the same.
String psJsonPretty(Object? v) {
  final sb = StringBuffer();
  _write(sb, v, 0);
  return sb.toString();
}

void _write(StringBuffer sb, Object? v, int depth) {
  final pad = '  ' * (depth + 1), end = '  ' * depth;
  switch (v) {
    case null:
      sb.write('null');
    case bool b:
      sb.write(b ? 'true' : 'false');
    case int i:
      sb.write('$i');
    case double d:
      final s = netNumber(d);
      sb.write(s.contains(RegExp('[.EN]')) || s.contains('Infinity') ? s : '$s.0');
    case String s:
      sb.write(psJsonString(s));
    case List l when l.isEmpty:
      sb.write('[]');
    case List l:
      sb.write('[\n');
      for (var i = 0; i < l.length; i++) {
        sb.write(pad);
        _write(sb, l[i], depth + 1);
        sb.write(i < l.length - 1 ? ',\n' : '\n');
      }
      sb.write('$end]');
    case Map m when m.isEmpty:
      sb.write('{}');
    case Map m:
      sb.write('{\n');
      final keys = m.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        sb.write('$pad${psJsonString('${keys[i]}')}: ');
        _write(sb, m[keys[i]], depth + 1);
        sb.write(i < keys.length - 1 ? ',\n' : '\n');
      }
      sb.write('$end}');
    default:
      sb.write(psJsonString('$v'));
  }
}

/// A JSON string as Newtonsoft escapes it by default: quotes, backslashes,
/// control characters, U+0085, U+2028 and U+2029.
String psJsonString(String s) {
  final sb = StringBuffer('"');
  for (final c in s.codeUnits) {
    switch (c) {
      case 0x22:
        sb.write(r'\"');
      case 0x5C:
        sb.write(r'\\');
      case 0x08:
        sb.write(r'\b');
      case 0x09:
        sb.write(r'\t');
      case 0x0A:
        sb.write(r'\n');
      case 0x0C:
        sb.write(r'\f');
      case 0x0D:
        sb.write(r'\r');
      case < 0x20 || 0x85 || 0x2028 || 0x2029:
        sb.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      default:
        sb.writeCharCode(c);
    }
  }
  sb.write('"');
  return sb.toString();
}
