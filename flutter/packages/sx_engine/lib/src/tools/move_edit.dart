import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/find_show.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'move_edit/gpj.dart';
import 'move_edit/ps_json.dart';

// MOVEMENT EDITOR: reads and changes ShowXpress Generator movements
// (Editor/Generator/projects/*.gpj).
//
// ShowXpress must still open every file written, and anything the editor
// doesn't understand is passed through untouched (see `move_edit/gpj.dart`).
// Before anything is written the result is read back and must give exactly the
// movement that was asked for. Every save keeps the previous file as a backup,
// outside the show folder so Google Drive never gets them.
//
// Owned by other tabs, read only here: ReversePan / ReverseTilt (Reverse
// heads), and the heads' aim and size in the movements Aim Movers looks after
// (df_aim_state.json = Dance Floor, room_aim_state.json = Room). A shape saved
// here goes into Aim Movers' shape record, so its next Apply keeps it as drawn.
//
// Port of `move_edit.ps1`.

const _maxBackups = 20;

/// Where backups go by default: the app's settings folder, `move_backups`.
/// The old tool in test mode kept them next to the show folder instead; tests
/// pass that folder.
String get defaultMoveBackups => p.join(settingsDir, 'move_backups');

String _gdir(ShowEnv env) => '${env.root}/Editor/Generator/projects';

void _requireGdir(ShowEnv env) {
  if (!Directory(_gdir(env)).existsSync()) throw ToolError('The show has no Generator movements folder (${_gdir(env)}). NOTHING was changed.');
}

final _moveName = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.gpj\n?$', caseSensitive: false);

/// The name check the old server and tool both make (`$moveRx`).
bool isMoveName(String name) => _moveName.hasMatch(name);

/// Port of `Get-MoveFile`.
String _moveFile(ShowEnv env, String name) {
  if (!_moveName.hasMatch(name) || name.startsWith('.')) throw ToolError("Not a movement name: '$name'. NOTHING was changed.");
  final path = p.join(_gdir(env), name);
  if (!File(path).existsSync()) throw ToolError("Movement '$name' not found in the show. NOTHING was changed.");
  return path;
}

/// File name without `.gpj`. Port of `Get-Title`.
String _title(String f) => f.replaceFirst(RegExp(r'\.gpj$', caseSensitive: false), '');

/// Every `.gpj` in the projects folder, by name. Hidden files are left out,
/// like `Get-ChildItem` does.
List<File> _files(ShowEnv env) => psSorted<File>(
  Directory(_gdir(env)).listSync().whereType<File>().where((f) {
    final n = p.basename(f.path);
    return n.toLowerCase().endsWith('.gpj') && !n.startsWith('.');
  }),
  [(f) => p.basename(f.path)],
);

String _two(int v) => v.toString().padLeft(2, '0');

// ---------------------------------------------------------------- what other tabs own

/// Movement file (lowercase) to 'floor' or 'room', for the movements Aim Movers rewrites. Port of `Get-AimOwner`.
Map<String, String> _aimOwner(ShowEnv env) {
  final r = <String, String>{};
  for (final (f, own) in const [('df_aim_state.json', 'floor'), ('room_aim_state.json', 'room')]) {
    final file = env.file(f);
    if (!file.existsSync()) continue;
    final Object? j;
    try {
      j = jsonDecode(readText(file.path));
    } on FormatException {
      continue;
    }
    final files = prop(j, 'files');
    if (files is Map) {
      for (final k in files.keys) {
        r['$k'.toLowerCase()] = own;
      }
    }
  }
  return r;
}

/// Fixture id to DMX address, from fixtures.ini. Port of `Get-Patch`.
Map<String, int> _patch(ShowEnv env) {
  final a = psMap<int>();
  final f = env.file('fixtures.ini');
  if (!f.existsSync()) return a;
  final addr = RegExp(r'^address = (\d+)', caseSensitive: false), idRx = RegExp(r'^id = (\S+)\s*$', caseSensitive: false);
  ({int a, String id})? cur;
  for (final l in readLines(f.path)) {
    if (l.startsWith('[')) {
      cur = (a: 0, id: '');
      continue;
    }
    if (cur == null) continue;
    final am = addr.firstMatch(l), im = idRx.firstMatch(l);
    if (am != null) cur = (a: int.parse(am[1]!), id: cur.id);
    if (im != null) cur = (a: cur.a, id: im[1]!);
    if (cur.id.isNotEmpty && cur.a != 0) a[cur.id] = cur.a;
  }
  return a;
}

