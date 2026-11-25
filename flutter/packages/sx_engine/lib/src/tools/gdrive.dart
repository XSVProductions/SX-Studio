import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../show/show_env.dart';
import '../show/text_files.dart';

// SYNC TO / IMPORT FROM GOOGLE DRIVE: the show's copy in Google Drive > AWAAZ >
// Lighting > <show folder name>, in the Google Drive app's own folder on this
// computer, so Google Drive uploads and downloads it by itself.
//
//   Preview  where things are and when they last moved
//   Sync     new and changed files are copied up. A file that is newer on
//            Google Drive is left alone. A file this computer's sync put on
//            Google Drive, and that has since left the show, is removed there,
//            unless Google Drive's copy changed since (see `_ManifestEntry`).
//   Import   the Google Drive copy replaces the show here. Everything is read
//            into a temp folder first, so a failed read changes nothing. The
//            old show is kept as a backup (newest 3). This computer's window
//            layout, error log and sync notes stay.
//
// Port of `gdrive.ps1`. The removal on sync is new: the old sync never
// removed anything, so a file deleted from the show lived on in Google Drive
// and the next import brought it back.

/// The sync record of the last sync, in the show folder. Old app.
const syncStateFile = 'gdrive_sync.json';

/// The import record, in the show folder. Old app.
const importStateFile = 'gdrive_import.json';

/// What this computer's last sync left on Google Drive. New in the port.
const syncFilesFile = 'gdrive_sync_files.json';

/// Files that belong to this computer. Import keeps them; sync never sends
/// the first three.
const _keepLocal = [syncStateFile, importStateFile, syncFilesFile, 'thelightingcontroller.ini', 'TheLightingController_Err.log'];

final _junk = RegExp(r'(^|[\\/])(desktop\.ini|\.DS_Store|Icon\r|~\$[^\\/]*|\._[^\\/]*|[^\\/]*\.tmp)$', caseSensitive: false);

/// Where sync and import read and write.
class DrivePlaces {
  const DrivePlaces({required this.dest, required this.backups, this.my = '', this.override = '', this.appFound = false});

  /// The show's folder on Google Drive, or '' when Google Drive wasn't found.
  final String dest;

  /// Where import keeps the shows it replaced.
  final String backups;

  /// Google Drive's My Drive folder in use, or ''.
  final String my;

  /// The My Drive folder set by hand in Settings, or ''.
  final String override;

  /// Google Drive for desktop is installed.
  final bool appFound;

  /// The signed-in account. The Mac folder is `GoogleDrive-<email>`, Windows
  /// doesn't show it.
  String get account => RegExp(r'GoogleDrive-([^\\/]+)', caseSensitive: false).firstMatch(my)?.group(1) ?? '';
}

/// Google Drive on this computer, before the show is known.
class DriveFound {
  const DriveFound({required this.my, required this.override, required this.appFound});

  final String my;
  final String override;
  final bool appFound;
}

/// `yyyy-MM-ddTHH:mm:ss`, PowerShell's `ToString('s')`.
String _sortable(DateTime t) => t.toIso8601String().substring(0, 19);

String get _home => Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';

