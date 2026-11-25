import 'client.dart';
import 'json.dart';

// Scene Editor wire types. Port of the JSON `scene_edit.ps1` prints and the
// change file `/api/scene/save` hands it.

/// One scene in the Scene Editor's list.
class SceneListItem {
  const SceneListItem({
    required this.file,
    required this.name,
    required this.steps,
    required this.heads,
    required this.used,
    required this.trimmed,
    required this.at,
  });

  factory SceneListItem.fromJson(Json j) => SceneListItem(
    file: j.str('file'),
    name: j.str('name'),
    steps: j.integer('steps'),
    heads: j.integer('heads'),
    used: j.strList('used'),
    trimmed: j.boolean('trimmed'),
    at: j.str('at'),
  );

  /// File name in `scenes/`, for example `CHASE.scex`. The scene's id.
  final String file;

  /// [file] without `.scex`.
  final String name;
  final int steps;
  final int heads;

  /// Live buttons that play it, as "PAGE: title".
  final List<String> used;

  /// Tonight's Rig has trimmed this scene, and the file is still the trimmed version.
  final bool trimmed;

  /// When the file last changed, local time, `2026-11-24T21:05:00`.
  final String at;

  Json toJson() => {'file': file, 'name': name, 'steps': steps, 'heads': heads, 'used': used, 'trimmed': trimmed, 'at': at};
}

/// Every scene in the show's `scenes/` folder.
class SceneList {
  const SceneList({required this.show, required this.scenes});

  factory SceneList.fromJson(Json j) => SceneList(show: j.str('show'), scenes: j.list('scenes', SceneListItem.fromJson));

  final String show;
  final List<SceneListItem> scenes;

  Json toJson() => {
    'ok': true,
    'show': show,
    'scenes': [for (final s in scenes) s.toJson()],
  };
}

/// A fixture (head) of a scene, with its DMX start address from fixtures.ini.
class SceneHead {
  const SceneHead({required this.id, required this.name, required this.model, required this.addr});

  factory SceneHead.fromJson(Json j) => SceneHead(id: j.str('id'), name: j.str('name'), model: j.str('model'), addr: j.integer('addr'));

  final String id;
  final String name;
  final String model;

  /// DMX start address, or 0 when the head is not patched.
  final int addr;

  Json toJson() => {'id': id, 'name': name, 'model': model, 'addr': addr};
}

/// A channel name as ShowXpress wrote it in the show's scenes.
class SceneChannelName {
  const SceneChannelName({required this.ix, required this.name});

  factory SceneChannelName.fromJson(Json j) => SceneChannelName(ix: j.integer('ix'), name: j.str('name'));

  /// 0-based channel index within the head.
  final int ix;
  final String name;

  Json toJson() => {'ix': ix, 'name': name};
}

/// A named value range of a channel ("red" = 10..19), from the fixture profile.
class SceneRange {
  const SceneRange({required this.n, required this.lo, required this.hi});

  factory SceneRange.fromJson(Json j) => SceneRange(n: j.str('n'), lo: j.integer('lo'), hi: j.integer('hi'));

  /// Range name, lowercase.
  final String n;
  final int lo;
  final int hi;

  Json toJson() => {'n': n, 'lo': lo, 'hi': hi};
}

/// What the editor knows about one fixture model.
class SceneModel {
  const SceneModel({required this.chans, required this.ranges});

  factory SceneModel.fromJson(Json j) {
    final r = j.obj('ranges');
    return SceneModel(chans: j.list('chans', SceneChannelName.fromJson), ranges: {for (final k in r.keys) k: r.list(k, SceneRange.fromJson)});
  }

  /// Every channel of the model any scene in the show names, by index.
  final List<SceneChannelName> chans;

  /// Channel name (lowercase) to its named ranges. Only channels that have some.
  final Map<String, List<SceneRange>> ranges;

  Json toJson() => {
    'chans': [for (final c in chans) c.toJson()],
    'ranges': {
      for (final e in ranges.entries) e.key: [for (final r in e.value) r.toJson()],
    },
  };
}