/// Movement file (lowercase) to the live buttons that play it, as "page: title". Port of `Get-UsedBy`.
Map<String, List<String>> _usedBy(ShowEnv env) {
  final r = <String, List<String>>{};
  final LiveInfo info;
  try {
    info = LiveInfo.read(env);
  } on Object {
    return r;
  }
  for (final b in info.buttons) {
    if (!b.name.toLowerCase().endsWith('.gpj')) continue;
    r.putIfAbsent(b.name.toLowerCase(), () => []).add('${b.pageName}: ${b.title.isNotEmpty ? b.title : _title(b.name)}');
  }
  return r;
}

/// Fixture id to the mover's label and model. Port of `Get-Labels`.
Map<String, (String, String)> _labels(ShowEnv env) {
  final r = psMap<(String, String)>();
  try {
    for (final m in showMovers(env)) {
      r[m.id] = (m.label, m.model);
    }
  } on Object {
    // No CENTER SPOT scene: no labels.
  }
  return r;
}

// ---------------------------------------------------------------- actions

/// Every movement: heads, cycle, points, what plays, buttons that use it. Port of `-Action List`.
MoveList moveList(ShowEnv env) {
  _requireGdir(env);
  final used = _usedBy(env), own = _aimOwner(env);
  final list = <MoveListItem>[];
  for (final fi in _files(env)) {
    final name = p.basename(fi.path);
    OpenMove? o;
    try {
      o = OpenMove.read(fi.readAsBytesSync());
    } on Object {
      o = null;
    }
    final mo = o?.m == null ? null : MoveModel.of(o!.m!);
    final pt = mo?.sec(movePtSection);
    final t = fi.lastModifiedSync();
    list.add(
      MoveListItem(
        file: name,
        name: _title(name),
        heads: mo?.heads.length ?? 0,
        points: pt?.pts.length ?? 0,
        moves: pt != null && pt.sel != 0,
        cycle: pt == null ? 0 : pt.dur / 10,
        on: [
          for (final s in mo?.secs ?? const <MoveSection>[])
            if (s.sel != 0 && !psEq(s.name, movePtSection)) s.name,
        ],
        used: used[name.toLowerCase()] ?? const [],
        aim: own[name.toLowerCase()] ?? '',
        readonly: o == null ? 'it could not be read' : o.why,
        at: '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}',
      ),
    );
  }
  return MoveList(show: p.basename(env.root), moves: list);
}

/// One movement for the editor: heads, sections, points, DMX addresses. Port of `-Action Open`.
MoveDoc moveOpen(ShowEnv env, String move) {
  _requireGdir(env);
  final path = _moveFile(env, move);
  final o = OpenMove.read(File(path).readAsBytesSync());
  final patch = _patch(env), lab = _labels(env), used = _usedBy(env)[move.toLowerCase()];
  final mo = o.m == null ? null : MoveModel.of(o.m!);
  return MoveDoc(
    file: move,
    name: _title(move),
    sha: o.file.sha,
    readonly: o.why,
    aim: _aimOwner(env)[move.toLowerCase()] ?? '',
    used: used ?? const [],
    params: o.m == null ? const {} : {...o.m!.params},
    heads: [
      for (final h in mo?.heads ?? const <ModelHead>[])
        MoveHead(
          k: h.k,
          id: h.id,
          name: h.name,
          label: lab[h.id]?.$1 ?? h.name.replaceAllMapped(RegExp(r'^.*?(#\d+)?$'), (m) => m[1] ?? ''),
          model: lab[h.id]?.$2 ?? h.name.replaceAll(RegExp(r'\s*#\d+(\s*#\d+)*$'), ''),
          addr: patch[h.id] ?? 0,
          chans: h.chans,
          rp: h.rp,
          rt: h.rt,
          op: h.op,
          ot: h.ot,
          zp: h.zp,
          zt: h.zt,
          has: h.has,
        ),
    ],
    secs: mo?.secs ?? const [],
  );
}

