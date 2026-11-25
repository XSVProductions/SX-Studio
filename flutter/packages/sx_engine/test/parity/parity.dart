/// Old-versus-new checks. Each case runs the old PowerShell tool and its Dart
/// port on the same copy of a show, then compares what they answered and
/// every file they left behind, byte for byte. Under Windows PowerShell 5.1
/// the app's own `.json` state files compare by content instead (see
/// [forCompare]); ShowXpress never reads them.
///
/// Needs three things on this machine, found through environment variables or
/// the usual folder layout. When one is missing the cases are skipped.
///   SX_PWSH     PowerShell 7 (`pwsh`), or Windows PowerShell
///   SX_OLD_SRC  the old app's `src` folder
///   SX_SHOW     a real ShowXpress show folder (never committed, it is the user's)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

String? _firstExisting(Iterable<String?> candidates, {bool dir = false}) {
  for (final c in candidates) {
    if (c == null || c.isEmpty) continue;
    if (dir ? Directory(c).existsSync() : File(c).existsSync()) return c;
  }
  return null;
}

String? _onPath(String exe) {
  for (final d in (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
    for (final ext in Platform.isWindows ? ['.exe'] : ['']) {
      final f = p.join(d, '$exe$ext');
      if (File(f).existsSync()) return f;
    }
  }
  return null;
}

/// `packages/sx_engine`, wherever the tests were started from.
final String _package = () {
  var d = Directory.current.absolute;
  while (!File(p.join(d.path, 'pubspec.yaml')).existsSync() || p.basename(d.path) != 'sx_engine') {
    if (d.parent.path == d.path) return Directory.current.absolute.path;
    d = d.parent;
  }
  return d.path;
}();

/// Looks for [relative] next to this checkout or any folder above it, so the
/// tests find the old app and the show from a git worktree too.
String? _above(String relative, {bool dir = false}) {
  var d = Directory(_package);
  while (true) {
    final c = p.join(d.path, relative);
    if (dir ? Directory(c).existsSync() : File(c).existsSync()) return c;
    if (d.parent.path == d.path) return null;
    d = d.parent;
  }
}

final _env = Platform.environment;
final String? pwshPath = _firstExisting([_env['SX_PWSH'], _above(p.join('tools', 'pwsh', 'pwsh')), _onPath('pwsh'), _onPath('powershell')]);

/// The old app's scripts: `SX_OLD_SRC`, or `repo/src` above (the old app
/// cloned next to the port), or the `src` folder above that holds
/// `df_aim_gui.ps1` (the port inside the SX-Studio repository).
final String? oldSrcPath = _firstExisting([
  _env['SX_OLD_SRC'],
  _above(p.join('repo', 'src'), dir: true),
  if (_above(p.join('src', 'df_aim_gui.ps1')) case final String gui) p.dirname(gui),
], dir: true);
final String? realShowPath = _firstExisting([_env['SX_SHOW'], _above(p.join('real-show', 'Awaaz Lightshow'), dir: true)], dir: true);

/// The major version of the PowerShell at [pwshPath], asked once: 5 for
/// Windows PowerShell 5.1, 7 for PowerShell 7. Null when there is none.
final int? psMajor = () {
  if (pwshPath == null) return null;
  final r = Process.runSync(pwshPath!, ['-NoProfile', '-NonInteractive', '-Command', r'$PSVersionTable.PSVersion.Major']);
  return int.tryParse('${r.stdout}'.trim());
}();

/// True when the old tools run under Windows PowerShell 5.1, the version the
/// old app's owner runs. Its `ConvertTo-Json` lays JSON out differently from
/// PowerShell 7 (wider indents, CRLF, `>` escapes), and it reads and
/// prints scripts in the console's code page.
bool get oldIsWinPs => psMajor != null && psMajor! < 6;

/// Writes a script for `powershell -File`. Under Windows PowerShell the file
/// gets a byte order mark (without one it is read in the ANSI code page) and
/// sets UTF-8 output first (it prints in the console's code page otherwise).
/// The line goes after a leading `param(...)`, which must stay first.
File writePsScript(String path, String body) {
  final f = File(path);
  if (!oldIsWinPs) return f..writeAsStringSync(body);
  const enc = r'[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false';
  final at = body.startsWith('param(') ? body.indexOf('\n') + 1 : 0;
  return f..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode('${body.substring(0, at)}$enc\n${body.substring(at)}')]);
}

