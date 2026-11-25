import 'dart:math' as math;

import 'client.dart';
import 'json.dart';

// MOVEMENT EDITOR: ShowXpress Generator movements (`Editor/Generator/projects/*.gpj`).
// Wire types for `/api/moves`, `/api/move`, `/api/move/save`, `/api/move/backups`
// and `/api/move/revert`, plus the movement maths the screen uses to draw the
// curve and to drive the preview on the lights.
//
// Port of the wire side of `move_edit.ps1` and the Movement Editor page script.

/// The section that holds the pan/tilt shape. Every other section is a value graph.
const movePtSection = 'Pan/Tilt/uPan/uTilt';

/// Top of the 16-bit range points live in.
const moveMax = 65535;

/// One point: pan/tilt for the shape, (place in the cycle, value) for a value graph.
typedef MovePt = (int, int);

List<MovePt> _pts(Json j, String key) {
  final raw = j[key];
  final list = raw is List ? raw : (raw == null ? const [] : [raw]);
  return [
    for (final p in list)
      if (p is List && p.length == 2 && p[0] is num && p[1] is num)
        ((p[0] as num).round(), (p[1] as num).round())
      else
        throw FormatException('"$key" should be a list of [x, y] points'),
  ];
}

List<List<int>> _ptsJson(List<MovePt> pts) => [
  for (final (x, y) in pts) [x, y],
];

/// A row of the movement list (`/api/moves`).
class MoveListItem {
  const MoveListItem({
    required this.file,
    required this.name,
    required this.heads,
    required this.points,
    required this.moves,
    required this.cycle,
    required this.on,
    required this.used,
    required this.aim,
    required this.readonly,
    required this.at,
  });

  factory MoveListItem.fromJson(Json j) => MoveListItem(
    file: j.str('file'),
    name: j.str('name'),
    heads: j.integer('heads'),
    points: j.integer('points'),
    moves: j.boolean('moves'),
    cycle: j.number('cycle'),
    on: j.strList('on'),
    used: j.strList('used'),
    aim: j.str('aim'),
    readonly: j.str('readonly'),
    at: j.str('at'),
  );

  /// File name, `X.gpj`. The movement's id.
  final String file;

  /// File name without `.gpj`.
  final String name;
  final int heads;

  /// Points of the pan/tilt shape.
  final int points;

  /// True when the pan/tilt shape plays.
  final bool moves;

  /// Seconds once round the pan/tilt shape.
  final double cycle;

  /// The other channels that play.
  final List<String> on;

  /// Live buttons that play it, as "page: title".
  final List<String> used;

  /// 'floor' or 'room' when Aim Movers looks after it, else ''.
  final String aim;

  /// Why SX Studio can't change it, or '' when it can.
  final String readonly;

  /// Last written, `yyyy-MM-dd HH:mm` in the laptop's time.
  final String at;

  Json toJson() => {
    'file': file,
    'name': name,
    'heads': heads,
    'points': points,
    'moves': moves,
    'cycle': cycle,
    'on': on,
    'used': used,
    'aim': aim,
    'readonly': readonly,
    'at': at,
  };
}

/// Every movement in the show.
class MoveList {
  const MoveList({required this.show, required this.moves});

  factory MoveList.fromJson(Json j) => MoveList(show: j.str('show'), moves: j.list('moves', MoveListItem.fromJson));

  /// The show folder's name.
  final String show;
  final List<MoveListItem> moves;

  Json toJson() => {
    'ok': true,
    'show': show,
    'moves': [for (final m in moves) m.toJson()],
  };
}

/// One head (`[Fixture_N]`) of an open movement.
class MoveHead {
  const MoveHead({
    required this.k,
    required this.id,
    required this.name,
    required this.label,
    required this.model,
    required this.addr,
    required this.chans,
    required this.rp,
    required this.rt,
    required this.op,
    required this.ot,
    required this.zp,
    required this.zt,
    required this.has,
  });