/// The backups of a movement, newest first. Port of `-Action Backups`.
MoveBackups moveBackups(ShowEnv env, String move, {String? backups}) {
  _requireGdir(env);
  _moveFile(env, move);
  return MoveBackups(
    file: move,
    backups: [for (final b in _backups(env, move, backups)) MoveBackup(id: b.id, at: b.at, what: b.what)],
  );
}

/// One movement's result in [moveCheck].
class MoveCheckItem {
  const MoveCheckItem(this.file, this.ok, this.skipped, [this.why]);

  final String file;
  final bool ok;

  /// Why it was left out (it can't be changed here), or ''.
  final String skipped;

  /// What went wrong, '' when it came out the same. Null for a skipped file.
  final String? why;

  Json toJson() => {'file': file, 'ok': ok, 'skipped': skipped, 'why': ?why};
}

/// The answer of [moveCheck].
class MoveCheck {
  const MoveCheck(this.moves);

  final List<MoveCheckItem> moves;

  bool get ok => moves.every((m) => m.ok);

  Json toJson() => {
    'ok': ok,
    'moves': [for (final m in moves) m.toJson()],
  };
}

/// Every movement read, and "saved" in memory with every point and value
/// written again. Each must come out byte for byte the same. Writes nothing.
/// Port of `-Action Check`.
MoveCheck moveCheck(ShowEnv env) {
  _requireGdir(env);
  final res = <MoveCheckItem>[];
  for (final fi in _files(env)) {
    final name = p.basename(fi.path);
    final o = OpenMove.read(fi.readAsBytesSync());
    if (o.why.isNotEmpty) {
      res.add(MoveCheckItem(name, true, o.why));
      continue;
    }
    final mo = MoveModel.of(o.m!), own = _aimOwner(env)[name.toLowerCase()];
    final ch = <String, Object?>{
      'secs': [
        for (final s in mo.secs)
          {
            'name': s.name,
            if (s.has.contains('Selected')) 'sel': s.sel,
            if (s.has.contains('Transition')) 'tr': s.tr,
            if (s.has.contains('Duration') && s.dur == psRound(s.dur)) 'dur': psRound(s.dur),
            if (!s.locked && s.pts.isNotEmpty)
              'pts': [
                for (final (x, y) in s.pts) [x, y],
              ],
          },
      ],
      'heads': [
        if (own == null)
          for (final h in mo.heads)
            {
              'k': h.k,
              for (final (k, key, v) in [('op', 'OffsetPan', h.op), ('ot', 'OffsetTilt', h.ot), ('zp', 'ZoomPan', h.zp), ('zt', 'ZoomTilt', h.zt)])
                if (h.has.contains(key) && v == psRound(v)) k: psRound(v),
            },
      ],
    };
    try {
      final r = newBytes(o, ch, own);
      final same = bytesSha(r.bytes) == o.file.sha;
      res.add(MoveCheckItem(name, same, '', same ? '' : 'did not come out byte for byte the same'));
    } on ToolError catch (e) {
      res.add(MoveCheckItem(name, false, '', e.message));
    }
  }
  return MoveCheck(res);
}

/// The movement as [changes] would save it, written to [out] instead (the live
/// preview file). No check on ShowXpress, nothing in the show changes.
/// Port of `-Action Render`.
String moveRender(ShowEnv env, Map<String, Object?> changes, String out) {
  _requireGdir(env);
  if (out.isEmpty || !RegExp(r'\.gpj\n?$', caseSensitive: false).hasMatch(out)) throw ToolError('Render needs -Out <file>.gpj.');
  final move = psText(prop(changes, 'move'));
  final path = _moveFile(env, move);
  final o = OpenMove.read(File(path).readAsBytesSync());
  if (o.why.isNotEmpty) throw ToolError("${_title(move)} can't be shown from here: ${o.why}.");
  final r = newBytes(o, changes, _aimOwner(env)[move.toLowerCase()]);
  File(out).writeAsBytesSync(r.bytes);
  return '  rendered ${_title(move)}';
}

