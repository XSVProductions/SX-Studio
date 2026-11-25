import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/fixtures.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'scene_edit/scene_change.dart';
import 'scene_edit/scene_text.dart';
import 'scene_edit/scene_xml.dart';

// SCENE EDITOR: reads and changes ShowXpress scenes (.scex).
//
// ShowXpress must still open every file written, and anything the editor
// doesn't understand is passed through untouched. So a save never rebuilds a
// scene: it starts from the file's own text and changes only
//   - the value="" / length="" of what was edited (and adds or removes fade="1"),
//   - whole <Step> blocks (copied as text for a new step, left out for a
//     deleted one, put in a new order),
//   - whole <Channel .../> lines (a channel added to or taken out of one head
//     in every step).
// Everything else (the header, the fixture list, tags and attributes the
// editor doesn't know, comments, spacing, the BOM and the line endings) stays
// byte for byte as it was. Before anything is written the same changes are
// made a second, independent way, on the parsed XML, and both must give the
// same scene. Every save keeps the previous file as a backup.
//
// Port of `scene_edit.ps1`.

/// How many earlier versions of a scene are kept.
const maxSceneBackups = 20;

/// Where scene backups go, given the engine's settings folder
/// (`Engine.settingsFolder`): outside the show folder, so Google Drive never
/// gets them. Each show and scene has its own folder below this one.
String sceneBackupBase(String settingsFolder) => p.join(settingsFolder, 'scene_backups');

final _sceneName = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$', caseSensitive: false);
final _scexEnd = RegExp(r'\.scex$', caseSensitive: false);

String _bareName(String file) => file.replaceFirst(_scexEnd, '');

String _shaBytes(List<int> b) => sha256.convert(b).toString();

final _utf8Strict = const Utf8Decoder();

void _requireScenes(ShowEnv env) {
  if (!Directory(env.path('scenes')).existsSync()) throw ToolError('The show has no scenes folder (${env.root}). NOTHING was changed.');
}

/// The scene files in `scenes/`, sorted by name.
List<File> _sceneFiles(ShowEnv env) {
  final files = Directory(env.path('scenes')).listSync().whereType<File>().where((f) => p.basename(f.path).toLowerCase().endsWith('.scex'));
  return psSorted<File>(files, [(f) => p.basename(f.path)]);
}

/// `[IO.File]::ReadAllText`: UTF-8, or UTF-16 / UTF-32 when the file starts
/// with their byte order mark.
String _readAllText(String path) {
  final b = File(path).readAsBytesSync();
  bool at(List<int> m) => b.length >= m.length && [for (var i = 0; i < m.length; i++) b[i] == m[i]].every((x) => x);
  String utf16(int skip, Endian e) {
    final bd = ByteData.sublistView(Uint8List.fromList(b));
    return String.fromCharCodes([for (var i = skip; i + 1 < b.length; i += 2) bd.getUint16(i, e)]);
  }

  if (at(const [0xFF, 0xFE]) && !at(const [0xFF, 0xFE, 0, 0])) return utf16(2, Endian.little);
  if (at(const [0xFE, 0xFF])) return utf16(2, Endian.big);
  return readText(path);
}

/// Checks a scene file name and finds the file. Port of `Get-SceneFile`.
String _sceneFile(ShowEnv env, String name) {
  if (!_sceneName.hasMatch(name) || name.startsWith('.')) throw ToolError("Not a scene name: '$name'. NOTHING was changed.");
  final path = p.join(env.path('scenes'), name);
  if (!File(path).existsSync()) throw ToolError("Scene '$name' not found in the show. NOTHING was changed.");
  return path;
}

/// A scene file's bytes, and its text when it is plain UTF-8. Port of `Read-SceneBytes`.
class _SceneBytes {
  _SceneBytes(this.bytes) : bom = hasBom(bytes), sha = _shaBytes(bytes) {
    try {
      final t = _utf8Strict.convert(bytes, bom ? 3 : 0);
      if (_sameBytes(_toBytes(t, bom), bytes)) {
        text = t;
      } else {
        why = 'the file does not read back the same way';
      }
    } on FormatException {
      why = 'the file is not plain UTF-8 text';
    }
  }