  factory MoveHead.fromJson(Json j) => MoveHead(
    k: j.integer('k'),
    id: j.str('id'),
    name: j.str('name'),
    label: j.str('label'),
    model: j.str('model'),
    addr: j.integer('addr'),
    chans: j.strList('chans'),
    rp: j.integer('rp'),
    rt: j.integer('rt'),
    op: j.number('op'),
    ot: j.number('ot'),
    zp: j.number('zp'),
    zt: j.number('zt'),
    has: j.strList('has'),
  );

  /// The N of `[Fixture_N]`. Each next head runs `shift` % behind the one before.
  final int k;

  /// ShowXpress's fixture id.
  final String id;
  final String name;

  /// "140 #2" for a known mover, else the `#N` of the name.
  final String label;
  final String model;

  /// DMX start address from fixtures.ini, 0 when the head isn't patched.
  final int addr;

  /// The fixture's channel names in order (pan, upan, tilt...).
  final List<String> chans;

  /// ReversePan / ReverseTilt, 0 or 1. Set by Reverse heads, read only here.
  final int rp;
  final int rt;

  /// Aim (16-bit steps) and size (%) of the head's copy of the shape.
  final double op;
  final double ot;
  final double zp;
  final double zt;

  /// Which of OffsetPan, OffsetTilt, ZoomPan, ZoomTilt the file has.
  final List<String> has;

  /// Channel name (lowercase) to its place in [chans]. The first one wins.
  Map<String, int> get index {
    final r = <String, int>{};
    for (final (i, c) in chans.indexed) {
      final k = c.trim().toLowerCase();
      if (k.isNotEmpty) r.putIfAbsent(k, () => i);
    }
    return r;
  }

  Json toJson() => {
    'k': k,
    'id': id,
    'name': name,
    'label': label,
    'model': model,
    'addr': addr,
    'chans': chans,
    'rp': rp,
    'rt': rt,
    'op': op,
    'ot': ot,
    'zp': zp,
    'zt': zt,
    'has': has,
  };
}

/// One channel section of a movement: the pan/tilt shape or a value graph.
class MoveSection {
  const MoveSection({
    required this.name,
    required this.sel,
    required this.tr,
    required this.dur,
    required this.shift,
    required this.curve,
    required this.pts,
    required this.locked,
    required this.has,
  });

  factory MoveSection.fromJson(Json j) => MoveSection(
    name: j.str('name'),
    sel: j.integer('sel'),
    tr: j.integer('tr'),
    dur: j.number('dur'),
    shift: j.number('shift'),
    curve: j.str('curve'),
    pts: _pts(j, 'pts'),
    locked: j.boolean('locked'),
    has: j.strList('has'),
  );

  /// Section name. [movePtSection] for the shape, else the channel it drives.
  final String name;

  /// 1 when it plays (`Selected`).
  final int sel;

  /// Between points: 0 jump, 1 straight lines, 2 smooth curve.
  final int tr;

  /// Once round, in 1/10 s.
  final double dur;

  /// How far each next head runs behind, in % of the cycle.
  final double shift;
  final String curve;
  final List<MovePt> pts;

  /// True when its points are written in a way SX Studio doesn't change.
  final bool locked;

  /// Which of Selected, Transition, Duration, Shift the file has.
  final List<String> has;

  bool get isShape => name == movePtSection;

  Json toJson() => {'name': name, 'sel': sel, 'tr': tr, 'dur': dur, 'shift': shift, 'curve': curve, 'pts': _ptsJson(pts), 'locked': locked, 'has': has};
}

/// An open movement (`/api/move?f=X.gpj`).
class MoveDoc {
  const MoveDoc({
    required this.file,
    required this.name,
    required this.sha,
    required this.readonly,
    required this.aim,
    required this.used,
    required this.params,
    required this.heads,
    required this.secs,
  });

