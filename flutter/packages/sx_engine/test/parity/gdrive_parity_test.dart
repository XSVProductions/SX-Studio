/// Old versus new for Google Drive sync and import.
///
/// With `-TestRoot`, `gdrive.ps1` puts the Google Drive copy and the import
/// backups two folders above the show (`GoogleDriveTest/<show>` and
/// `HelperBackups`), so each case lays out its own folder:
///
/// ```
/// w/LS/<show>                  the show
/// w/GoogleDriveTest/<show>     "Google Drive"
/// w/HelperBackups              import backups
/// ```
///
/// and compares every file under `w`. The old tool also needs
/// `$env:ProgramFiles`, which Linux doesn't set (that is why a bare
/// `-Action Preview` failed here).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// The show's own name, so paths look like the real thing.
final _name = realShowPath == null ? 'show' : p.basename(realShowPath!);

class _Layout {
  _Layout(this.w);

  final String w;
  String get show => p.join(w, 'LS', _name);
  String get drive => p.join(w, 'GoogleDriveTest', _name);
  String get backups => p.join(w, 'HelperBackups');

  /// What the old tool sees in test mode.
  DrivePlaces get places {
    var override = '';
    final sf = File(p.join(show, 'settings.json'));
    if (sf.existsSync()) override = '${(jsonDecode(sf.readAsStringSync()) as Map)['driveFolder'] ?? ''}';
    return DrivePlaces(dest: drive, backups: backups, override: override);
  }
}

/// Copies a folder and keeps each file's modified time, like Google Drive's
/// own copy would.
void copyTree(String from, String to) {
  for (final e in Directory(from).listSync(recursive: true, followLinks: false)) {
    final t = p.join(to, p.relative(e.path, from: from));
    if (e is Directory) Directory(t).createSync(recursive: true);
    if (e is File) {
      File(t).parent.createSync(recursive: true);
      e.copySync(t);
      File(t).setLastModifiedSync(e.lastModifiedSync());
    }
  }
}

/// Today's backup names carry the time of the import. Older ones (made by a
/// case's setup) are left as they are.
final _stamp = () {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return RegExp('before import ${t.year}-${two(t.month)}-${two(t.day)} \\d{6}');
}();

/// JSON state files: keys in any order (PowerShell hashtables have none) and
/// the time they were written masked.
List<int> _maskState(String path, List<int> bytes) {
  final base = p.basename(path);
  if (base != 'gdrive_sync.json' && base != 'gdrive_import.json') return bytes;
  final j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  for (final k in ['synced', 'imported']) {
    if (j.containsKey(k)) j[k] = '<time>';
  }
  if (j['backup'] is String) j['backup'] = (j['backup'] as String).replaceAll(_stamp, 'before import <time>');
  return utf8.encode(jsonEncode({for (final k in j.keys.toList()..sort()) k: j[k]}));
}

/// Every file under [dir] except the new sync record, which only the port writes.
Map<String, List<int>> _snapshot(String dir) => {
  for (final f in Directory(dir).listSync(recursive: true, followLinks: false).whereType<File>())
    if (p.basename(f.path) != syncFilesFile) p.relative(f.path, from: dir).replaceAll(_stamp, 'before import <time>'): _maskState(f.path, f.readAsBytesSync()),
};

/// PowerShell 7 reads `"2026-11-23T06:20:16"` from JSON as a date and prints
/// it as `11/23/2026 06:20:16`. Windows PowerShell 5.1 keeps the text. Both
/// are made the ISO form here.
String _isoDate(Object? v) {
  final m = RegExp(r'^(\d\d)/(\d\d)/(\d{4}) (\d\d:\d\d:\d\d)$').firstMatch('$v');
  return m == null ? '$v' : '${m[3]}-${m[1]}-${m[2]}T${m[4]}';
}

Future<OldRun> _runOld(String action, String show) async {
  final r = await Process.run(
    pwshPath!,
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ErrorActionPreference='Stop'; "
          "try { & '${p.join(oldSrcPath!, 'gdrive.ps1')}' -Action $action -TestRoot '${show.replaceAll("'", "''")}' } "
          "catch { [Console]::Error.WriteLine('SXERR:' + \$_.Exception.Message); exit 3 }",
    ],
    environment: {'ProgramFiles': '/nonexistent'},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final err = const LineSplitter().convert(r.stderr as String).where((l) => l.startsWith('SXERR:')).map((l) => l.substring(6)).join('\n');
  return OldRun(r.exitCode, r.stdout as String, r.stderr as String, r.exitCode == 0 ? null : err);
}

String _tidy(String t) => t.replaceAll('\r\n', '\n').trimRight().replaceAll(_stamp, 'before import <time>');