  final List<int> bytes;
  final bool bom;
  final String sha;
  String? text;
  String why = '';
}

List<int> _toBytes(String text, bool bom) => [
  if (bom) ...const [0xEF, 0xBB, 0xBF],
  ...utf8.encode(text),
];

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A scene read for editing. [sc] is null when the editor leaves it alone,
/// and [why] says why. Port of `Open-Scene`.
class _Opened {
  _Opened(String path) : file = _SceneBytes(File(path).readAsBytesSync()) {
    why = file.why;
    if (why.isNotEmpty) return;
    final s = SxsScene.read(file.text!);
    if (!s.ok) {
      why = s.why;
      return;
    }
    final String xm;
    try {
      xm = xmlModel(file.text!);
    } on FormatException {
      why = 'it is not valid XML';
      return;
    }
    if (xm != s.model()) {
      why = 'the editor could not read it safely';
      return;
    }
    sc = s;
  }

  final _SceneBytes file;
  SxsScene? sc;
  String why = '';

  String get text => file.text!;
}

// ---------------------------------------------------------------- show info

/// Head id to DMX address, from fixtures.ini. Port of `Get-Patch`.
Map<String, int> _patch(ShowEnv env) {
  final a = psMap<int>();
  final f = env.file('fixtures.ini');
  if (!f.existsSync()) return a;
  final addrRx = RegExp(r'^address = (\d+)', caseSensitive: false), idRx = RegExp(r'^id = (\S+)\s*$', caseSensitive: false);
  ({String? id, int? a})? cur;
  for (final l in readLines(f.path)) {
    if (l.startsWith('[')) {
      cur = (id: null, a: null);
      continue;
    }
    if (cur == null) continue;
    final am = addrRx.firstMatch(l), im = idRx.firstMatch(l);
    if (am != null) cur = (id: cur.id, a: int.parse(am[1]!));
    if (im != null) cur = (id: im[1]!, a: cur.a);
    final id = cur.id, ad = cur.a;
    if (id != null && id.isNotEmpty && ad != null && ad != 0) a[id] = ad;
  }
  return a;
}

/// Scene file (lowercase) to the live buttons that play it, as "PAGE: title".
/// Port of `Get-UsedBy`.
Map<String, List<String>> _usedBy(ShowEnv env) {
  final r = psMap<List<String>>();
  final LiveInfo info;
  try {
    info = LiveInfo.read(env);
  } on Object {
    return r;
  }
  for (final b in info.buttons) {
    if (!b.name.toLowerCase().endsWith('.scex')) continue;
    r.putIfAbsent(b.name.toLowerCase(), () => []).add('${b.pageName}: ${b.title.isNotEmpty ? b.title : _bareName(b.name)}');
  }
  return r;
}

String _psStr(Object? v) => switch (v) {
  null => '',
  String() => v,
  bool() => v ? 'True' : 'False',
  _ => '$v',
};

/// Scene files Tonight's Rig has trimmed right now, to the sha of the text it
/// wrote. Port of `Get-RigTrimmed`.
Map<String, String> _rigTrimmed(ShowEnv env) {
  final r = psMap<String>();
  final f = env.file('rig_state.json');
  if (!f.existsSync()) return r;
  Object? j;
  try {
    j = jsonDecode(_readAllText(f.path));
  } on FormatException {
    return r;
  }
  if (j is! Map || j['scenes'] is! Map) return r;
  (j['scenes'] as Map).forEach((k, v) => r['$k'.toLowerCase()] = _psStr(v is Map ? v['written'] : null));
  return r;
}