  factory MoveDoc.fromJson(Json j) => MoveDoc(
    file: j.str('file'),
    name: j.str('name'),
    sha: j.str('sha'),
    readonly: j.str('readonly'),
    aim: j.str('aim'),
    used: j.strList('used'),
    params: {for (final e in j.obj('params').entries) e.key: '${e.value ?? ''}'},
    heads: j.list('heads', MoveHead.fromJson),
    secs: j.list('secs', MoveSection.fromJson),
  );

  final String file;
  final String name;

  /// SHA-256 of the file as read. A save is refused when the file changed since.
  final String sha;

  /// Why SX Studio can't change it, or '' when it can.
  final String readonly;

  /// 'floor' or 'room' when Aim Movers looks after it (then head aim and size are read only).
  final String aim;
  final List<String> used;

  /// `[Params]`, as written.
  final Map<String, String> params;
  final List<MoveHead> heads;
  final List<MoveSection> secs;

  Json toJson() => {
    'ok': true,
    'file': file,
    'name': name,
    'sha': sha,
    'readonly': readonly,
    'aim': aim,
    'used': used,
    'params': params,
    'heads': [for (final h in heads) h.toJson()],
    'secs': [for (final s in secs) s.toJson()],
  };
}

/// A kept earlier version of a movement.
class MoveBackup {
  const MoveBackup({required this.id, required this.at, required this.what});

  factory MoveBackup.fromJson(Json j) => MoveBackup(id: j.str('id'), at: j.str('at'), what: j.str('what'));

  /// `yyyyMMdd-HHmmss-fff`, when it was kept.
  final String id;

  /// `yyyy-MM-dd HH:mm:ss`, when it was kept.
  final String at;

  /// What the save that replaced it changed.
  final String what;

  Json toJson() => {'id': id, 'at': at, 'what': what};
}

/// A movement's backups, newest first (`/api/move/backups?f=X.gpj`).
class MoveBackups {
  const MoveBackups({required this.file, required this.backups});

  factory MoveBackups.fromJson(Json j) => MoveBackups(file: j.str('file'), backups: j.list('backups', MoveBackup.fromJson));

  final String file;
  final List<MoveBackup> backups;

  Json toJson() => {
    'ok': true,
    'file': file,
    'backups': [for (final b in backups) b.toJson()],
  };
}

/// What changed in one section. A null field is left as it is.
class MoveSecChange {
  const MoveSecChange({required this.name, this.sel, this.tr, this.dur, this.shift, this.pts});

  factory MoveSecChange.fromJson(Json j) => MoveSecChange(
    name: j.str('name'),
    sel: j.integerOrNull('sel'),
    tr: j.integerOrNull('tr'),
    dur: j.integerOrNull('dur'),
    shift: j.numberOrNull('shift'),
    pts: j['pts'] == null ? null : _pts(j, 'pts'),
  );

  final String name;
  final int? sel;
  final int? tr;

  /// Once round, in 1/10 s.
  final int? dur;
  final double? shift;
  final List<MovePt>? pts;

  Json toJson() => {'name': name, 'sel': ?sel, 'tr': ?tr, 'dur': ?dur, 'shift': ?shift, if (pts != null) 'pts': _ptsJson(pts!)};
}

/// What changed in one head. A null field is left as it is.
class MoveHeadChange {
  const MoveHeadChange({required this.k, this.op, this.ot, this.zp, this.zt});

  factory MoveHeadChange.fromJson(Json j) =>
      MoveHeadChange(k: j.integer('k'), op: j.integerOrNull('op'), ot: j.integerOrNull('ot'), zp: j.integerOrNull('zp'), zt: j.integerOrNull('zt'));

  final int k;
  final int? op;
  final int? ot;
  final int? zp;
  final int? zt;

  Json toJson() => {'k': k, 'op': ?op, 'ot': ?ot, 'zp': ?zp, 'zt': ?zt};
}

/// A save: only what differs from the file as opened ([sha]).
class MoveSave {
  const MoveSave({required this.move, required this.sha, this.secs = const [], this.heads = const []});

  factory MoveSave.fromJson(Json j) =>
      MoveSave(move: j.str('move'), sha: j.str('sha'), secs: j.list('secs', MoveSecChange.fromJson), heads: j.list('heads', MoveHeadChange.fromJson));

