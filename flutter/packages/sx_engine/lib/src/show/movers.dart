import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../ps_compat.dart';
import 'show_env.dart';
import 'text_files.dart';

// Port of the mover, reverse-heads and truss functions in `show_common.ps1`.

/// The two moving-head models SX Studio knows, by their ShowXpress profile name.
const model140 = 'Intimidator Hybrid 140SR (19ch)';
const model251 = 'IntimidatorHybrid251Sr(19ch)';

/// One moving head in the show.
class Mover {
  const Mover({required this.id, required this.name, required this.model, required this.num, required this.is140});

  /// ShowXpress's fixture id.
  final String id;
  final String name;
  final String model;

  /// The head's number within its model (140 #1, 251 #2...).
  final int num;
  final bool is140;

  String get label => is140 ? '140 #$num' : '251 #$num';
}

/// Every 140SR and 251SR in the show, 140s first, each by number.
///
/// Read from the CENTER SPOT scene's fixture list, which has all of them.
List<Mover> showMovers(ShowEnv env) {
  var cs = env.path('scenes/CENTER SPOT.scex');
  if (!File(cs).existsSync()) cs = env.path('scenes/CENTER SPOT (adjust).scex');
  if (!File(cs).existsSync()) {
    throw ToolError("Scene CENTER SPOT not found in the show - it's used to list the movers. NOTHING was changed.");
  }
  final scene = XmlDocument.parse(readText(cs)).rootElement;
  final list = <Mover>[];
  for (final f in scene.findElements('Fixtures').expand((x) => x.findElements('Fixture'))) {
    final name = f.getAttribute('name') ?? '', model = f.getAttribute('model') ?? '';
    if (!psEq(model, model140) && !psEq(model, model251)) continue;
    final hits = RegExp(r'#(\d+)').allMatches(name).toList();
    var num = hits.isEmpty ? 1 : int.parse(hits.last[1]!);
    // ShowXpress names copies of a copy "#4 #2", "#4 #2 #2": those are heads 5 and 6.
    final lower = name.toLowerCase();
    if (lower.endsWith('#4 #2 #2')) {
      num = 6;
    } else if (lower.endsWith('#4 #2')) {
      num = 5;
    }
    list.add(Mover(id: f.getAttribute('id') ?? '', name: name, model: model, num: num, is140: psEq(model, model140)));
  }
  return psSorted<Mover>(list, [(m) => m.is140 ? 0 : 1, (m) => m.num]);
}

/// Which heads SX Studio reverses (`flip_state.json`), by fixture id.
///
/// Rule: show files always hold what goes out to the heads, with reversed
/// heads already reversed. SX Studio's own maths (aims, home, RIG ID) works as
/// if every head hung normally. [sentPos] converts between the two, and it is
/// the same conversion both ways.
class FlipState {
  FlipState._(this.heads);

  factory FlipState.read(ShowEnv env) {
    final f = env.file('flip_state.json');
    final heads = <String, ({bool pan, bool tilt})>{};
    if (!f.existsSync()) return FlipState._(heads);
    final Object? j;
    try {
      j = jsonDecode(readText(f.path));
    } on FormatException {
      throw ToolError("flip_state.json in the show folder can't be read - NOTHING was changed. (It says which heads SX Studio reverses.)");
    }
    final raw = j is Map ? j['heads'] : null;
    if (raw is Map) {
      raw.forEach((id, v) {
        final pan = v is Map && _truthy(v['pan']), tilt = v is Map && _truthy(v['tilt']);
        if (pan || tilt) heads['$id'] = (pan: pan, tilt: tilt);
      });
    }
    return FlipState._(heads);
  }

  final Map<String, ({bool pan, bool tilt})> heads;

  /// [pos] is (pan, tilt), each 0..65535.
  (int, int) sentPos(String id, (int, int) pos) {
    final f = heads[id];
    if (f == null) return pos;
    return (f.pan ? 65535 - pos.$1 : pos.$1, f.tilt ? 65535 - pos.$2 : pos.$2);
  }
}

/// PowerShell's `[bool]` cast.
bool _truthy(Object? v) => switch (v) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  List l => l.isNotEmpty,
  _ => true,
};

/// A T-bar position in ShowXpress's 2D view. [x], [y] is the top-left corner
/// of the left head's icon, in pixels. The right head sits [gap] further right.
class TrussSpot {
  const TrussSpot(this.key, this.name, this.x, this.y, {this.extra = false, this.gap = 110});

  final String key;
  final String name;
  final int x;
  final int y;

  /// True for the two middle towers, which not every gig uses.
  final bool extra;
  final int gap;
}

const trussSpots = [
  TrussSpot('tl', 'Top left', 0, 0),
  TrussSpot('tr', 'Top right', 786, 0),
  TrussSpot('tm', 'Top middle', 329, 0, extra: true, gap: 266),
  TrussSpot('bl', 'Bottom left', 0, 592),
  TrussSpot('br', 'Bottom right', 786, 592),
  TrussSpot('bm', 'Bottom middle', 329, 592, extra: true, gap: 266),
];

/// Fixture name to icon position, from `Editor/2DView/fixtures.ini`.
Map<String, (int, int)>? _viewPositions(ShowEnv env) {
  final f = env.file('Editor/2DView/fixtures.ini');
  if (!f.existsSync()) return null;
  final pos = psMap<(int, int)>();
  final header = RegExp(r'^\[(.+)\]\s*$'), position = RegExp(r'^Position = (-?\d+),(-?\d+)', caseSensitive: false);
  String? sec;
  for (final l in readLines(f.path)) {
    final h = header.firstMatch(l);
    if (h != null) {
      sec = h[1]!;
      continue;
    }
    final m = position.firstMatch(l);
    if (sec != null && m != null) pos[sec] = (int.parse(m[1]!), int.parse(m[2]!));
  }
  return pos;
}

bool _near((int, int)? q, int x, int y) => q != null && (q.$1 - x).abs() <= 40 && (q.$2 - y).abs() <= 40;

/// For every head that shares a T-bar with another head of the same model:
/// the other head's id and the tower's name.
Map<String, ({String partner, String tower})> trussPartners(ShowEnv env, List<Mover> movers) {
  final r = <String, ({String partner, String tower})>{};
  final pos = _viewPositions(env);
  if (pos == null) return r;
  for (final s in trussSpots) {
    final left = movers.where((m) => _near(pos[m.name], s.x, s.y)).toList();
    final right = movers.where((m) => _near(pos[m.name], s.x + s.gap, s.y)).toList();
    if (left.length != 1 || right.length != 1 || !psEq(left[0].model, right[0].model)) continue;
    r[left[0].id] = (partner: right[0].id, tower: s.name);
    r[right[0].id] = (partner: left[0].id, tower: s.name);
  }
  return r;
}

/// Where a head sits on the truss.
typedef TrussSeat = ({String key, String tower, String side, int order});

/// For every head sitting on a T-bar spot in the 2D view: which one, which
/// side ('L' or 'R'), and its place in walking order.
Map<String, TrussSeat> trussSeats(ShowEnv env, List<Mover> movers) {
  final r = <String, TrussSeat>{};
  final pos = _viewPositions(env);
  if (pos == null) return r;
  var n = 0;
  for (final s in trussSpots) {
    for (final (side, dx) in [('L', 0), ('R', s.gap)]) {
      n++;
      final here = movers.where((m) => !r.containsKey(m.id) && _near(pos[m.name], s.x + dx, s.y)).toList();
      if (here.length == 1) r[here[0].id] = (key: s.key, tower: s.name, side: side, order: n);
    }
  }
  return r;
}