/// One channel of one head in one step. On the wire it is `[ix, name, v, fade]`.
class SceneChannel {
  const SceneChannel({required this.ix, required this.name, required this.v, required this.fade});

  factory SceneChannel.fromJson(Object? raw) {
    if (raw is! List || raw.length < 4) throw FormatException('A scene channel should be [ix, name, value, fade], got $raw');
    int n(Object? x) => x is num ? x.round() : int.tryParse('$x') ?? -1;
    return SceneChannel(ix: n(raw[0]), name: '${raw[1] ?? ''}', v: n(raw[2]), fade: n(raw[3]) == 1);
  }

  /// 0-based index, or -1 when the file's index is not a number the editor reads.
  final int ix;
  final String name;

  /// 0..255, or -1 for a value the editor doesn't change (not a plain number).
  final int v;
  final bool fade;

  List<Object> toJson() => [ix, name, v, fade ? 1 : 0];
}

/// One head's channels in one step.
class SceneStepFixture {
  const SceneStepFixture({required this.id, required this.ch});

  factory SceneStepFixture.fromJson(Json j) {
    final raw = j['ch'];
    return SceneStepFixture(id: j.str('id'), ch: [for (final c in raw is List ? raw : const []) SceneChannel.fromJson(c)]);
  }

  final String id;
  final List<SceneChannel> ch;

  Json toJson() => {
    'id': id,
    'ch': [for (final c in ch) c.toJson()],
  };
}

/// One step of a scene, as found in the file.
class SceneEditStep {
  const SceneEditStep({required this.len, required this.lenRaw, required this.fx});

  factory SceneEditStep.fromJson(Json j) => SceneEditStep(len: j.integerOrNull('len'), lenRaw: j.str('lenRaw'), fx: j.list('fx', SceneStepFixture.fromJson));

  /// Length in hundredths of a second, or null when the step has none (or not a number).
  final int? len;

  /// The `length` attribute as written, '' when there is none.
  final String lenRaw;
  final List<SceneStepFixture> fx;

  Json toJson() => {
    'len': len,
    'lenRaw': lenRaw,
    'fx': [for (final f in fx) f.toJson()],
  };
}

/// A scene opened for editing.
///
/// When [readonly] is not empty the editor can't change the file safely, and
/// [heads], [models] and [steps] are left out.
class SceneOpen {
  const SceneOpen({
    required this.show,
    required this.file,
    required this.name,
    required this.sha,
    required this.used,
    required this.trimmed,
    required this.readonly,
    required this.structural,
    required this.backups,
    this.heads,
    this.models,
    this.steps,
  });

  factory SceneOpen.fromJson(Json j) {
    final m = j.objOrNull('models');
    return SceneOpen(
      show: j.str('show'),
      file: j.str('file'),
      name: j.str('name'),
      sha: j.str('sha'),
      used: j.strList('used'),
      trimmed: j.boolean('trimmed'),
      readonly: j.str('readonly'),
      structural: j.boolean('structural'),
      backups: j.integer('backups'),
      heads: j['heads'] == null ? null : j.list('heads', SceneHead.fromJson),
      models: m == null ? null : {for (final k in m.keys) k: SceneModel.fromJson(m.obj(k))},
      steps: j['steps'] == null ? null : j.list('steps', SceneEditStep.fromJson),
    );
  }

  final String show;
  final String file;
  final String name;

  /// SHA-256 of the file's bytes. Sent back with a save, so the engine can
  /// refuse when the file changed in between.
  final String sha;
  final List<String> used;
  final bool trimmed;

  /// Why the editor leaves this scene alone, or '' when it can edit it.
  final String readonly;

  /// False when something unknown sits between the steps. Then steps can be
  /// changed but not added, moved or taken out.
  final bool structural;

  /// How many earlier versions are kept.
  final int backups;
  final List<SceneHead>? heads;
  final Map<String, SceneModel>? models;
  final List<SceneEditStep>? steps;

  Json toJson() => {
    'ok': true,
    'show': show,
    'file': file,
    'name': name,
    'sha': sha,
    'used': used,
    'trimmed': trimmed,
    'readonly': readonly,
    'structural': structural,
    'backups': backups,
    if (heads != null) 'heads': [for (final h in heads!) h.toJson()],
    if (models != null) 'models': {for (final e in models!.entries) e.key: e.value.toJson()},
    if (steps != null) 'steps': [for (final s in steps!) s.toJson()],
  };
}