/// Writes [changes] (`{move, sha, secs, heads}`, the old changes file) into the
/// movement. Returns the report. Port of `-Action Save`.
///
/// [changes] is the request body as sent, not a parsed [MoveSave], so values of
/// the wrong kind are refused with the old tool's own words.
String moveSave(ShowEnv env, Map<String, Object?> changes, {String? backups}) {
  _requireGdir(env);
  env.requireSxClosed();
  final move = psText(prop(changes, 'move'));
  final path = _moveFile(env, move);
  final o = OpenMove.read(File(path).readAsBytesSync());
  if (o.why.isNotEmpty) throw ToolError("${_title(move)} can't be changed by SX Studio: ${o.why}. NOTHING was changed.");
  if (psText(prop(changes, 'sha')) != o.file.sha) {
    throw ToolError(
      '${_title(move)} was changed since you opened it (in ShowXpress or another window). Press Reload to see it as it is now. NOTHING was changed.',
    );
  }
  final r = newBytes(o, changes, _aimOwner(env)[move.toLowerCase()]);
  if (bytesSha(r.bytes) == o.file.sha) return '  ${_title(move)} - nothing to change.';
  final bk = _addBackup(env, move, o.file.bytes, 'before: ${r.what}', backups);
  _writeMove(path, r.bytes);
  final out = ['  CHANGED  ${_title(move)}: ${r.what}'];
  _withRestore(path, o.file.bytes, () {
    _saveBackupInfo(env, bk, bytesSha(r.bytes), move, backups);
    if (r.ptsChanged) {
      final own = _updateAimRecord(env, move, r.newPts);
      if (own != null) {
        out.add("  Aim Movers${own == 'room' ? ' (Room)' : ''} will keep this shape as you drew it (it moves and sizes it, but doesn't re-make it).");
      }
    }
  });
  out.add('  backup kept: ${bk.id}');
  return out.join('\n');
}

/// What [moveRevert] did.
sealed class MoveRevertResult {}

/// The movement changed after that backup's save. Nothing was written; ask, then revert with force.
class MoveRevertConflict extends MoveRevertResult {}

/// The report of a revert that ran.
class MoveReverted extends MoveRevertResult {
  MoveReverted(this.out);

  final String out;
}

/// Puts backup [backup] back. The current file is backed up first.
/// Port of `-Action Revert`.
MoveRevertResult moveRevert(ShowEnv env, String move, String backup, {bool force = false, String? backups}) {
  _requireGdir(env);
  env.requireSxClosed();
  final path = _moveFile(env, move);
  final bk = _backups(env, move, backups).where((b) => b.id == backup).firstOrNull;
  if (bk == null) throw ToolError('That backup is not there any more. NOTHING was changed.');
  final cur = File(path).readAsBytesSync(), curSha = bytesSha(cur);
  if (!force && bk.written.isNotEmpty && curSha != bk.written) return MoveRevertConflict();
  final old = File(bk.path).readAsBytesSync();
  if (curSha == bytesSha(old)) return MoveReverted('  ${_title(move)} is already that version - nothing to change.');
  final nb = _addBackup(env, move, cur, 'before going back to ${bk.at}', backups);
  _writeMove(path, old);
  final out = ['  CHANGED  ${_title(move)}: back to the version from before ${bk.at}'];
  _withRestore(path, cur, () {
    _saveBackupInfo(env, nb, bytesSha(old), move, backups);
    final ro = OpenMove.read(File(path).readAsBytesSync());
    if (ro.why.isEmpty) {
      final pt = MoveModel.of(ro.m!).sec(movePtSection);
      if (pt != null && _updateAimRecord(env, move, pt.pts) != null) out.add('  Aim Movers will keep this shape as it is now.');
    }
  });
  return MoveReverted(out.join('\n'));
}

// ---------------------------------------------------------------- writing

/// Writes the movement and reads it back. Port of `Write-MoveBytes`.
void _writeMove(String path, Uint8List bytes) {
  writeBytesSafely(path, bytes);
  if (bytesSha(File(path).readAsBytesSync()) != bytesSha(bytes)) {
    throw ToolError("The movement didn't read back the same after saving. Use Revert to put the earlier version back.");
  }
}

/// Runs the writes that come after the movement itself (backup info, Aim
/// Movers' record). If one fails the movement is put back as it was, so the
/// show and the other tab's record never disagree.
void _withRestore(String path, Uint8List was, void Function() after) {
  try {
    after();
  } catch (_) {
    writeBytesSafely(path, was);
    rethrow;
  }
}

