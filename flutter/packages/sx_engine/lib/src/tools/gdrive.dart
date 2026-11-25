import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../player/win32.dart' show kernel32, winAlloc, winFree, toWide, fromWide;
import '../show/show_env.dart';
import '../show/text_files.dart';
import '../ps_compat.dart';

// SYNC TO / IMPORT FROM GOOGLE DRIVE: the show's copy in Google Drive > AWAAZ >
// Lighting > <show folder name>, in the Google Drive app's own folder on this
// computer, so Google Drive uploads and downloads it by itself.
//
//   Preview  where things are and when they last moved
//   Sync     one way, never deletes: new and changed files are copied up.
//            A file that is newer on Google Drive is left alone.
//   Import   the Google Drive copy replaces the show here. Everything is read
//            into a temp folder first, so a failed read changes nothing. The
//            old show is kept as a backup (newest 3). This computer's window
//            layout, error log and sync notes stay.
//
// Port of `gdrive.ps1`.

/// The sync record of the last sync, in the show folder. Old app.
const syncStateFile = 'gdrive_sync.json';

/// The import record, in the show folder. Old app.
const importStateFile = 'gdrive_import.json';

/// Files that belong to this computer. Import keeps them; sync never sends
/// the first two.
const _keepLocal = [syncStateFile, importStateFile, 'thelightingcontroller.ini', 'TheLightingController_Err.log'];

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

String get _home => Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';

/// Finds Google Drive's My Drive folder. A folder set in Settings
/// (`driveFolder`) wins while it exists. Port of `Find-MyDrive`.
///
/// Windows: the first drive, in letter order, that is G or whose label says
/// Google, with a `My Drive` folder on it (`Get-PSDrive`, see [pickMyDrive]).
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
      final dirs = [
        for (final d in cs.listSync().whereType<Directory>())
          if (psLike(p.basename(d.path), 'GoogleDrive-*')) d.path,
      ];
      for (final d in psSorted<String>(dirs, [(String x) => p.basename(x)])) {
        final my = p.join(d, 'My Drive');
        if (FileSystemEntity.typeSync(my) != FileSystemEntityType.notFound) return my;
      }
      return '';
    }
    if (Platform.isWindows) {
      final my = pickMyDrive(_windowsDrives(), (path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound);
      if (my.isNotEmpty) return my;
    }
    for (final my in [p.join(_home, 'Google Drive', 'My Drive'), p.join(_home, 'My Drive')]) {
      if (FileSystemEntity.typeSync(my) != FileSystemEntityType.notFound) return my;
    }
    return '';
  }

  return DriveFound(my: find(), override: override, appFound: appFound);
}

/// The Windows half of `Find-MyDrive`: the first of [drives] (letter and
/// volume label, in letter order) that is G or whose label says Google
/// (case ignored, as `-match`), with `My Drive` on it. '' when none.
String pickMyDrive(Iterable<({String letter, String label})> drives, bool Function(String path) exists) {
  for (final d in drives) {
    final my = '${d.letter}:\\My Drive';
    if ((d.label.toLowerCase().contains('google') || psEq(d.letter, 'G')) && exists(my)) return my;
  }
  return '';
}

final _getLogicalDrives = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLogicalDrives');
final _getVolumeInformation = kernel32
    .lookupFunction<
      Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint16>, Uint32),
      int Function(Pointer<Uint16>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint16>, int)
    >('GetVolumeInformationW');

/// This computer's drive letters and their volume labels, A to Z, as
/// `Get-PSDrive -PSProvider FileSystem` lists them (`Name`, `Description`).
/// A drive that can't be read (an empty card reader) has no label.
List<({String letter, String label})> _windowsDrives() {
  final mask = _getLogicalDrives();
  final out = <({String letter, String label})>[];
  for (var i = 0; i < 26; i++) {
    if (mask & (1 << i) == 0) continue;
    final letter = String.fromCharCode(0x41 + i);
    final root = toWide('$letter:\\');
    final name = winAlloc<Uint16>(261 * 2);
    try {
      final ok = _getVolumeInformation(root, name, 261, nullptr, nullptr, nullptr, nullptr, 0) != 0;
      out.add((letter: letter, label: ok ? fromWide(name) ?? '' : ''));
    } finally {
      winFree(root);
      winFree(name);
    }
  }
  return out;
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
    srcTime: sf ? sortableTime(File(srcLive).lastModifiedSync()) : '',
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
  for (final (rel, f) in _files(env.root)) {
    if (psEq(rel, syncStateFile) || psEq(rel, importStateFile)) continue;
    final t = File(p.join(dest, rel));
    final fs = f.statSync();
    if (t.existsSync()) {
      final ts = t.statSync();
      final diff = ts.modified.difference(fs.modified).inMicroseconds;
      if (ts.size == fs.size && diff.abs() <= 2000000) {
        same++;
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
    } on FileSystemException {
      failed.add(rel);
    }
  }
  _writeState(env.path(syncStateFile), {'synced': sortableTime(env.now()), 'target': dest});
  return [
    '  Google Drive folder: $dest',
    '  CHANGED  $copied file(s) copied, $same already up to date',
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
  _writeState(env.path(importStateFile), {'imported': sortableTime(t), 'from': dest, 'backup': bName});
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