  final String move;
  final String sha;
  final List<MoveSecChange> secs;
  final List<MoveHeadChange> heads;

  bool get isEmpty => secs.isEmpty && heads.isEmpty;

  Json toJson() => {
    'move': move,
    'sha': sha,
    'secs': [for (final s in secs) s.toJson()],
    'heads': [for (final h in heads) h.toJson()],
  };
}

extension MoveApi on SxClient {
  Future<MoveList> moves() => get('/api/moves', MoveList.fromJson);

  Future<MoveDoc> move(String file) => get('/api/move', MoveDoc.fromJson, query: {'f': file});

  Future<MoveBackups> moveBackups(String file) => get('/api/move/backups', MoveBackups.fromJson, query: {'f': file});

  Future<ToolResult> moveSave(MoveSave save) => run('/api/move/save', save.toJson());

  /// Puts backup [id] back. When the movement changed since that save the
  /// answer has `conflict: true` in `extra` and nothing changed; ask, then
  /// call again with [force].
  Future<ToolResult> moveRevert(String file, String id, {bool force = false}) => run('/api/move/revert', {'f': file, 'id': id, 'force': force});
}

// ---------------------------------------------------------------- the working copy the screen edits

/// One section as the screen has it, saved or not.
class MoveSecState {
  const MoveSecState({required this.sel, required this.tr, required this.dur, required this.shift, required this.pts});

  factory MoveSecState.of(MoveSection s) => MoveSecState(sel: s.sel != 0 ? 1 : 0, tr: s.tr, dur: s.dur, shift: s.shift, pts: s.pts);

  final int sel;
  final int tr;
  final double dur;
  final double shift;
  final List<MovePt> pts;

  MoveSecState copyWith({int? sel, int? tr, double? dur, double? shift, List<MovePt>? pts}) =>
      MoveSecState(sel: sel ?? this.sel, tr: tr ?? this.tr, dur: dur ?? this.dur, shift: shift ?? this.shift, pts: pts ?? this.pts);

  @override
  bool operator ==(Object other) =>
      other is MoveSecState && other.sel == sel && other.tr == tr && other.dur == dur && other.shift == shift && _samePts(other.pts, pts);

  @override
  int get hashCode => Object.hash(sel, tr, dur, shift, Object.hashAll(pts));
}

/// One head's aim and size as the screen has it.
class MoveHeadState {
  const MoveHeadState({required this.op, required this.ot, required this.zp, required this.zt});

  factory MoveHeadState.of(MoveHead h) => MoveHeadState(op: h.op, ot: h.ot, zp: h.zp, zt: h.zt);

  final double op;
  final double ot;
  final double zp;
  final double zt;

  double get(String p) => switch (p) {
    'op' => op,
    'ot' => ot,
    'zp' => zp,
    _ => zt,
  };

  MoveHeadState with_(String p, double v) => MoveHeadState(op: p == 'op' ? v : op, ot: p == 'ot' ? v : ot, zp: p == 'zp' ? v : zp, zt: p == 'zt' ? v : zt);

  @override
  bool operator ==(Object other) => other is MoveHeadState && other.op == op && other.ot == ot && other.zp == zp && other.zt == zt;

  @override
  int get hashCode => Object.hash(op, ot, zp, zt);
}

