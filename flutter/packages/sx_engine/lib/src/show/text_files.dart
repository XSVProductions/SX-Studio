import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _bom = [0xEF, 0xBB, 0xBF];

bool hasBom(List<int> b) => b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;

/// Reads a text file the way .NET's `File.ReadAllText` does: UTF-8, a leading
/// byte order mark is dropped, bad bytes become U+FFFD.
String readText(String path) {
  final b = File(path).readAsBytesSync();
  return utf8.decode(hasBom(b) ? Uint8List.sublistView(b, 3) : b, allowMalformed: true);
}

/// Reads lines the way .NET's `File.ReadAllLines` does: splits on CRLF, LF or
/// CR, and a final line break does not add an empty last line.
List<String> readLines(String path) {
  final lines = readText(path).split(RegExp(r'\r\n|\n|\r'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Replaces [path] with [text] without ever leaving a half-written file.
///
/// Writes a temp file next to the target, flushes it to disk, then renames it
/// over the target. A crash leaves either the old file or the new one.
void writeTextSafely(String path, String text, {required bool bom}) => writeBytesSafely(path, [if (bom) ..._bom, ...utf8.encode(text)]);

void writeBytesSafely(String path, List<int> bytes) {
  final tmp = File('$path.sxtmp');
  final raf = tmp.openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(bytes);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  tmp.renameSync(path);
}