/// True when Tonight's Rig trimmed [name] and the file is still what it wrote.
/// Port of `Test-Trimmed`.
bool _trimmed(Map<String, String> trim, String name, String path) {
  final w = trim[name.toLowerCase()] ?? '';
  return w.isNotEmpty && psEq(textSha(_readAllText(path)), w);
}

/// Model to channel index to name, from this scene and then every other
/// scene (names as ShowXpress wrote them). Port of `Get-ChannelNames`.
Map<String, Map<int, String>> _channelNames(ShowEnv env, _Opened o) {
  final want = {
    for (final h in o.sc!.heads)
      if (h.model.isNotEmpty) h.model,
  };
  final r = <String, Map<int, String>>{};
  SxsScene.names(o.text, want, r);
  for (final f in _sceneFiles(env)) {
    final String t;
    try {
      t = _readAllText(f.path);
    } on FileSystemException {
      continue;
    }
    if (want.any((k) => t.contains(xmlEscape(k)))) SxsScene.names(t, want, r);
  }
  return r;
}

/// Channel name (lowercase) to its named ranges, from `fixtures/<model>.txt`.
/// Port of `Get-Ranges`.
Map<String, List<SceneRange>> _ranges(FixtureDefs defs, String model) => {
  for (final e in defs.of(model).entries)
    if (e.value.isNotEmpty) e.key: [for (final r in e.value) SceneRange(n: r.name, lo: r.lo, hi: r.hi)],
};

// ---------------------------------------------------------------- backups

/// A scene's backup folder. Port of `Get-BackupDir`.
String _backupDir(ShowEnv env, String base, String name) => p.join(base, p.basename(p.normalize(env.root)), name);

class _Backup {
  _Backup(this.id, this.at, this.what, this.written, this.path);

  final String id, at, what, written, path;
}