bool _samePts(List<MovePt> a, List<MovePt> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The whole movement as the screen has it. Immutable: an edit makes a new one,
/// so "step back" is a list of earlier states.
class MoveState {
  const MoveState(this.secs, this.heads);

  factory MoveState.of(MoveDoc d) => MoveState([for (final s in d.secs) MoveSecState.of(s)], [for (final h in d.heads) MoveHeadState.of(h)]);

  final List<MoveSecState> secs;
  final List<MoveHeadState> heads;

  MoveState withSec(int i, MoveSecState s) => MoveState([...secs]..[i] = s, heads);

  MoveState withHead(int i, MoveHeadState h) => MoveState(secs, [...heads]..[i] = h);

  /// What to send to save: only what differs from [d]. Port of `mvBody`.
  MoveSave diff(MoveDoc d) {
    final out = <MoveSecChange>[];
    for (final (i, o) in d.secs.indexed) {
      final w = secs[i];
      final c = MoveSecChange(
        name: o.name,
        sel: w.sel != (o.sel != 0 ? 1 : 0) ? w.sel : null,
        tr: w.tr != o.tr ? w.tr : null,
        dur: w.dur != o.dur ? w.dur.round() : null,
        shift: w.shift != o.shift ? w.shift : null,
        pts: !o.locked && !_samePts(w.pts, o.pts) ? w.pts : null,
      );
      if (c.sel != null || c.tr != null || c.dur != null || c.shift != null || c.pts != null) out.add(c);
    }
    final hs = <MoveHeadChange>[];
    for (final (i, o) in d.heads.indexed) {
      final w = heads[i];
      int? ch(double now, double was) => now != was ? now.round() : null;
      final c = MoveHeadChange(k: o.k, op: ch(w.op, o.op), ot: ch(w.ot, o.ot), zp: ch(w.zp, o.zp), zt: ch(w.zt, o.zt));
      if (c.op != null || c.ot != null || c.zp != null || c.zt != null) hs.add(c);
    }
    return MoveSave(move: d.file, sha: d.sha, secs: out, heads: hs);
  }

  @override
  bool operator ==(Object other) =>
      other is MoveState &&
      other.secs.length == secs.length &&
      other.heads.length == heads.length &&
      [for (var i = 0; i < secs.length; i++) other.secs[i] == secs[i]].every((x) => x) &&
      [for (var i = 0; i < heads.length; i++) other.heads[i] == heads[i]].every((x) => x);

  @override
  int get hashCode => Object.hash(Object.hashAll(secs), Object.hashAll(heads));
}

/// "Pan / Tilt" for the shape, else the section's own name. Port of `mvSecName`.
String moveSecName(String n) => n == movePtSection ? 'Pan / Tilt' : n;

/// What a save would change, in words, for the hint next to Save. Port of `mvWhat`.
String moveWhat(MoveSave b) {
  final w = <String>[];
  for (final c in b.secs) {
    final p = [
      if (c.pts != null) c.name == movePtSection ? 'shape' : 'graph',
      if (c.sel != null) c.sel != 0 ? 'turned on' : 'turned off',
      if (c.tr != null) 'transition',
      if (c.dur != null) 'cycle',
      if (c.shift != null) 'shift',
    ];
    w.add('${moveSecName(c.name)}: ${p.join(', ')}');
  }
  if (b.heads.isNotEmpty) w.add('${b.heads.length} head${b.heads.length == 1 ? '' : 's'} aimed or sized');
  return w.join(' · ');
}

// ---------------------------------------------------------------- the movement maths
//
// Worked out the way the SX Player plays a movement (`player.ps1` LoadMove and
// Eval), which the old page copied, so the drawing and the preview on the
// lights match ShowXpress. Number for number: the pin tests compare these with
// the player's own C# on every movement of the real show.

/// Tangent scale of the pan/tilt curve. Like Catmull-Rom (0.5) but 0.75: measured
/// on ShowXpress's own Art-Net output, 0.75 fits to about 10/65535, 0.5 swung about 9% short.
const movePtTension = 0.75;

/// The pan/tilt curve between [p1] and [p2]. Port of `Card` (player.ps1) and `mvCard`.
double moveCard(double p0, double p1, double p2, double p3, double t) {
  final m1 = movePtTension * (p2 - p0), m2 = movePtTension * (p3 - p1), t2 = t * t, t3 = t2 * t;
  return (2 * t3 - 3 * t2 + 1) * p1 + (t3 - 2 * t2 + t) * m1 + (-2 * t3 + 3 * t2) * p2 + (t3 - t2) * m2;
}

/// Plain Catmull-Rom, for value graphs. Port of `CR` (player.ps1) and `mvCR`.
double moveCR(double p0, double p1, double p2, double p3, double t) =>
    0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t);