/// Finds Google Drive's My Drive folder. A folder set in Settings
/// (`driveFolder`) wins while it exists. Port of `Find-MyDrive`.
///
/// Windows: the old tool asked Windows for the drive whose label says
/// Google. Without that, this takes the first drive letter (G first) with a
/// `My Drive` folder on it.
DriveFound findDrive(String settingsDir) {
  var override = '';
  final setF = File(p.join(settingsDir, 'settings.json'));
  if (setF.existsSync()) {
    try {
      final j = jsonDecode(readText(setF.path));
      if (j is Map && j['driveFolder'] != null) override = '${j['driveFolder']}';
    } on FormatException {
      override = '';
    }
  }
  final appFound = Platform.isMacOS
      ? Directory('/Applications/Google Drive.app').existsSync()
      : Platform.isWindows &&
            File(p.join(Platform.environment['ProgramFiles'] ?? r'C:\Program Files', 'Google', 'Drive File Stream', 'launch.bat')).existsSync();
  String find() {
    if (override.isNotEmpty && Directory(override).existsSync()) return override;
    if (Platform.isMacOS) {
      final cs = Directory(p.join(_home, 'Library', 'CloudStorage'));
      if (!cs.existsSync()) return '';
      for (final d in cs.listSync().whereType<Directory>()) {
        final my = p.join(d.path, 'My Drive');
        if (p.basename(d.path).startsWith('GoogleDrive-') && Directory(my).existsSync()) return my;
      }
      return '';
    }
    if (Platform.isWindows) {
      for (final l in 'GDEFHIJKLMNOPQRSTUVWXYZ'.split('')) {
        final my = '$l:\\My Drive';
        if (Directory(my).existsSync()) return my;
      }
    }
    for (final my in [p.join(_home, 'Google Drive', 'My Drive'), p.join(_home, 'My Drive')]) {
      if (Directory(my).existsSync()) return my;
    }
    return '';
  }

  return DriveFound(my: find(), override: override, appFound: appFound);
}

/// The show folder when this computer has no show yet (a new laptop): the
/// show on Google Drive goes into the usual ShowXpress folder. Throws the
/// original error when Google Drive has no show either.
String showFromDrive(String my, ToolError noShow) {
  final lib = my.isEmpty ? '' : p.join(my, 'AWAAZ', 'Lighting');
  final cand = lib.isEmpty || !Directory(lib).existsSync()
      ? <Directory>[]
      : [
          for (final d in Directory(lib).listSync().whereType<Directory>())
            if (File(p.join(d.path, 'Live', 'live.ini')).existsSync()) d,
        ];
  final pick = cand.where((d) => p.basename(d.path).toLowerCase() == 'awaaz lightshow').firstOrNull ?? (cand.length == 1 ? cand.single : null);
  if (pick == null) throw noShow;
  return p.join(_home, 'TheLightingController', 'LightShows', p.basename(pick.path));
}

/// The places for a show on this computer's real Google Drive.
DrivePlaces drivePlaces(DriveFound d, String root, String settingsDir) => DrivePlaces(
  dest: d.my.isEmpty ? '' : p.join(d.my, 'AWAAZ', 'Lighting', p.basename(root)),
  backups: p.join(settingsDir, 'backups'),
  my: d.my,
  override: d.override,
  appFound: d.appFound,
);

String _readKey(String path, String key) {
  if (!File(path).existsSync()) return '';
  final j = jsonDecode(readText(path));
  return j is Map && j[key] != null ? '${j[key]}' : '';
}

/// A small JSON state file, written the way PowerShell 7's `ConvertTo-Json`
/// lays it out.
void _writeState(String path, Json value) => writeTextSafely(path, const JsonEncoder.withIndent('  ').convert(value), bom: false);

/// What the Google Drive card shows. Writes nothing.
DriveInfo drivePreview(ShowEnv env, DrivePlaces at) {
  final srcLive = at.dest.isEmpty ? '' : p.join(at.dest, 'Live', 'live.ini');
  final sf = srcLive.isNotEmpty && File(srcLive).existsSync();
  return DriveInfo(
    show: env.root,
    here: env.file(p.join('Live', 'live.ini')).existsSync(),
    found: at.dest.isNotEmpty,
    target: at.dest,
    last: _readKey(env.path(syncStateFile), 'synced'),
    srcFound: sf,
    srcTime: sf ? _sortable(File(srcLive).lastModifiedSync()) : '',
    lastImport: _readKey(env.path(importStateFile), 'imported'),
    my: at.my,
    override: at.override,
    account: at.account,
    appFound: at.appFound,
  );
}

/// Every file under [dir], by path relative to it.
Iterable<(String, File)> _files(String dir) sync* {
  for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
    if (e is File) yield (p.relative(e.path, from: dir), e);
  }
}

/// Copies a file and its modified time, like `Copy-Item`.
void _copy(File from, String to) {
  Directory(p.dirname(to)).createSync(recursive: true);
  from.copySync(to);
  File(to).setLastModifiedSync(from.lastModifiedSync());
}