/// Reads a whole number the way the old tool's checks see it. Anything that
/// is not a plain non-negative whole number reads as -1, which every check
/// refuses, as the old tool's `^\d+$` tests do.
int _wholeOr(Object? v, int bad) {
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  if (v is String && RegExp(r'^\d+$').hasMatch(v)) return int.tryParse(v) ?? bad;
  return bad;
}

/// The items of a changes list, as the old server and `scene_edit.ps1` kept
/// them. A null is dropped (`Where-Object { $null -ne $_ }`), and with
/// [dropFalse] so are false, 0 and '' (`if (-not $x) { continue }`). An item
/// that is not an object stays as an empty one, so it fails the checks the
/// way the old tool's did (its fields read as null).
List<Json> _objects(Object? raw, {bool dropFalse = false}) => [
  for (final e in raw is List ? raw : (raw == null ? const [] : [raw]))
    if (e is Map)
      e.cast<String, Object?>()
    else if (e != null && !(dropFalse && (e == false || e == 0 || e == '' || (e is List && e.isEmpty))))
      <String, Object?>{},
];

/// "Set this channel of this head in this step." [v] or [fade] may be left out.
class SceneSet {
  const SceneSet({required this.fx, required this.ix, this.v, this.fade});

  factory SceneSet.fromJson(Json j) {
    final f = j['fade'];
    if (f != null && f is! bool) throw const FormatException('Bad fade setting. NOTHING was changed.');
    return SceneSet(fx: j.str('fx'), ix: _wholeOr(j['ix'], -1), v: j['v'] == null ? null : _wholeOr(j['v'], -1), fade: f as bool?);
  }

  /// Head id.
  final String fx;

  /// 0-based channel index.
  final int ix;

  /// New value 0..255, or null to leave it.
  final int? v;

  /// Fade on or off, or null to leave it.
  final bool? fade;

  Json toJson() => {'fx': fx, 'ix': ix, 'v': ?v, 'fade': ?fade};
}

/// One step of the new list of steps: a copy of old step [src], with its own changes.
class SceneStepChange {
  const SceneStepChange({required this.src, this.len, this.set = const []});

  factory SceneStepChange.fromJson(Json j) => SceneStepChange(
    src: _wholeOr(j['src'], -1),
    len: j['len'] == null ? null : _wholeOr(j['len'], -1),
    set: [for (final s in _objects(j['set'], dropFalse: true)) SceneSet.fromJson(s)],
  );

  /// 0-based number of the step in the file this one is a copy of.
  final int src;

  /// New length in hundredths of a second, or null to leave it.
  final int? len;
  final List<SceneSet> set;

  Json toJson() => {
    'src': src,
    'len': ?len,
    'set': [for (final s in set) s.toJson()],
  };
}

/// A channel of a head, for adding to or taking out of every step.
class SceneChannelRef {
  const SceneChannelRef({required this.fx, required this.ix});

  factory SceneChannelRef.fromJson(Json j) => SceneChannelRef(fx: j.str('fx'), ix: _wholeOr(j['ix'], -1));

  final String fx;
  final int ix;

  Json toJson() => {'fx': fx, 'ix': ix};
}

/// Everything a Scene Editor save sends. Only what differs from the file.
///
/// The work is done in this order: [delch], [addch] (value 0, no fade, in
/// every step that has the head), then each step's length and values.
class SceneChanges {
  const SceneChanges({required this.scene, required this.sha, required this.steps, this.addch = const [], this.delch = const []});

  factory SceneChanges.fromJson(Json j) => SceneChanges(
    scene: j.str('scene'),
    sha: j.str('sha'),
    steps: [for (final s in _objects(j['steps'])) SceneStepChange.fromJson(s)],
    addch: [for (final s in _objects(j['addch'], dropFalse: true)) SceneChannelRef.fromJson(s)],
    delch: [for (final s in _objects(j['delch'], dropFalse: true)) SceneChannelRef.fromJson(s)],
  );