void _case(String name, String action, {void Function(_Layout l)? setup}) {
  test(name, skip: paritySkip, () async {
    final tmp = Directory.systemTemp.createTempSync('sx_gd_parity_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final l = _Layout(p.join(tmp.path, 'w'));
    void fresh() {
      if (Directory(l.w).existsSync()) Directory(l.w).deleteSync(recursive: true);
      copyTree(realShowPath!, l.show);
      setup?.call(l);
    }

    fresh();
    final old = await _runOld(action, l.show);
    final oldFiles = _snapshot(l.w);

    fresh();
    Object? answer;
    String? error;
    final env = ShowEnv(l.show);
    try {
      answer = switch (action) {
        'Preview' => drivePreview(env, l.places),
        'Sync' => driveSync(env, l.places),
        _ => driveImport(env, l.places),
      };
    } on ToolError catch (e) {
      error = e.message;
    }
    final newFiles = _snapshot(l.w);

    if (old.error != null || error != null) {
      expect(error, old.error, reason: 'error message (old stderr: ${old.stderr.trim()})');
    } else if (answer is String) {
      expect(_tidy(answer), _tidy(old.stdout), reason: 'text report');
    } else {
      Map<String, Object?> fix(Object? j) {
        final m = (jsonDecode(jsonEncode(j)) as Map).cast<String, Object?>();
        m['last'] = _isoDate(m['last']);
        m['lastImport'] = _isoDate(m['lastImport']);
        // the Drive copy's time: each side made its own copy a moment apart
        if ('${m['srcTime']}'.isNotEmpty) m['srcTime'] = '<time>';
        return m;
      }

      expect(fix(answer), fix(old.json), reason: 'JSON answer');
    }
    expect(newFiles.keys.toSet(), oldFiles.keys.toSet(), reason: 'which files exist');
    for (final f in oldFiles.keys) {
      expect(newFiles[f], oldFiles[f], reason: 'bytes of $f');
    }
  });
}

/// Puts a copy of the show on "Google Drive", with the same file times.
void _onDrive(_Layout l) => copyTree(l.show, l.drive);

void main() {
  group('preview', () {
    _case('nothing on Google Drive yet', 'Preview');
    _case('a show on Google Drive', 'Preview', setup: _onDrive);
    _case(
      'Google Drive folder set in settings',
      'Preview',
      setup: (l) => File(p.join(l.show, 'settings.json')).writeAsStringSync('{"driveFolder":"/somewhere/My Drive"}'),
    );
  });

  group('sync', () {
    _case('first sync copies everything', 'Sync');
    _case('nothing changed', 'Sync', setup: _onDrive);
    _case(
      'changed here, newer on Google Drive',
      'Sync',
      setup: (l) {
        _onDrive(l);
        final live = File(p.join(l.show, 'Live', 'live.ini'));
        live
          ..writeAsStringSync('${live.readAsStringSync()}\r\n; changed here\r\n')
          ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
        final fx = File(p.join(l.drive, 'fixtures.ini'));
        fx
          ..writeAsStringSync('changed on the other laptop')
          ..setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
        File(p.join(l.show, 'scenes', 'NEW ONE.scex')).writeAsStringSync('<Scene/>');
      },
    );
  });

  group('import', () {
    _case('nothing on Google Drive', 'Import');
    _case(
      'replaces the show and keeps a backup',
      'Import',
      setup: (l) {
        _onDrive(l);
        File(p.join(l.show, 'only here.txt')).writeAsStringSync('goes');
        File(p.join(l.drive, 'fixtures.ini')).writeAsStringSync('from the other laptop');
        for (final junk in ['desktop.ini', '.DS_Store', r'~$notes.docx', 'x.tmp', p.join('scenes', '._A.scex')]) {
          File(p.join(l.drive, junk)).writeAsStringSync('junk');
        }
        File(p.join(l.drive, 'gdrive_sync.json')).writeAsStringSync('{"synced":"2001-01-01T00:00:00","target":"elsewhere"}');
        File(p.join(l.drive, 'thelightingcontroller.ini')).writeAsStringSync('the other laptop window');
      },
    );
    _case(
      'no window layout here takes the one on Google Drive',
      'Import',
      setup: (l) {
        _onDrive(l);
        File(p.join(l.show, 'thelightingcontroller.ini')).deleteSync();
        File(p.join(l.drive, 'thelightingcontroller.ini')).writeAsStringSync('the other laptop window');
      },
    );
    _case(
      'no show here yet',
      'Import',
      setup: (l) {
        _onDrive(l);
        Directory(l.show).deleteSync(recursive: true);
      },
    );
    _case(
      'keeps the newest 3 backups',
      'Import',
      setup: (l) {
        _onDrive(l);
        for (final d in ['2020-01-01 000000', '2020-01-03 000000', '2020-01-02 000000', '2019-12-31 235959']) {
          File(p.join(l.backups, '$_name before import $d', 'live.ini')).createSync(recursive: true);
        }
        File(p.join(l.backups, 'something else', 'keep.txt')).createSync(recursive: true);
      },
    );
  });
}
