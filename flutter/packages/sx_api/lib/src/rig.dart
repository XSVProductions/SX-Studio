import 'client.dart';
import 'json.dart';

/// One moving head on the Tonight's Rig screen.
class RigHead {
  const RigHead({required this.id, required this.label, required this.num, required this.is140, required this.on, required this.rp, required this.rt});

  factory RigHead.fromJson(Json j) => RigHead(
    id: j.str('id'),
    label: j.str('label'),
    num: j.integer('num'),
    is140: j.boolean('is140'),
    on: j.boolean('on'),
    rp: j.boolean('rp'),
    rt: j.boolean('rt'),
  );

  /// ShowXpress's fixture id.
  final String id;

  /// "140 #4", "251 #2".
  final String label;
  final int num;
  final bool is140;

  /// True when the head is hung tonight (as last saved).
  final bool on;

  /// True when SX Studio reverses this head's pan (`flip_state.json`).
  final bool rp;

  /// True when SX Studio reverses this head's tilt.
  final bool rt;

  Json toJson() => {'id': id, 'label': label, 'num': num, 'is140': is140, 'on': on, 'rp': rp, 'rt': rt};
}

/// One step of a chase scene: how long it lasts and what it lights.
class RigStep {
  const RigStep({required this.cs, required this.lit, required this.other});

  factory RigStep.fromJson(Json j) => RigStep(cs: j.integer('cs'), lit: j.strList('lit'), other: j.boolean('other'));

  /// Length in hundredths of a second.
  final int cs;

  /// Ids of the movers lit in this step.
  final List<String> lit;

  /// True when a blinder or uplight is lit in this step.
  final bool other;

  Json toJson() => {'cs': cs, 'lit': lit, 'other': other};
}

/// A chase scene Tonight's Rig can trim.
class RigScene {
  const RigScene({
    required this.file,
    required this.name,
    required this.titles,
    required this.trimmed,
    required this.edited,
    required this.groups,
    required this.steps,
  });

  factory RigScene.fromJson(Json j) => RigScene(
    file: j.str('file'),
    name: j.str('name'),
    titles: j.strList('titles'),
    trimmed: j.boolean('trimmed'),
    edited: j.boolean('edited'),
    groups: _groups(j['groups']),
    steps: j.list('steps', RigStep.fromJson),
  );

  /// File name in `scenes/`, for example `CHASE.scex`.
  final String file;
  final String name;

  /// Titles of the live buttons that play it.
  final List<String> titles;

  /// True when the scene in the show is the trimmed version saved last time.
  final bool trimmed;

  /// True when the trimmed scene was changed in ShowXpress since, so that
  /// version now counts as the full scene.
  final bool edited;

  /// Step indexes that come and go together: a lit step plus the dark steps
  /// after it. Empty when the scene has fewer than two lit steps.
  final List<List<int>> groups;
  final List<RigStep> steps;

  /// Which steps go for this set of hung heads, or null when every group
  /// would go (the scene is then left complete). Same rule as `rig.ps1`.
  Set<int>? dropFor(Set<String> hung) {
    final drop = <int>{};
    var kept = 0;
    for (final g in groups) {
      final s = steps[g.first];
      if (!s.other && s.lit.isNotEmpty && !s.lit.any(hung.contains)) {
        drop.addAll(g);
      } else {
        kept++;
      }
    }
    return groups.isNotEmpty && kept == 0 ? null : drop;
  }

  Json toJson() => {
    'file': file,
    'name': name,
    'titles': titles,
    'trimmed': trimmed,
    'edited': edited,
    'groups': groups,
    'steps': [for (final s in steps) s.toJson()],
  };
}

List<List<int>> _groups(Object? v) => [
  if (v is List)
    for (final g in v)
      [
        if (g is List)
          for (final i in g)
            if (i is num) i.round(),
        if (g is num) g.round(),
      ],
];

/// What the Tonight's Rig screen shows.
class RigPreview {
  const RigPreview({required this.show, required this.heads, required this.scenes});

  factory RigPreview.fromJson(Json j) => RigPreview(show: j.str('show'), heads: j.list('heads', RigHead.fromJson), scenes: j.list('scenes', RigScene.fromJson));

  final String show;
  final List<RigHead> heads;
  final List<RigScene> scenes;

  Json toJson() => {
    'ok': true,
    'show': show,
    'heads': [for (final h in heads) h.toJson()],
    'scenes': [for (final s in scenes) s.toJson()],
  };
}

/// Which axes SX Studio reverses on one head.
typedef Flip = ({bool pan, bool tilt});

/// One head as the Reverse Heads tool (`flip.ps1`) lists it.
class FlipHead {
  const FlipHead({required this.id, required this.label, required this.is140, required this.pan, required this.tilt});

  factory FlipHead.fromJson(Json j) =>
      FlipHead(id: j.str('id'), label: j.str('label'), is140: j.boolean('is140'), pan: j.boolean('pan'), tilt: j.boolean('tilt'));

  final String id;
  final String label;
  final bool is140;
  final bool pan;
  final bool tilt;

  Json toJson() => {'id': id, 'label': label, 'is140': is140, 'pan': pan, 'tilt': tilt};
}

/// Every head and which axes are reversed now. The Rig screen gets the same
/// facts through [RigHead.rp] and [RigHead.rt].
class FlipPreview {
  const FlipPreview({required this.show, required this.heads});

  factory FlipPreview.fromJson(Json j) => FlipPreview(show: j.str('show'), heads: j.list('heads', FlipHead.fromJson));

  final String show;
  final List<FlipHead> heads;

  Json toJson() => {
    'ok': true,
    'show': show,
    'heads': [for (final h in heads) h.toJson()],
  };
}

extension RigApi on SxClient {
  Future<RigPreview> rig() => get('/api/rig', RigPreview.fromJson);

  /// Saves tonight's hung heads and the full list of reversed heads. A head
  /// left out of [flip] goes back to normal.
  Future<ToolResult> rigApply(List<String> heads, Map<String, Flip> flip) => run('/api/rig/apply', {
    'heads': heads,
    'flip': {
      for (final e in flip.entries)
        if (e.value.pan || e.value.tilt) e.key: {'pan': e.value.pan, 'tilt': e.value.tilt},
    },
  });
}
