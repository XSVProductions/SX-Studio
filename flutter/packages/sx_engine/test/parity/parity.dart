/// Old-versus-new checks. Each case runs the old PowerShell tool and its Dart
/// port on the same copy of a show, then compares what they answered and
/// every file they left behind, byte for byte.
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
final String? oldSrcPath = _firstExisting([_env['SX_OLD_SRC'], _above(p.join('repo', 'src'), dir: true)], dir: true);
final String? realShowPath = _firstExisting([_env['SX_SHOW'], _above(p.join('real-show', 'Awaaz Lightshow'), dir: true)], dir: true);

/// Why parity cases can't run here, or null when they can.
final String? paritySkip = pwshPath == null
    ? 'no PowerShell found (set SX_PWSH)'
    : oldSrcPath == null
    ? 'old app source not found (set SX_OLD_SRC)'
    : realShowPath == null
    ? 'no show folder to test with (set SX_SHOW)'
    : null;

/// Per-case allowances for things that legitimately differ between two runs,
/// such as a timestamp in a backup file name.
class ParityOptions {
  const ParityOptions({this.renamePath, this.rewriteFile, this.rewriteJson, this.rewriteText});

  /// Maps a file's relative path to the name used for comparing.
  final String Function(String path)? renamePath;

  /// Rewrites a file's bytes before comparing (mask a timestamp, say).
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

/// Runs an old tool. [args] maps parameter names to values, `true` for a switch.
Future<OldRun> runOld(String script, Map<String, Object> args) async {
  final call = StringBuffer('& ${_quote(p.join(oldSrcPath!, script))}');
  args.forEach((k, v) => call.write(v == true ? ' -$k' : ' -$k ${_quote('$v')}'));
  final cmd =
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ErrorActionPreference='Stop'; "
      "try { $call } catch { [Console]::Error.WriteLine('SXERR:' + \$_.Exception.Message); exit 3 }";
  final r = await Process.run(pwshPath!, ['-NoProfile', '-NonInteractive', '-Command', cmd], stdoutEncoding: utf8, stderrEncoding: utf8);
  final err = const LineSplitter().convert(r.stderr as String).where((l) => l.startsWith('SXERR:')).map((l) => l.substring(6)).join('\n');
  return OldRun(r.exitCode, r.stdout as String, r.stderr as String, r.exitCode == 0 ? null : err);
}

void _copyDir(Directory from, Directory to) {
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
    final bytes = e.readAsBytesSync();
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
void parityTest(
  String name, {
  required String script,
  Map<String, Object> args = const {},
  Object? changes,
  String changesArg = 'ChangesFile',
  required FutureOr<Object?> Function(ShowEnv env) dart,
  void Function(ShowEnv env)? setup,
  ParityOptions options = const ParityOptions(),
}) {
  test(name, skip: paritySkip, () async {
    final tmp = Directory.systemTemp.createTempSync('sx_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Both sides run in the same folder, one after the other, so answers that
    // echo the show's path match.
    final show = Directory(p.join(tmp.path, 'show'));
    void fresh() {
      if (show.existsSync()) show.deleteSync(recursive: true);
      _copyDir(Directory(realShowPath!), show);
      setup?.call(ShowEnv(show.path));
    }

    fresh();
    final psArgs = {...args, 'TestRoot': show.path};
    if (changes != null) {
      final cf = File(p.join(tmp.path, 'changes.json'))..writeAsStringSync(jsonEncode(changes));
      psArgs[changesArg] = cf.path;
    }
    final old = await runOld(script, psArgs);
    final oldFiles = _snapshot(show, options);

    fresh();
    Object? answer;
    String? error;
    try {
      answer = await dart(ShowEnv(show.path));
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