/// A scene's backups, newest first. Port of `Get-Backups`.
List<_Backup> _backups(ShowEnv env, String base, String name) {
  final d = Directory(_backupDir(env, base, name));
  if (!d.existsSync()) return [];
  final infos = d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.json')).toList()
    ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
  final out = <_Backup>[];
  for (final i in infos) {
    Object? j;
    try {
      j = jsonDecode(_readAllText(i.path));
    } on FormatException {
      continue;
    }
    final id = p.basenameWithoutExtension(i.path);
    final f = p.join(d.path, '$id.scex');
    if (!File(f).existsSync()) continue;
    String k(String key) => j is Map ? _psStr(j[key]) : '';
    out.add(_Backup(id, k('at'), k('what'), k('written'), f));
  }
  return out;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// A new backup: the file's bytes now. Its info file is written by
/// [_saveBackupInfo] once the scene is saved. Port of `Add-Backup`.
({String id, String dir, String json, String at, String what, String scex}) _addBackup(ShowEnv env, String base, String name, List<int> bytes, String what) {
  final d = _backupDir(env, base, name);
  Directory(d).createSync(recursive: true);
  final n = env.now();
  final id = '${n.year}${_two(n.month)}${_two(n.day)}-${_two(n.hour)}${_two(n.minute)}${_two(n.second)}-${n.millisecond.toString().padLeft(3, '0')}';
  final scex = p.join(d, '$id.scex');
  writeBytesSafely(scex, bytes);
  return (
    id: id,
    dir: d,
    json: p.join(d, '$id.json'),
    at: '${n.year}-${_two(n.month)}-${_two(n.day)} ${_two(n.hour)}:${_two(n.minute)}:${_two(n.second)}',
    what: what,
    scex: scex,
  );
}

/// Writes a backup's info and drops the oldest backups beyond
/// [maxSceneBackups]. Port of `Save-BackupInfo`.
void _saveBackupInfo(ShowEnv env, String base, String name, ({String id, String dir, String json, String at, String what, String scex}) bk, String written) {
  writeTextSafely(bk.json, jsonEncode({'at': bk.at, 'what': bk.what, 'written': written}), bom: false);
  for (final old in _backups(env, base, name).skip(maxSceneBackups)) {
    for (final f in [old.path, p.setExtension(old.path, '.json')]) {
      try {
        File(f).deleteSync();
      } on FileSystemException {
        // gone already
      }
    }
  }
}

/// Saves a scene's new bytes and reads them back. Port of `Write-SceneBytes`.
void _writeScene(String path, List<int> bytes) {
  writeBytesSafely(path, bytes);
  if (!_sameBytes(File(path).readAsBytesSync(), bytes)) {
    throw ToolError("The scene didn't read back the same after saving. Use Revert to put the earlier version back.");
  }
}

/// Backs the scene up, writes [bytes] and then the backup's info. If a later
/// step fails, the scene and the backup are put back as they were.
String _writeWithBackup(ShowEnv env, String base, String name, String path, List<int> before, List<int> bytes, String what) {
  final bk = _addBackup(env, base, name, before, what);
  var written = false;
  try {
    _writeScene(path, bytes);
    written = true;
    _saveBackupInfo(env, base, name, bk, _shaBytes(bytes));
  } catch (_) {
    if (written) writeBytesSafely(path, before);
    for (final f in [bk.scex, bk.json]) {
      if (File(f).existsSync()) File(f).deleteSync();
    }
    rethrow;
  }
  return bk.id;
}

// ================================================================ actions

/// Every scene in `scenes/`: steps, heads, the buttons that use it, trimmed.
/// Port of `-Action List`.
SceneList sceneList(ShowEnv env) {
  _requireScenes(env);
  final used = _usedBy(env), trim = _rigTrimmed(env);
  final stepRx = RegExp(r'<Step[\f\n\r\t\v\x85\p{Z}>/]', unicode: true), headsRx = RegExp(r'<Fixtures>([\s\S]*?)</Fixtures>');
  final fixRx = RegExp(r'<Fixture[\f\n\r\t\v\x85\p{Z}]', unicode: true);
  return SceneList(
    show: env.root,
    scenes: [
      for (final f in _sceneFiles(env))
        () {
          final name = p.basename(f.path);
          var t = '';
          try {
            t = _readAllText(f.path);
          } on FileSystemException {
            // unreadable: no steps, no heads
          }
          final hm = headsRx.firstMatch(t);
          final m = f.lastModifiedSync();
          return SceneListItem(
            file: name,
            name: _bareName(name),
            steps: stepRx.allMatches(t).length,
            heads: hm == null ? 0 : fixRx.allMatches(hm[1]!).length,
            used: used[name.toLowerCase()] ?? const [],
            trimmed: _trimmed(trim, name, f.path),
            at: '${m.year}-${_two(m.month)}-${_two(m.day)}T${_two(m.hour)}:${_two(m.minute)}:${_two(m.second)}',
          );
        }(),
    ],
  );
}

/// Every scene read and "saved" with no changes in memory. Nothing is
/// written. Each editable scene must come out byte for byte the same.
/// Port of `-Action Check`.
SceneCheck sceneCheck(ShowEnv env) {
  _requireScenes(env);
  final res = <SceneCheckItem>[];
  for (final f in _sceneFiles(env)) {
    final o = _Opened(f.path);
    var same = false, self = false;
    final sc = o.sc;
    if (sc != null) {
      final steps = [for (var i = 0; i < sc.steps.length; i++) SceneStepChange(src: i)];
      final nt = changedText(o.text, sc, steps, const [], const [], const {});
      same = _sameBytes(_toBytes(nt, o.file.bom), o.file.bytes);
      self = canonXml(nt) == changedXml(o.text, sc.structural, steps, const [], const [], const {});
    }
    res.add(SceneCheckItem(file: p.basename(f.path), editable: o.why.isEmpty, why: o.why, structural: sc?.structural ?? false, same: same, selfCheck: self));
  }
  return SceneCheck(
    show: env.root,
    scenes: res,
    total: res.length,
    editable: res.where((s) => s.editable).length,
    bad: [
      for (final s in res)
        if (s.editable && !(s.same && s.selfCheck)) s.file,
    ],
  );
}

/// A scene for the editor: steps, heads, channels, named ranges, DMX
/// addresses. Port of `-Action Open`.
SceneOpen sceneOpen(ShowEnv env, String scene, {required String backupBase}) {
  _requireScenes(env);
  final path = _sceneFile(env, scene);
  final o = _Opened(path);
  final used = _usedBy(env)[scene.toLowerCase()] ?? const <String>[];
  final sc = o.sc;
  final base = SceneOpen(
    show: env.root,
    file: scene,
    name: _bareName(scene),
    sha: o.file.sha,
    used: used,
    trimmed: _trimmed(_rigTrimmed(env), scene, path),
    readonly: o.why,
    structural: sc?.structural ?? false,
    backups: _backups(env, backupBase, scene).length,
  );
  if (sc == null) return base;
  final patch = _patch(env), names = _channelNames(env, o), defs = FixtureDefs(env);
  final models = <String, SceneModel>{};
  for (final mo in sc.heads.map((h) => h.model).toSet()) {
    final cn = names[mo];
    models[mo] = SceneModel(
      chans: [
        if (cn != null)
          for (final k in cn.keys.toList()..sort()) SceneChannelName(ix: k, name: cn[k]!),
      ],
      ranges: _ranges(defs, mo),
    );
  }
  final digits = RegExp(r'^\d+$');
  return SceneOpen(
    show: base.show,
    file: base.file,
    name: base.name,
    sha: base.sha,
    used: base.used,
    trimmed: base.trimmed,
    readonly: base.readonly,
    structural: base.structural,
    backups: base.backups,
    heads: [for (final h in sc.heads) SceneHead(id: h.id, name: h.name, model: h.model, addr: patch[h.id] ?? 0)],
    models: models,
    steps: [
      for (final s in sc.steps)
        SceneEditStep(
          len: s.len != null && digits.hasMatch(s.len!.v) ? int.tryParse(s.len!.v) : null,
          lenRaw: s.len?.v ?? '',
          fx: [
            for (final f in s.fx)
              SceneStepFixture(
                id: f.id,
                ch: [for (final c in f.ch) SceneChannel(ix: c.ix, name: c.name, v: c.v, fade: c.fade)],
              ),
          ],
        ),
    ],
  );
}

/// The backups of a scene, newest first. Port of `-Action Backups`.
SceneBackups sceneBackups(ShowEnv env, String scene, {required String backupBase}) {
  _requireScenes(env);
  _sceneFile(env, scene);
  return SceneBackups(
    file: scene,
    backups: [for (final b in _backups(env, backupBase, scene)) SceneBackup(id: b.id, at: b.at, what: b.what)],
  );
}

/// What a revert did. When [conflict] is true nothing was written: the scene
/// was saved again after that backup, and the user has to confirm.
typedef SceneRevertResult = ({bool conflict, String out});

/// Puts a backup back. The current file is backed up first. Port of `-Action Revert`.
SceneRevertResult sceneRevert(ShowEnv env, String scene, String backup, {bool force = false, required String backupBase}) {
  _requireScenes(env);
  env.requireSxClosed();
  final base = backupBase;
  final path = _sceneFile(env, scene);
  final bk = _backups(env, base, scene).where((b) => b.id == backup).firstOrNull;
  if (bk == null) throw ToolError('That backup is not there any more. NOTHING was changed.');
  final cur = File(path).readAsBytesSync();
  final curSha = _shaBytes(cur);
  if (!force && bk.written.isNotEmpty && !psEq(curSha, bk.written)) {
    return (conflict: true, out: '  The scene was changed after that save (in ShowXpress or SX Studio). Revert anyway?');
  }
  final old = File(bk.path).readAsBytesSync();
  if (psEq(curSha, _shaBytes(old))) return (conflict: false, out: '  ${_bareName(scene)} is already that version - nothing to change.');
  _writeWithBackup(env, base, scene, path, cur, old, 'before going back to ${bk.at}');
  return (conflict: false, out: '  CHANGED  ${_bareName(scene)}: back to the version from before ${bk.at}');
}

/// Writes a scene's changes. Returns the report. Port of `-Action Save`.
String sceneSave(ShowEnv env, SceneChanges changes, {required String backupBase}) {
  _requireScenes(env);
  env.requireSxClosed();
  final base = backupBase;
  final scene = changes.scene, bare = _bareName(scene);
  final path = _sceneFile(env, scene);
  final o = _Opened(path);
  final sc = o.sc;
  if (sc == null) throw ToolError("$bare can't be changed by SX Studio: ${o.why}. NOTHING was changed.");
  if (changes.sha != o.file.sha) {
    throw ToolError('$bare was changed since you opened it (in ShowXpress or another window). Press Reload to see it as it is now. NOTHING was changed.');
  }
  final steps = checkChanges(sc, changes);
  final addch = changes.addch, delch = changes.delch;
  final names = psMap<String>();
  if (addch.isNotEmpty) {
    final cn = _channelNames(env, o);
    final modelOf = psMap<String>();
    for (final h in sc.heads) {
      modelOf[h.id] = h.model;
    }
    for (final a in addch) {
      final mo = modelOf[a.fx] ?? '';
      final nm = cn[mo]?[a.ix] ?? '';
      if (nm.isEmpty) {
        throw ToolError("Channel ${a.ix} of $mo has no name in any scene, so it can't be added here - add it once in ShowXpress. NOTHING was changed.");
      }
      names['${a.fx}|${a.ix}'] = nm;
    }
  }
  final nt = changedText(o.text, sc, steps, addch, delch, names);
  final nb = _toBytes(nt, o.file.bom);
  if (_sameBytes(nb, o.file.bytes)) return '  $bare - nothing to change.';
  // the checks: outside <Steps> untouched, the text way = the XML way, and SX Studio can read the result again
  final t = o.text;
  final tailOld = t.substring(sc.steps.last.end);
  if (!nt.startsWith(t.substring(0, sc.open)) || !nt.endsWith(tailOld)) {
    throw ToolError("Self-check failed (the scene's header would change). NOTHING was changed.");
  }
  final canon = canonXml(nt);
  if (canon == null || canon != changedXml(t, sc.structural, steps, addch, delch, names)) {
    throw ToolError("Self-check failed (the two ways of making the change don't agree). NOTHING was changed.");
  }
  final re = SxsScene.read(nt);
  String? reXml;
  try {
    reXml = xmlModel(nt);
  } on FormatException {
    reXml = null;
  }
  if (!re.ok || reXml != re.model()) throw ToolError("Self-check failed (the new scene doesn't read back cleanly). NOTHING was changed.");

  var nVals = 0, nLen = 0;
  for (final s in steps) {
    nVals += s.set.length;
    if (s.len != null) nLen++;
  }
  final what = <String>[
    if (steps.length != sc.steps.length)
      '${sc.steps.length} -> ${steps.length} steps'
    else if ([for (var i = 0; i < steps.length; i++) steps[i].src != i].any((x) => x))
      'steps moved',
    if (nVals > 0) '$nVals value(s)',
    if (nLen > 0) '$nLen step length(s)',
    if (addch.isNotEmpty) '${addch.length} channel(s) added',
    if (delch.isNotEmpty) '${delch.length} channel(s) taken out',
  ];
  final trimmedNow = _trimmed(_rigTrimmed(env), scene, path);
  final id = _writeWithBackup(env, base, scene, path, o.file.bytes, nb, 'before: ${what.join(', ')}');
  return [
    '  CHANGED  $bare: ${what.join(', ')}',
    if (trimmedNow) "  NOTE  Tonight's Rig had trimmed this scene - the version you saved now counts as the full scene.",
    '  backup kept: $id',
  ].join('\n');
}