double _frac(double v) => v - v.floorToDouble();

/// Where the shape is at [u] (0..1 is once round, the whole part is ignored).
/// [tr] is the section's transition. Port of `mvPathAt` and the pan/tilt part of `Eval`.
(double, double) movePathAt(List<MovePt> p, int tr, double u) {
  final n = p.length;
  if (n == 0) return (0, 0);
  final s = _frac(u) * n;
  final i = math.min(n - 1, s.floor()), t = s - i;
  if (tr == 0 || n == 1) return (p[i].$1.toDouble(), p[i].$2.toDouble());
  if (tr == 1) {
    final j = (i + 1) % n;
    return (p[i].$1 + (p[j].$1 - p[i].$1) * t, p[i].$2 + (p[j].$2 - p[i].$2) * t);
  }
  final a = (i - 1 + n) % n, b = (i + 1) % n, c = (i + 2) % n;
  return (
    moveCard(p[a].$1.toDouble(), p[i].$1.toDouble(), p[b].$1.toDouble(), p[c].$1.toDouble(), t),
    moveCard(p[a].$2.toDouble(), p[i].$2.toDouble(), p[b].$2.toDouble(), p[c].$2.toDouble(), t),
  );
}

/// A value graph's points in cycle order (ties keep file order). Port of `mvSorted`.
List<MovePt> moveSorted(List<MovePt> p) {
  final ix = [for (var i = 0; i < p.length; i++) i]..sort((a, b) => p[a].$1 != p[b].$1 ? p[a].$1.compareTo(p[b].$1) : a.compareTo(b));
  return [for (final i in ix) p[i]];
}

/// A value graph at [x] (0..65535 = once round). [s] comes from [moveSorted].
/// Port of `ValAt` (player.ps1) and `mvValAt`.
double moveValAt(List<MovePt> s, int tr, double x) {
  final n = s.length;
  if (n == 0) return 0;
  if (n == 1 || x <= s[0].$1) return s[0].$2.toDouble();
  if (x >= s[n - 1].$1) return s[n - 1].$2.toDouble();
  var j = 0;
  while (j < n - 2 && x >= s[j + 1].$1) {
    j++;
  }
  if (tr == 0) return s[j].$2.toDouble();
  final w = s[j + 1].$1 - s[j].$1;
  final t = w > 0 ? (x - s[j].$1) / w : 0.0;
  if (tr == 1) return s[j].$2 + (s[j + 1].$2 - s[j].$2) * t;
  return moveCR(s[math.max(0, j - 1)].$2.toDouble(), s[j].$2.toDouble(), s[j + 1].$2.toDouble(), s[math.min(n - 1, j + 2)].$2.toDouble(), t);
}

/// The middle of the shape's bounding box. Heads size their copy around it. Port of `mvCentre`.
(double, double) moveCentre(List<MovePt> p) {
  if (p.isEmpty) return (moveMax / 2, moveMax / 2);
  var x0 = p.first.$1, x1 = x0, y0 = p.first.$2, y1 = y0;
  for (final (x, y) in p) {
    x0 = math.min(x0, x);
    x1 = math.max(x1, x);
    y0 = math.min(y0, y);
    y1 = math.max(y1, y);
  }
  return ((x0 + x1) / 2, (y0 + y1) / 2);
}

/// A point of the shape as head [h] plays it: sized around [c], then its aim,
/// then Reverse. Port of `mvHeadXY`.
(double, double) moveHeadXY(MoveHead h, MoveHeadState w, (double, double) c, (double, double) p) {
  final zp = math.pow(1 + w.zp / 100, 2), zt = math.pow(1 + w.zt / 100, 2);
  var x = c.$1 + (p.$1 - c.$1) * zp + w.op, y = c.$2 + (p.$2 - c.$2) * zt + w.ot;
  if (h.rp != 0) x = moveMax - x;
  if (h.rt != 0) y = moveMax - y;
  return (x, y);
}