/// Port of `Update-AimRecord`: a new shape goes into Aim Movers' record
/// (written = the shape as saved, base = the shape at size 100). Returns the
/// owner, or null when Aim Movers doesn't look after [file].
String? _updateAimRecord(ShowEnv env, String file, List<MovePt> pts) {
  final own = _aimOwner(env)[file.toLowerCase()];
  if (own == null || pts.length < 2) return null;
  final path = env.path(own == 'room' ? 'room_aim_state.json' : 'df_aim_state.json');
  final Object? j = jsonDecode(readText(path));
  final files = prop(j, 'files');
  final rec = prop(files, file);
  if (rec is! Map<String, Object?>) return null;
  double dbl(Object? v) => v is num ? v.toDouble() : (v == null ? 0 : (netDouble('$v') ?? 0));
  var sx = dbl(prop(rec, 'sx')), sy = dbl(prop(rec, 'sy'));
  if (sx <= 0) sx = 1;
  if (sy <= 0) sy = 1;
  final xs = [for (final p in pts) p.$1], ys = [for (final p in pts) p.$2];
  final cx = (xs.reduce((a, b) => a < b ? a : b) + xs.reduce((a, b) => a > b ? a : b)) / 2;
  final cy = (ys.reduce((a, b) => a < b ? a : b) + ys.reduce((a, b) => a > b ? a : b)) / 2;
  String fmt(Iterable<(num, num)> a) => [for (final (x, y) in a) '${psRound(x)},${psRound(y)}'].join(';');
  void set(String k, String v) {
    final key = rec.keys.where((x) => psEq(x, k)).firstOrNull;
    if (key == null) {
      throw ToolError('Exception setting "$k": "The property \'$k\' cannot be found on this object. Verify that the property exists and can be set."');
    }
    rec[key] = v;
  }

  set('written', fmt(pts));
  set('base', fmt([for (final (x, y) in pts) (cx + (x - cx) / sx, cy + (y - cy) / sy)]));
  writeTextSafely(path, psJsonPretty(j), bom: false);
  return own;
}

// ---------------------------------------------------------------- backups (outside the show folder, so Google Drive never gets them)

String _backupDir(ShowEnv env, String name, String? base) => p.join(base ?? defaultMoveBackups, p.basename(env.root), name);

typedef _Backup = ({String id, String at, String what, String written, String path});

/// Port of `Get-Backups`: newest first.
List<_Backup> _backups(ShowEnv env, String name, String? base) {
  final d = Directory(_backupDir(env, name, base));
  if (!d.existsSync()) return const [];
  final jsons = d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.json') && !p.basename(f.path).startsWith('.')).toList()
    ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
  final r = <_Backup>[];
  for (final f in jsons) {
    final Object? j;
    try {
      j = jsonDecode(readText(f.path));
    } on FormatException {
      continue;
    }
    final gpj = p.join(d.path, '${p.basenameWithoutExtension(f.path)}.gpj');
    if (File(gpj).existsSync()) {
      r.add((id: p.basenameWithoutExtension(f.path), at: psText(prop(j, 'at')), what: psText(prop(j, 'what')), written: psText(prop(j, 'written')), path: gpj));
    }
  }
  return r;
}

typedef _NewBackup = ({String id, String dir, String json, String at, String what});

/// Port of `Add-Backup`.
_NewBackup _addBackup(ShowEnv env, String name, List<int> bytes, String what, String? base) {
  final d = _backupDir(env, name, base);
  Directory(d).createSync(recursive: true);
  final t = env.now();
  final id = '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}-${t.millisecond.toString().padLeft(3, '0')}';
  File(p.join(d, '$id.gpj')).writeAsBytesSync(bytes);
  return (
    id: id,
    dir: d,
    json: p.join(d, '$id.json'),
    at: '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}',
    what: what,
  );
}

/// Port of `Save-BackupInfo`: the backup's note, then the oldest past [_maxBackups] go.
void _saveBackupInfo(ShowEnv env, _NewBackup bk, String written, String name, String? base) {
  File(bk.json).writeAsStringSync('{"at":${psJsonString(bk.at)},"what":${psJsonString(bk.what)},"written":${psJsonString(written)}}');
  for (final old in _backups(env, name, base).skip(_maxBackups)) {
    for (final f in [old.path, old.path.replaceFirst(RegExp(r'\.gpj$'), '.json')]) {
      try {
        File(f).deleteSync();
      } on FileSystemException {
        // Like -ErrorAction SilentlyContinue.
      }
    }
  }
}