/// One file this computer's sync left on Google Drive: its size and modified
/// time there. Sync removes a file from Google Drive only when it is in here,
/// has left the show, and Google Drive's copy still has this size and time.
/// A copy someone changed since is somebody else's and stays.
typedef _ManifestEntry = ({int size, int time});

Map<String, _ManifestEntry> _readManifest(String path, String dest) {
  if (!File(path).existsSync()) return {};
  try {
    final j = jsonDecode(readText(path));
    // a record for another Google Drive folder says nothing about this one
    if (j is! Map || j['target'] != dest || j['files'] is! Map) return {};
    return {
      for (final e in (j['files'] as Map).entries)
        if (e.value case {'size': final int size, 'time': final int time}) '${e.key}': (size: size, time: time),
    };
  } on FormatException {
    return {};
  }
}

bool _matches(FileStat s, _ManifestEntry m) => s.size == m.size && (s.modified.millisecondsSinceEpoch - m.time).abs() <= 2000;

/// Copies the show to Google Drive. Returns the report text.
String driveSync(ShowEnv env, DrivePlaces at) {
  if (at.dest.isEmpty) throw ToolError('Google Drive not found on this computer - is the Google Drive app installed and signed in? NOTHING was copied.');
  if (env.sxRunning()) {
    throw ToolError('ShowXpress is OPEN - NOTHING was copied. Close ShowXpress (save first) so the newest show is copied, then try again.');
  }
  final dest = at.dest;
  Directory(dest).createSync(recursive: true);
  var copied = 0, newer = 0, same = 0;
  final failed = <String>[];
  final left = <String, _ManifestEntry>{};
  final here = <String>{};
  for (final (rel, f) in _files(env.root)) {
    if (rel == syncStateFile || rel == importStateFile || rel == syncFilesFile) continue;
    final key = rel.replaceAll(r'\', '/');
    here.add(key);
    final t = File(p.join(dest, rel));
    final fs = f.statSync();
    if (t.existsSync()) {
      final ts = t.statSync();
      final diff = ts.modified.difference(fs.modified).inMicroseconds;
      if (ts.size == fs.size && diff.abs() <= 2000000) {
        same++;
        left[key] = (size: ts.size, time: ts.modified.millisecondsSinceEpoch);
        continue;
      }
      if (diff > 2000000) {
        newer++;
        continue;
      }
    }
    try {
      _copy(f, t.path);
      copied++;
      final ts = t.statSync();
      left[key] = (size: ts.size, time: ts.modified.millisecondsSinceEpoch);
    } on FileSystemException {
      failed.add(rel);
    }
  }
  // Files the last sync left on Google Drive that are no longer in the show.
  var removed = 0, changedThere = 0;
  final manifestPath = env.path(syncFilesFile);
  for (final e in _readManifest(manifestPath, dest).entries) {
    if (here.contains(e.key)) continue;
    final t = File(p.join(dest, e.key));
    if (!t.existsSync()) continue;
    if (!_matches(t.statSync(), e.value)) {
      changedThere++;
      continue;
    }
    try {
      t.deleteSync();
      removed++;
    } on FileSystemException {
      // still there: keep it on the list, so the next sync tries again
      left[e.key] = e.value;
      failed.add(e.key);
    }
  }
  _writeState(manifestPath, {
    'target': dest,
    'files': {
      for (final e in left.entries) e.key: {'size': e.value.size, 'time': e.value.time},
    },
  });
  _writeState(env.path(syncStateFile), {'synced': _sortable(env.now()), 'target': dest});
  return [
    '  Google Drive folder: $dest',
    '  CHANGED  $copied file(s) copied, $same already up to date',
    if (removed > 0) '  REMOVED  $removed file(s) from Google Drive that are no longer in the show',
    if (changedThere > 0) '  $changedThere file(s) no longer in the show were changed on Google Drive since the last sync - left alone',
    if (newer > 0) '  $newer file(s) are newer on Google Drive - left alone',
    if (failed.isNotEmpty) '  WARNING: could not copy ${failed.length}: ${failed.take(5).join(', ')}',
  ].join('\n');
}

/// Replaces the show with the Google Drive copy. Returns the report text.
String driveImport(ShowEnv env, DrivePlaces at) {
  if (at.dest.isEmpty) throw ToolError('Google Drive not found on this computer - is the Google Drive app installed and signed in? NOTHING was changed.');
  final dest = at.dest, root = env.root, showName = p.basename(root);
  if (!File(p.join(dest, 'Live', 'live.ini')).existsSync()) {
    throw ToolError("There's no show on Google Drive at $dest - sync it from the other computer first. NOTHING was changed.");
  }
  if (env.sxRunning()) {
    throw ToolError('ShowXpress is OPEN - NOTHING was changed. Close ShowXpress first (it writes its old show back when it closes), then import.');
  }
  final bk = at.backups;
  Directory(bk).createSync(recursive: true);
  // 1) read everything from Google Drive into a temp folder next to the backups
  final stage = Directory(p.join(bk, '_importing'));
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  final srcFull = Directory(dest).resolveSymbolicLinksSync();
  var n = 0;
  final failed = <String>[];
  for (final (rel, f) in _files(srcFull)) {
    if (_junk.hasMatch(rel) || _keepLocal.any((k) => k.toLowerCase() == rel.toLowerCase())) continue;
    try {
      _copy(f, p.join(stage.path, rel));
      n++;
    } on FileSystemException {
      failed.add(rel);
    }
  }
  if (failed.isNotEmpty || !File(p.join(stage.path, 'Live', 'live.ini')).existsSync()) {
    stage.deleteSync(recursive: true);
    throw ToolError(
      "Couldn't read ${failed.length} file(s) from Google Drive (${failed.take(3).join(', ')}) - is this computer online and has Google Drive finished syncing? NOTHING was changed.",
    );
  }
  // 2) this computer's own files go along into the new copy (window layout
  //    only from Google Drive if this computer has none)
  final had = Directory(root).existsSync();
  if (had) {
    for (final k in _keepLocal) {
      final lf = File(p.join(root, k));
      if (lf.existsSync()) _copy(lf, p.join(stage.path, k));
    }
  }
  final dIni = File(p.join(srcFull, 'thelightingcontroller.ini'));
  if (!File(p.join(stage.path, 'thelightingcontroller.ini')).existsSync() && dIni.existsSync()) _copy(dIni, p.join(stage.path, 'thelightingcontroller.ini'));
  // 3) swap: old show to the backups, new copy into the show folder (the old
  //    one is put back if that fails)
  var bName = '';
  final t = env.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (had) {
    bName = '$showName before import ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      Directory(root).renameSync(p.join(bk, bName));
    } on FileSystemException catch (e) {
      stage.deleteSync(recursive: true);
      throw ToolError('The show folder is in use (is a file in it open?) - NOTHING was changed. ${e.message}');
    }
  } else {
    Directory(p.dirname(root)).createSync(recursive: true);
  }
  try {
    stage.renameSync(root);
  } on FileSystemException catch (e) {
    if (had) Directory(p.join(bk, bName)).renameSync(root);
    throw ToolError("Couldn't put the new show in place - the old show was put back, NOTHING was changed. ${e.message}");
  }
  _writeState(env.path(importStateFile), {'imported': _sortable(t), 'from': dest, 'backup': bName});
  // keep the newest 3 backups
  final prefix = '$showName before import '.toLowerCase();
  final olds = [
    for (final d in Directory(bk).listSync().whereType<Directory>())
      if (p.basename(d.path).toLowerCase().startsWith(prefix)) d,
  ]..sort((a, b) => p.basename(b.path).toLowerCase().compareTo(p.basename(a.path).toLowerCase()));
  for (final d in olds.skip(3)) {
    try {
      d.deleteSync(recursive: true);
    } on FileSystemException {
      // left for next time, like the old tool
    }
  }
  return [
    '  Google Drive folder: $dest',
    '  CHANGED  show replaced with the Google Drive copy ($n files) in $root',
    if (bName.isNotEmpty) '  old show kept as a backup: ${p.join(bk, bName)}',
  ].join('\n');
}