/// How far round head [k] is, [el] ms after the start (whole part = rounds done). Port of `mvPhase`.
double movePhase(MoveSecState w, int k, double el) => el / math.max(100, w.dur * 100) - k * w.shift / 100;

/// .NET `Math.Round` (halves to even), clamped to 16 bits. Port of `C16` (player.ps1).
int _c16(double v) {
  final f = v.floorToDouble(), d = v - f;
  final r = d < 0.5 ? f : (d > 0.5 ? f + 1 : (f % 2 == 0 ? f : f + 1));
  return r.clamp(0, moveMax).toInt();
}

/// DMX values of the whole movement [el] ms after it starts: 1-based channel to
/// value. Only what plays is in it, and only patched heads. Port of `mvFrame`
/// (the page) and `Eval` (player.ps1).
///
/// Rounding follows the player: halves go to the even number. The old page
/// rounded halves up, which differs by one 16-bit step at an exact half.
Map<int, int> moveFrame(MoveDoc d, MoveState s, double el) {
  final out = <int, int>{};
  final ptI = d.secs.indexWhere((x) => x.name == movePtSection);
  final pt = ptI >= 0 ? s.secs[ptI] : null;
  final c = pt == null ? null : moveCentre(pt.pts);
  for (final (hi, h) in d.heads.indexed) {
    if (h.addr == 0) continue;
    final ix = h.index;
    void put(String n, int v) {
      final i = ix[n];
      if (i == null) return;
      final ch = h.addr + i;
      if (ch >= 1 && ch <= 8192) out[ch] = v.clamp(0, 255);
    }

    if (pt != null && pt.sel != 0 && pt.pts.isNotEmpty) {
      final q = moveHeadXY(h, s.heads[hi], c!, movePathAt(pt.pts, pt.tr, movePhase(pt, h.k, el)));
      final pv = _c16(q.$1), tv = _c16(q.$2);
      put('pan', pv >> 8);
      put('upan', pv & 255);
      put('tilt', tv >> 8);
      put('utilt', tv & 255);
    }
    for (final (i, o) in d.secs.indexed) {
      final w = s.secs[i];
      if (i == ptI || w.sel == 0 || w.pts.isEmpty) continue;
      put(o.name.trim().toLowerCase(), _c16(moveValAt(moveSorted(w.pts), w.tr, _frac(movePhase(w, h.k, el)) * moveMax)) >> 8);
    }
  }
  return out;
}

/// The bounding box (x, y, size) that shows the whole shape and every head's
/// copy of it, with a margin, inside 0..65535. Port of `mvFit`.
({double x, double y, double s}) moveFit(MoveDoc d, MoveState st) {
  const whole = (x: 0.0, y: 0.0, s: 65535.0);
  final i = d.secs.indexWhere((x) => x.name == movePtSection);
  if (i < 0) return whole;
  final w = st.secs[i], c = moveCentre(w.pts), n = math.max(48, w.pts.length * 24);
  final all = <(double, double)>[];
  for (var k = 0; k < n; k++) {
    final p = movePathAt(w.pts, w.tr, k / n);
    all.add(p);
    for (final (hi, h) in d.heads.indexed) {
      all.add(moveHeadXY(h, st.heads[hi], c, p));
    }
  }
  if (all.isEmpty) return whole;
  var x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
  for (final (x, y) in all) {
    x0 = math.min(x0, x);
    x1 = math.max(x1, x);
    y0 = math.min(y0, y);
    y1 = math.max(y1, y);
  }
  final s = math.min(65535.0, math.max(6000.0, math.max((x1 - x0) * 1.3, (y1 - y0) * 1.3)));
  return (x: math.max(0.0, math.min(65535 - s, (x0 + x1) / 2 - s / 2)), y: math.max(0.0, math.min(65535 - s, (y0 + y1) / 2 - s / 2)), s: s);
}