/// A JSON number, kept as the text it was written with.
class _JsonNum {
  _JsonNum(this.text);
  final String text;
}

/// A JSON object, keys in file order.
class _JsonObj {
  final entries = <(String, Object?)>[];
}

final _numRx = RegExp(r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?');
final _strRx = RegExp(r'"(?:[^"\\]|\\.)*"');

/// Reads JSON keeping each number's text and each object's key order.
Object? _readJson(String s) {
  var i = 0;
  void ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  String str() {
    final m = _strRx.matchAsPrefix(s, i) ?? (throw FormatException('string expected', s, i));
    i = m.end;
    return jsonDecode(m[0]!) as String;
  }

  // the character at i, or a FormatException at the end of the text
  String peek() => i < s.length ? s[i] : throw FormatException('unexpected end', s, i);

  Object? value() {
    ws();
    switch (peek()) {
      case '{':
        final o = _JsonObj();
        i++;
        ws();
        if (peek() == '}') {
          i++;
          return o;
        }
        while (true) {
          ws();
          final k = str();
          ws();
          if (peek() != ':') throw FormatException(': expected', s, i);
          i++;
          o.entries.add((k, value()));
          ws();
          final c = peek();
          i++;
          if (c == '}') return o;
          if (c != ',') throw FormatException(', expected', s, i - 1);
        }
      case '[':
        final l = <Object?>[];
        i++;
        ws();
        if (peek() == ']') {
          i++;
          return l;
        }
        while (true) {
          l.add(value());
          ws();
          final c = peek();
          i++;
          if (c == ']') return l;
          if (c != ',') throw FormatException(', expected', s, i - 1);
        }
      case '"':
        return str();
    }
    for (final (word, v) in const [('true', true), ('false', false), ('null', null)]) {
      if (s.startsWith(word, i)) {
        i += word.length;
        return v;
      }
    }
    final m = _numRx.matchAsPrefix(s, i) ?? (throw FormatException('value expected', s, i));
    i = m.end;
    return _JsonNum(m[0]!);
  }

  final v = value();
  ws();
  if (i != s.length) throw FormatException('text after the value', s, i);
  return v;
}

/// The exact decimal value of a JSON number, in one spelling: `1`, `1.0` and
/// `1E+00` all give `1`, while `1.1` and `1.10000000000000001` stay apart
/// (they are the same double, but not the same number written down).
String _exactValue(String text) {
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$').firstMatch(text)!;
  final frac = m[3] ?? '';
  var digits = '${m[2]}$frac'.replaceFirst(RegExp('^0+'), '');
  var exp = int.parse(m[4] ?? '0') - frac.length; // value = digits * 10^exp
  if (digits.isEmpty) return '0';
  final trail = digits.length - digits.replaceFirst(RegExp(r'0+$'), '').length;
  digits = digits.substring(0, digits.length - trail);
  exp += trail;
  final sign = m[1]!;
  if (exp >= 0) return exp <= 30 ? '$sign$digits${'0' * exp}' : '$sign${digits}E$exp';
  if (-exp > digits.length + 30) return '$sign${digits}E$exp';
  final whole = digits.length + exp;
  return whole > 0 ? '$sign${digits.substring(0, whole)}.${digits.substring(whole)}' : '${sign}0.${'0' * -whole}$digits';
}

/// [v] laid out as PowerShell 7's `ConvertTo-Json` does (two-space indent,
/// `"key": value`, LF), or as `-Compress` does when [compact].
String _writeJson(Object? v, bool compact, [String indent = '']) {
  final inner = '$indent  ', nl = compact ? '' : '\n', sep = compact ? ':' : ': ';
  return switch (v) {
    _JsonNum n => _exactValue(n.text),
    String s => jsonEncode(s),
    List l when l.isEmpty => '[]',
    List l => '[$nl${[for (final e in l) '${compact ? '' : inner}${_writeJson(e, compact, inner)}'].join(',$nl')}$nl${compact ? '' : indent}]',
    _JsonObj o when o.entries.isEmpty => '{}',
    _JsonObj o =>
      '{$nl${[for (final (k, e) in o.entries) '${compact ? '' : inner}${jsonEncode(k)}$sep${_writeJson(e, compact, inner)}'].join(',$nl')}$nl${compact ? '' : indent}}',
    _ => '$v',
  };
}

/// A JSON file's bytes in one layout, so files written by Windows PowerShell
/// 5.1 and by PowerShell 7 compare by what they hold. Key order and string
/// values are kept. Numbers compare by exact decimal value: 5.1 writes a
/// whole double as `1` where 7 writes `1.0`, but any other digits still
/// differ. A file on one line stays compact. A byte order mark is kept.
/// Bytes that are not JSON come back unchanged.
List<int> jsonLayout(List<int> bytes) {
  final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
  try {
    final text = utf8.decode(bom ? bytes.sublist(3) : bytes);
    final out = _writeJson(_readJson(text), !text.trim().contains('\n'));
    return [
      if (bom) ...[0xEF, 0xBB, 0xBF],
      ...utf8.encode(out),
    ];
  } on FormatException {
    return bytes;
  }
}

/// [bytes] of the file at [path] made comparable across PowerShell versions:
/// under Windows PowerShell 5.1 a `.json` file goes through [jsonLayout].
/// Everything else, and everything under PowerShell 7, is left as it is.
List<int> forCompare(String path, List<int> bytes) => oldIsWinPs && path.toLowerCase().endsWith('.json') ? jsonLayout(bytes) : bytes;

/// Why parity cases can't run here, or null when they can.
///
/// Reading it also sets [psFlavor] to the PowerShell the old side runs under,
/// so the port is compared with the same one. Every parity file reads it
/// before any case runs.
final String? paritySkip = () {
  psFlavor = oldIsWinPs ? PsFlavor.winPs51 : PsFlavor.ps7;
  return pwshPath == null
      ? 'no PowerShell found (set SX_PWSH)'
      : oldSrcPath == null
      ? 'old app source not found (set SX_OLD_SRC)'
      : realShowPath == null
      ? 'no show folder to test with (set SX_SHOW)'
      : null;
}();

/// Per-case allowances for things that legitimately differ between two runs,
/// such as a timestamp in a backup file name.
class ParityOptions {
  const ParityOptions({this.renamePath, this.rewriteFile, this.rewriteJson, this.rewriteText});

  /// Maps a file's relative path to the name used for comparing.
  final String Function(String path)? renamePath;

  /// Rewrites a file's bytes before comparing (mask a timestamp, say). Under
  /// Windows PowerShell 5.1 a `.json` file arrives in PowerShell 7's layout.
  final List<int> Function(String path, List<int> bytes)? rewriteFile;

  /// Rewrites the decoded JSON answer before comparing.
  final Object? Function(Object? json)? rewriteJson;

  /// Rewrites the text report before comparing.
  final String Function(String text)? rewriteText;
}

/// What the old tool did.
class OldRun {
  OldRun(this.exitCode, this.stdout, this.stderr, this.error);

  final int exitCode;
  final String stdout;
  final String stderr;

  /// The message the tool threw, or null when it finished normally.
  final String? error;

  /// The one line of JSON the tool printed, decoded.
  Object? get json {
    final line = const LineSplitter().convert(stdout).lastWhere((l) => l.startsWith('{'), orElse: () => '');
    return line.isEmpty ? null : jsonDecode(line);
  }
}

String _quote(String s) => "'${s.replaceAll("'", "''")}'";

/// What the old tools see as ShowXpress's process, for [runOld]'s `sxOpenShow`.
/// A function wins over the cmdlet of the same name, so `Get-SxProcess` in
/// `show_common.ps1` finds this one.
const _fakeSxProcess = r"function global:Get-Process { [pscustomobject]@{ ProcessName = 'ShowXpress'; Id = $PID } }; ";

/// Points the old tools' `Find-Show` at [show] through a `show_path.txt` in a
/// made up `APPDATA` folder ([at], or next to the show), and returns that
/// folder.
String oldShowPathFor(String show, {String? at}) {
  final appData = at ?? p.join(p.dirname(show), 'appdata');
  File(p.join(appData, 'ShowXpress Helper', 'show_path.txt'))
    ..createSync(recursive: true)
    ..writeAsStringSync(show);
  return appData;
}

/// Runs an old tool. [args] maps parameter names to values, `true` for a switch.
///
/// With [sxOpenShow], the tool runs as on the laptop, without `-TestRoot`, on
/// that show (found through `show_path.txt`) while ShowXpress looks open, so
/// its `Test-SxRunning` refusal can be compared. `-TestRoot` skips that check.
Future<OldRun> runOld(String script, Map<String, Object> args, {String? sxOpenShow}) async {
  final call = StringBuffer('& ${_quote(p.join(oldSrcPath!, script))}');
  args.forEach((k, v) => call.write(v == true ? ' -$k' : ' -$k ${_quote('$v')}'));
  final cmd =
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ErrorActionPreference='Stop'; ${sxOpenShow == null ? '' : _fakeSxProcess}"
      "try { $call } catch { [Console]::Error.WriteLine('SXERR:' + \$_.Exception.Message); exit 3 }";
  final r = await Process.run(
    pwshPath!,
    ['-NoProfile', '-NonInteractive', '-Command', cmd],
    environment: sxOpenShow == null ? null : {'APPDATA': oldShowPathFor(sxOpenShow)},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final err = const LineSplitter().convert(r.stderr as String).where((l) => l.startsWith('SXERR:')).map((l) => l.substring(6)).join('\n');
  return OldRun(r.exitCode, r.stdout as String, r.stderr as String, r.exitCode == 0 ? null : err);
}

/// Copies a folder and everything in it. Plain Dart, so it works on Windows too.
void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}

Map<String, List<int>> _snapshot(Directory dir, ParityOptions o) {
  final files = <String, List<int>>{};
  for (final e in dir.listSync(recursive: true, followLinks: false).whereType<File>()) {
    final rel = p.relative(e.path, from: dir.path).replaceAll(r'\', '/');
    final bytes = forCompare(rel, e.readAsBytesSync());
    files[o.renamePath?.call(rel) ?? rel] = o.rewriteFile?.call(rel, bytes) ?? bytes;
  }
  return files;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// With `SX_PARITY_DUMP` set to a folder, keeps both sides of a differing file
/// there (as compared, after masks) to read in full, since the failure shows
/// only the first differing line.
void _dump(String rel, List<int> old, List<int> now) {
  final dir = _env['SX_PARITY_DUMP'];
  if (dir == null || dir.isEmpty) return;
  final base = p.join(dir, '${DateTime.now().microsecondsSinceEpoch}_${rel.replaceAll(RegExp(r'[\\/:]'), '_')}');
  File('$base.old').parent.createSync(recursive: true);
  File('$base.old').writeAsBytesSync(old);
  File('$base.new').writeAsBytesSync(now);
}

/// With `SX_PARITY_DUMP` set, copies the folder [dir] there under [label], for
/// tests that compare whole folders by hash and so can't show the bytes.
void dumpTree(String label, Directory dir) {
  final to = _env['SX_PARITY_DUMP'];
  if (to == null || to.isEmpty || !dir.existsSync()) return;
  copyDir(dir, Directory(p.join(to, label)));
}

/// A readable account of how two folders differ, or '' when they match.
String _diffFiles(Map<String, List<int>> old, Map<String, List<int>> now) {
  final out = <String>[];
  for (final f in old.keys.where((f) => !now.containsKey(f))) {
    out.add('only the old tool wrote: $f');
  }
  for (final f in now.keys.where((f) => !old.containsKey(f))) {
    out.add('only the Dart port wrote: $f');
  }
  for (final f in old.keys.where(now.containsKey)) {
    if (_sameBytes(old[f]!, now[f]!)) continue;
    _dump(f, old[f]!, now[f]!);
    final a = utf8.decode(old[f]!, allowMalformed: true).split('\n'), b = utf8.decode(now[f]!, allowMalformed: true).split('\n');
    var i = 0;
    while (i < a.length && i < b.length && a[i] == b[i]) {
      i++;
    }
    out.add(
      'differs: $f (old ${old[f]!.length} bytes, new ${now[f]!.length} bytes), first at line ${i + 1}\n'
      '    old: ${i < a.length ? jsonEncode(a[i]) : '<end of file>'}\n'
      '    new: ${i < b.length ? jsonEncode(b[i]) : '<end of file>'}',
    );
  }
  return out.join('\n');
}

/// Where two decoded JSON values first differ, or null when they match.
/// Key order is ignored, and 100 equals 100.0.
String? _diffJson(Object? a, Object? b, [String at = r'$']) {
  if (a is Map && b is Map) {
    for (final k in {...a.keys, ...b.keys}) {
      if (!a.containsKey(k)) return '$at.$k is only in the Dart answer (${jsonEncode(b[k])})';
      if (!b.containsKey(k)) return '$at.$k is only in the old answer (${jsonEncode(a[k])})';
      final d = _diffJson(a[k], b[k], '$at.$k');
      if (d != null) return d;
    }
    return null;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return '$at has ${a.length} items in the old answer and ${b.length} in the Dart answer';
    for (var i = 0; i < a.length; i++) {
      final d = _diffJson(a[i], b[i], '$at[$i]');
      if (d != null) return d;
    }
    return null;
  }
  return a == b ? null : '$at: old ${jsonEncode(a)}, Dart ${jsonEncode(b)}';
}

String _tidy(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n').map((l) => l.trimRight()).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

/// Defines one old-versus-new test.
///
/// [script] and [args] say how to run the old tool (`-TestRoot` is added).
/// [changes], when given, is written to a temp JSON file and passed as
/// `-ChangesFile` (or [changesArg]). [dart] runs the port on the same show and
/// returns what it answers: an object with `toJson()` (or a Map) for a
/// preview, or the text report for a change.
///
/// [setup] edits the show copy before each side runs, to build the situation
/// under test. The real show itself is never touched.
///
/// [sxOpen] runs both sides while ShowXpress looks open: the old tool without
/// `-TestRoot` (see [runOld]) and the port with `sxRunning` true.
void parityTest(
  String name, {
  required String script,
  Map<String, Object> args = const {},
  Object? changes,
  String changesArg = 'ChangesFile',
  required FutureOr<Object?> Function(ShowEnv env) dart,
  void Function(ShowEnv env)? setup,
  ParityOptions options = const ParityOptions(),
  bool sxOpen = false,
}) {
  test(name, skip: paritySkip, () async {
    final tmp = Directory.systemTemp.createTempSync('sx_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Both sides run in the same folder, one after the other, so answers that
    // echo the show's path match.
    final show = Directory(p.join(tmp.path, 'show'));
    void fresh() {
      if (show.existsSync()) show.deleteSync(recursive: true);
      copyDir(Directory(realShowPath!), show);
      setup?.call(ShowEnv(show.path));
    }

    fresh();
    final psArgs = {...args, if (!sxOpen) 'TestRoot': show.path};
    if (changes != null) {
      final cf = File(p.join(tmp.path, 'changes.json'))..writeAsStringSync(jsonEncode(changes));
      psArgs[changesArg] = cf.path;
    }
    final old = await runOld(script, psArgs, sxOpenShow: sxOpen ? show.path : null);
    final oldFiles = _snapshot(show, options);

    fresh();
    Object? answer;
    String? error;
    try {
      answer = await dart(ShowEnv(show.path, sxRunning: () => sxOpen));
    } on ToolError catch (e) {
      error = e.message;
    }
    final newFiles = _snapshot(show, options);

    if (old.error != null || error != null) {
      expect(error, old.error, reason: 'error message (old stderr: ${old.stderr.trim()})');
    } else if (answer is String) {
      final fix = options.rewriteText ?? (t) => t;
      expect(fix(_tidy(answer)), fix(_tidy(old.stdout)), reason: 'text report');
    } else {
      final fix = options.rewriteJson ?? (j) => j;
      // Through JSON text and back, so both sides are plain maps and lists.
      final mine = fix(jsonDecode(jsonEncode(answer)));
      final diff = _diffJson(fix(old.json), mine);
      if (diff != null) fail('JSON answer differs. $diff');
    }
    final diff = _diffFiles(oldFiles, newFiles);
    if (diff.isNotEmpty) fail('Files differ after the run.\n$diff');
  });
}