  /// File name in `scenes/`.
  final String scene;

  /// [SceneOpen.sha] of the file the edits were made on.
  final String sha;

  /// The new list of steps, in order.
  final List<SceneStepChange> steps;
  final List<SceneChannelRef> addch;
  final List<SceneChannelRef> delch;

  Json toJson() => {
    'scene': scene,
    'sha': sha,
    'steps': [for (final s in steps) s.toJson()],
    'addch': [for (final a in addch) a.toJson()],
    'delch': [for (final d in delch) d.toJson()],
  };
}

/// An earlier version of a scene, kept by a save or a revert.
class SceneBackup {
  const SceneBackup({required this.id, required this.at, required this.what});

  factory SceneBackup.fromJson(Json j) => SceneBackup(id: j.str('id'), at: j.str('at'), what: j.str('what'));

  /// `yyyyMMdd-HHmmss-fff`.
  final String id;

  /// When the save that replaced it happened, `yyyy-MM-dd HH:mm:ss`.
  final String at;

  /// What that save changed, for example "before: 2 value(s)".
  final String what;

  Json toJson() => {'id': id, 'at': at, 'what': what};
}

/// A scene's earlier versions, newest first.
class SceneBackups {
  const SceneBackups({required this.file, required this.backups});

  factory SceneBackups.fromJson(Json j) => SceneBackups(file: j.str('file'), backups: j.list('backups', SceneBackup.fromJson));

  final String file;
  final List<SceneBackup> backups;

  Json toJson() => {
    'ok': true,
    'file': file,
    'backups': [for (final b in backups) b.toJson()],
  };
}

/// One scene in the read-back check.
class SceneCheckItem {
  const SceneCheckItem({required this.file, required this.editable, required this.why, required this.structural, required this.same, required this.selfCheck});

  factory SceneCheckItem.fromJson(Json j) => SceneCheckItem(
    file: j.str('file'),
    editable: j.boolean('editable'),
    why: j.str('why'),
    structural: j.boolean('structural'),
    same: j.boolean('same'),
    selfCheck: j.boolean('selfCheck'),
  );

  final String file;
  final bool editable;
  final String why;
  final bool structural;

  /// A save with no changes gives the file back byte for byte.
  final bool same;

  /// The text way and the XML way agree.
  final bool selfCheck;

  Json toJson() => {'file': file, 'editable': editable, 'why': why, 'structural': structural, 'same': same, 'selfCheck': selfCheck};
}

/// Every scene read and "saved" with no changes in memory. Nothing is written.
class SceneCheck {
  const SceneCheck({required this.show, required this.scenes, required this.total, required this.editable, required this.bad});

  factory SceneCheck.fromJson(Json j) => SceneCheck(
    show: j.str('show'),
    scenes: j.list('scenes', SceneCheckItem.fromJson),
    total: j.integer('total'),
    editable: j.integer('editable'),
    bad: j.strList('bad'),
  );

  final String show;
  final List<SceneCheckItem> scenes;
  final int total;
  final int editable;

  /// Editable scenes that did not come back the same.
  final List<String> bad;

  Json toJson() => {
    'ok': true,
    'show': show,
    'scenes': [for (final s in scenes) s.toJson()],
    'total': total,
    'editable': editable,
    'bad': bad,
  };
}

extension SceneEditApi on SxClient {
  Future<SceneList> scenes() => get('/api/scenes', SceneList.fromJson);

  Future<SceneOpen> scene(String file) => get('/api/scene', SceneOpen.fromJson, query: {'f': file});

  Future<SceneBackups> sceneBackups(String file) => get('/api/scene/backups', SceneBackups.fromJson, query: {'f': file});

  Future<ToolResult> sceneSave(SceneChanges changes) => run('/api/scene/save', changes.toJson());

  /// Puts backup [id] back. Without [force] the answer has `conflict: true`
  /// in [ToolResult.extra] when the scene was saved again after that backup.
  Future<ToolResult> sceneRevert(String file, String id, {bool force = false}) => run('/api/scene/revert', {'f': file, 'id': id, 'force': force});
}
