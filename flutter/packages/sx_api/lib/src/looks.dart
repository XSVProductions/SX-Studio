import 'client.dart';
import 'json.dart';

// ONE-CLICK LOOKS: wire types for `/api/looks` and `/api/looks/make`, and the
// templates that work out a look's steps. The templates ran in the old page
// (`lkBuild` and friends in df_aim_gui.ps1). They live here so the laptop UI,
// the phone UI and the engine's tests all build the same steps.

List<Object?> _rawList(Object? v) => v == null
    ? const []
    : v is List
    ? v
    : [v];

int _int(Object? v) => v is num ? v.round() : int.tryParse('$v') ?? 0;

List<int> _ints(Object? v) => [for (final e in _rawList(v)) _int(e)];

/// `[lo, hi]` of a DMX range, or null.
(int, int)? _range(Object? v) {
  if (v is! List || v.length < 2) return null;
  return (_int(v[0]), _int(v[1]));
}

List<int>? _rangeJson((int, int)? r) => r == null ? null : [r.$1, r.$2];

/// A head from fixtures.ini that a look can use.
class LookHead {
  const LookHead({required this.id, required this.name, required this.model, required this.addr});

  factory LookHead.fromJson(Json j) => LookHead(id: j.str('id'), name: j.str('name'), model: j.str('model'), addr: j.integer('addr'));

  final String id;
  final String name;
  final String model;

  /// DMX start address.
  final int addr;

  Json toJson() => {'id': id, 'name': name, 'model': model, 'addr': addr};
}

/// One channel of a fixture definition, named as a scene writes it (a
/// repeated name gets `#2`, `#3`...).
class LookChannel {
  const LookChannel(this.ix, this.name);

  factory LookChannel.fromJson(Json j) => LookChannel(j.integer('ix'), j.str('name'));

  final int ix;
  final String name;

  Json toJson() => {'ix': ix, 'name': name};
}

/// A fixed color-wheel slot: its name from the definition and its DMX value.
class WheelSlot {
  const WheelSlot(this.n, this.v);

  factory WheelSlot.fromJson(Json j) => WheelSlot(j.str('n'), j.integer('v'));

  final String n;
  final int v;

  Json toJson() => {'n': n, 'v': v};
}

/// The shutter channel and its open and closed values.
class Shutter {
  const Shutter(this.ix, this.open, this.closed);

  factory Shutter.fromJson(Json j) => Shutter(j.integer('ix'), j.integer('open'), j.integer('closed'));

  final int ix;
  final int open;
  final int closed;

  Json toJson() => {'ix': ix, 'open': open, 'closed': closed};
}

/// A prism channel: the value that puts it in, and its spin ranges.
class Prism {
  const Prism({required this.ix, required this.name, required this.on, this.r, this.l});

  factory Prism.fromJson(Json j) => Prism(ix: j.integer('ix'), name: j.str('name'), on: j.integer('on'), r: _range(j['r']), l: _range(j['l']));

  final int ix;
  final String name;
  final int on;

  /// Spin right and spin left, (lo, hi), or null when the prism has none.
  final (int, int)? r;
  final (int, int)? l;

  Json toJson() => {'ix': ix, 'name': name, 'on': on, 'r': _rangeJson(r), 'l': _rangeJson(l)};
}

/// The gobo rotation channel and its spin ranges.
class GoboRotate {
  const GoboRotate({required this.ix, this.r, this.l});

  factory GoboRotate.fromJson(Json j) => GoboRotate(ix: j.integer('ix'), r: _range(j['r']), l: _range(j['l']));

  final int ix;
  final (int, int)? r;
  final (int, int)? l;

  Json toJson() => {'ix': ix, 'r': _rangeJson(r), 'l': _rangeJson(l)};
}

/// What a look can use on one fixture model, from its definition. Channel
/// numbers are 0-based, and -1 means the model has no such channel.
class ModelCaps {
  const ModelCaps({
    required this.chans,
    required this.pan,
    required this.slots,
    required this.wheel,
    required this.rgb,
    required this.dim,
    required this.shut,
    required this.kill,
    required this.prisms,
    required this.grot,
    required this.gobos,
    required this.zoom,
    required this.focus,
    required this.frost,
    required this.gobo,
  });

  factory ModelCaps.fromJson(Json j) => ModelCaps(
    chans: j.list('chans', LookChannel.fromJson),
    pan: j.boolean('pan'),
    slots: j.list('slots', WheelSlot.fromJson),
    wheel: j.integer('wheel'),
    rgb: {for (final e in j.obj('rgb').entries) e.key: _ints(e.value)},
    dim: j.integer('dim'),
    shut: j.objOrNull('shut') == null ? null : Shutter.fromJson(j.obj('shut')),
    kill: [
      for (final k in _rawList(j['kill']))
        if (k is List && k.length >= 2) (_int(k[0]), _int(k[1])),
    ],
    prisms: j.list('prisms', Prism.fromJson),
    grot: j.objOrNull('grot') == null ? null : GoboRotate.fromJson(j.obj('grot')),
    gobos: _ints(j['gobos']),
    zoom: j.integer('zoom'),
    focus: j.integer('focus'),
    frost: j.integer('frost'),
    gobo: j.integer('gobo'),
  );

  final List<LookChannel> chans;

  /// True when the model has a pan channel (a moving head).
  final bool pan;

  /// Fixed color-wheel slots, up to the index / rotate part of the wheel.
  final List<WheelSlot> slots;

  /// The color wheel channel, or -1 when there is none or it has no slots.
  final int wheel;

  /// Every channel of each LED color: red, green, blue, white, amber, uv.
  final Map<String, List<int>> rgb;
  final int dim;
  final Shutter? shut;

  /// Strobe and effect channels to hold at their "off" value: (channel, value).
  final List<(int, int)> kill;
  final List<Prism> prisms;
  final GoboRotate? grot;

  /// Every gobo wheel. The prism fan sets them open.
  final List<int> gobos;
  final int zoom;
  final int focus;
  final int frost;
  final int gobo;

  Json toJson() => {
    'chans': [for (final c in chans) c.toJson()],
    'pan': pan,
    'slots': [for (final s in slots) s.toJson()],
    'wheel': wheel,
    'rgb': rgb,
    'dim': dim,
    'shut': shut?.toJson(),
    'kill': [
      for (final k in kill) [k.$1, k.$2],
    ],
    'prisms': [for (final p in prisms) p.toJson()],
    'grot': grot?.toJson(),
    'gobos': gobos,
    'zoom': zoom,
    'focus': focus,
    'frost': frost,
    'gobo': gobo,
  };
}

/// What the Looks screen works from: the show's heads and what each model can do.
class LookRig {
  const LookRig({required this.show, required this.sxOpen, required this.heads, required this.skipped, required this.models, required this.scenes});

  factory LookRig.fromJson(Json j) => LookRig(
    show: j.str('show'),
    sxOpen: j.boolean('sxOpen'),
    heads: j.list('heads', LookHead.fromJson),
    skipped: j.strList('skipped'),
    models: {for (final e in j.obj('models').entries) e.key: ModelCaps.fromJson((e.value as Map).cast<String, Object?>())},
    scenes: j.strList('scenes'),
  );

  final String show;
  final bool sxOpen;

  /// Single heads with a fixture definition, in fixtures.ini order.
  final List<LookHead> heads;

  /// Names of the fixtures a look can't use (a group of several heads, or no definition).
  final List<String> skipped;

  /// What each model can do, for every model in fixtures.ini.
  final Map<String, ModelCaps> models;

  /// File names of the scenes the show has.
  final List<String> scenes;

  Json toJson() => {
    'ok': true,
    'show': show,
    'sxOpen': sxOpen,
    'heads': [for (final h in heads) h.toJson()],
    'skipped': skipped,
    'models': {for (final e in models.entries) e.key: e.value.toJson()},
    'scenes': scenes,
  };
}

/// One step of a look as sent to the engine.
class LookStep {
  const LookStep({required this.len, required this.f});

  /// Lenient like the old tool: a step time that is not a whole number reads
  /// as null (refused), and a channel that is not a list reads as a one-item
  /// list (refused as a bad channel).
  factory LookStep.fromJson(Json j) {
    final len = j['len'];
    return LookStep(
      len: len is int
          ? len
          : len is double && len == len.truncateToDouble()
          ? len.toInt()
          : len is String
          ? int.tryParse(len.trim())
          : null,
      f: {
        for (final e in j.obj('f').entries)
          e.key: [
            for (final c in _rawList(e.value))
              [
                for (final x in _rawList(c))
                  if (x is num) x else num.tryParse('$x') ?? (throw FormatException('"f" should hold numbers, got $x')),
              ],
          ],
      },
    );
  }

  /// Step time in hundredths of a second (1 to 360000), or null when it isn't a whole number.
  final int? len;

  /// Head id to its channels, each `[index, value]` or `[index, value, fade]`
  /// where fade 1 means the channel fades into this step.
  final Map<String, List<List<num>>> f;

  Json toJson() => {'len': len, 'f': f};
}

/// A new scene to make: its file name (`X.scex`) and its steps.
class LookDraft {
  const LookDraft({required this.name, required this.steps});

  factory LookDraft.fromJson(Json j) => LookDraft(
    name: j.str('name'),
    steps: [
      for (final s in _rawList(j['steps']))
        if (s is Map) LookStep.fromJson(s.cast<String, Object?>()) else if (s != null) const LookStep(len: null, f: {}),
    ],
  );

  final String name;
  final List<LookStep> steps;

  Json toJson() => {
    'name': name,
    'steps': [for (final s in steps) s.toJson()],
  };
}

extension LooksApi on SxClient {
  Future<LookRig> looks() => get('/api/looks', LookRig.fromJson);

  Future<ToolResult> looksMake(LookDraft draft) => run('/api/looks/make', draft.toJson());
}

// ---------------------------------------------------------------- templates

/// The colors a look can use, by name, and about how they look.
const lookColors = [
  ('White', 'ffffff'),
  ('Red', 'ff0000'),
  ('Orange', 'ff7a00'),
  ('Amber', 'ffb000'),
  ('Yellow', 'ffe600'),
  ('Green', '00e040'),
  ('Cyan', '00e5ff'),
  ('Blue', '0030ff'),
  ('Purple', '8a2be2'),
  ('Magenta', 'ff00c8'),
  ('Pink', 'ff6fae'),
  ('UV', '6a00ff'),
];

/// Color-wheel slot names from the fixtures' own definitions, and about how they look.
const _slotHex = {
  'white': 'ffffff',
  'red': 'ff0000',
  'orange': 'ff7a00',
  'yellow': 'ffe600',
  'dark_yellow': 'd4a000',
  'amber': 'ffb000',
  'green': '00e040',
  'light_green': '80ff80',
  'pastel_sky_blue': '80d0ff',
  'sky_blue': '80d0ff',
  'light_blue': '80d0ff',
  'cyan': '00e5ff',
  'blue': '0030ff',
  'dark_blue': '0010a0',
  'purple': '8a2be2',
  'magenta': 'ff00c8',
  'pink': 'ff6fae',
  'lavender': 'c0a0ff',
  'uv': '6a00ff',
  'cto': 'ffb070',
  'natural_white': 'fff0dc',
  'cold_white': 'e6f2ff',
  'warm_white': 'ffe0b0',
};

/// How a prism lit by the prism fan is drawn.
const prismHex = 'e8ecff';

String lookColorHex(String name) => lookColors.firstWhere((c) => c.$1 == name, orElse: () => lookColors.first).$2;

List<int> _rgb(String hex) => [for (var i = 0; i < 6; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

/// JavaScript's `Math.round`: halves go up.
int _jsRound(num v) => (v + 0.5).floor();

int _byte(num? v) => _jsRound(v ?? 0).clamp(0, 255);

enum LookTemplate {
  contrast('Contrast pairs', 'Two colours side by side, swapping'),
  chase('Colour chase', 'One colour after another, back and forth'),
  strobe('Strobe', 'One flash each beat, or a steady strobe'),
  prism('Prism fan', 'Spinning prisms, no colour of its own');

  const LookTemplate(this.title, this.blurb);

  final String title;
  final String blurb;
}

/// How the contrast template splits the heads between the two colors.
enum ContrastSplit {
  alt('Every other head'),
  half('First half / second half'),
  type('Movers / the other lights');

  const ContrastSplit(this.label);

  final String label;
}

/// What a prism does in the prism fan.
enum PrismMode {
  off('Off'),
  still('In, still'),
  l('Spin left'),
  r('Spin right');

  const PrismMode(this.label);

  final String label;
}

/// One prism's setting in the prism fan. [s] is the spin speed, 0 to 100.
class PrismSetting {
  PrismSetting(this.m, this.s);

  PrismMode m;
  num s;
}

/// Every template's settings, as the user left them. A null time means the
/// box was left empty, which counts as 1 second.
class LookOptions {
  LookOptions();

  /// Settings kept from last time, in the old page's `sxh_looks` shape: per
  /// template only the keys saved replace the defaults (the old `Object.assign`),
  /// and a value of the wrong kind is ignored.
  factory LookOptions.fromJson(Json j) {
    final o = LookOptions();
    Json part(String k) => j[k] is Map ? (j[k]! as Map).cast<String, Object?>() : const {};
    num? time(Object? v, num? d) => v is num ? v : (v == '' ? null : d);
    bool flag(Object? v, bool d) => v is bool ? v : d;
    List<String>? names(Object? v) => v is List ? [for (final x in v) '$x'] : null;

    final c = part('contrast');
    if (c['pairs'] case final List ps) {
      o.pairs
        ..clear()
        ..addAll([
          for (final p in ps)
            if (p is List && p.length == 2) ('${p[0]}', '${p[1]}'),
        ]);
    }
    o.split = ContrastSplit.values.asNameMap()[c['split']] ?? o.split;
    o.swap = flag(c['swap'], o.swap);
    o.hold = time(c['hold'], o.hold);
    o.fade = flag(c['fade'], o.fade);

    final ch = part('chase');
    if (names(ch['cols']) case final cols?) {
      o.cols
        ..clear()
        ..addAll(cols);
    }
    o.pingPong = flag(ch['pp'], o.pingPong);
    o.spread = flag(ch['spread'], o.spread);
    o.chaseHold = time(ch['hold'], o.chaseHold);
    o.chaseFade = flag(ch['fade'], o.chaseFade);

    final st = part('strobe');
    if (st['col'] is String) o.strobeColor = st['col']! as String;
    if (st['mode'] case 'beat' || 'steady') o.beat = st['mode'] == 'beat';
    o.strobeOn = time(st['on'], o.strobeOn);
    o.strobeOff = time(st['off'], o.strobeOff);

    final pr = part('prism');
    if (pr['p'] case final List ps) {
      o.prisms
        ..clear()
        ..addAll([
          for (final p in ps.whereType<Map>()) PrismSetting(PrismMode.values.asNameMap()[p['m']] ?? PrismMode.off, p['s'] is num ? p['s']! as num : 50),
        ]);
    }
    if (pr['zoom'] is num) o.zoom = pr['zoom']! as num;
    if (pr['focus'] is num) o.focus = pr['focus']! as num;

    final on = part('on');
    for (final t in LookTemplate.values) {
      if (on[t.name] case final Map m) {
        o.on[t]!.addAll({
          for (final e in m.entries)
            if (e.value is bool) '${e.key}': e.value as bool,
        });
      }
    }
    return o;
  }

  // contrast
  final pairs = [('Red', 'Blue'), ('Green', 'Magenta'), ('Yellow', 'Purple'), ('Cyan', 'Pink')];
  var split = ContrastSplit.alt;
  var swap = true;
  num? hold = 1;
  var fade = false;

  // chase
  final cols = [...rainbow];
  var pingPong = true;
  var spread = false;
  num? chaseHold = 0.5;
  var chaseFade = false;

  // strobe
  var strobeColor = 'White';
  var beat = true;
  num? strobeOn = 0.05;
  num? strobeOff = 0.05;

  // prism
  final prisms = [PrismSetting(PrismMode.l, 77), PrismSetting(PrismMode.l, 29)];
  num zoom = 80;
  num focus = 128;

  /// Per template, models the user turned on or off. Models not in here use [lookDefaultOn].
  final on = {for (final t in LookTemplate.values) t: <String, bool>{}};

  static const rainbow = ['Red', 'Orange', 'Yellow', 'Green', 'Cyan', 'Blue', 'Purple', 'Magenta'];

  /// The old page's `sxh_looks`: an empty time box is `''`.
  Json toJson() => {
    'on': {
      for (final MapEntry(:key, :value) in on.entries)
        if (value.isNotEmpty) key.name: value,
    },
    'contrast': {
      'pairs': [
        for (final p in pairs) [p.$1, p.$2],
      ],
      'split': split.name,
      'swap': swap,
      'hold': hold ?? '',
      'fade': fade,
    },
    'chase': {'cols': cols, 'pp': pingPong, 'spread': spread, 'hold': chaseHold ?? '', 'fade': chaseFade},
    'strobe': {'col': strobeColor, 'mode': beat ? 'beat' : 'steady', 'on': strobeOn ?? '', 'off': strobeOff ?? ''},
    'prism': {
      'p': [
        for (final p in prisms) {'m': p.m.name, 's': p.s},
      ],
      'zoom': zoom,
      'focus': focus,
    },
  };
}

/// The heads of one model, as the screen groups them.
class LookGroup {
  LookGroup(this.model, this.caps, this.heads);

  final String model;
  final ModelCaps? caps;
  final List<LookHead> heads;

  /// "Intimidator Hybrid 140SR (19ch)" becomes "Intimidator Hybrid 140SR".
  String get label {
    final s = model
        .replaceFirst(RegExp(r'\s*\(\d+\s*ch\)\s*$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'_?CH\d+$', caseSensitive: false), '')
        .replaceAll('_', ' ')
        .trim();
    return s.isEmpty ? model : s;
  }
}

/// The rig's heads grouped by model, in fixtures.ini order.
List<LookGroup> lookGroups(LookRig rig) {
  final groups = <String, LookGroup>{};
  for (final h in rig.heads) {
    groups.putIfAbsent(h.model, () => LookGroup(h.model, rig.models[h.model], [])).heads.add(h);
  }
  return groups.values.toList();
}

bool _hasRgb(ModelCaps c) => ['red', 'green', 'blue', 'white'].any((k) => (c.rgb[k] ?? const []).isNotEmpty);

/// Whether template [t] can use lights of this kind at all.
bool lookCan(ModelCaps? c, LookTemplate t) => c != null && (t == LookTemplate.prism ? c.prisms.isNotEmpty : c.wheel >= 0 || _hasRgb(c));

/// Whether a group starts picked. The user's beat strobe left the Ovation
/// out, and the color looks leave out the Ovation and the blinders too.
bool lookDefaultOn(String model, LookTemplate t) =>
    t == LookTemplate.prism || !RegExp(t == LookTemplate.strobe ? 'ovation' : 'ovation|oppsk|blinder', caseSensitive: false).hasMatch(model);

bool lookGroupOn(LookOptions o, LookGroup g, LookTemplate t) => lookCan(g.caps, t) && (o.on[t]![g.model] ?? lookDefaultOn(g.model, t));

/// One head in a look, with its place in its group.
typedef _LookHead = ({LookHead h, ModelCaps c, int gi, int n});

/// What one head does in one step: its channels `[index, value, fade]` and the
/// color it shows ('rrggbb'), or null when it is dark.
typedef _HeadStep = ({List<List<int>> ch, String? hex});

/// One step of a built look.
class BuiltStep {
  BuiltStep(this.len);

  final int len;
  final f = <String, List<List<int>>>{};

  /// Head id to the color it shows in this step, or null when dark.
  final show = <String, String?>{};
}

/// A look worked out from a template, or the reason it can't be ([err]).
class BuiltLook {
  BuiltLook(this.steps, {this.err = '', this.beat = false, this.prism = false});

  final List<BuiltStep> steps;
  final String err;

  /// One flash, then dark until the next beat.
  final bool beat;
  final bool prism;

  /// Total time of one round in seconds.
  double get seconds => steps.fold(0, (a, s) => a + s.len) / 100;

  LookDraft draft(String fileName) => LookDraft(
    name: fileName,
    steps: [for (final s in steps) LookStep(len: s.len, f: s.f)],
  );
}

/// The nearest slot of a color wheel to the color called [name].
({int v, String hex}) _wheelSlot(ModelCaps c, String name) {
  final n = name.toLowerCase(), w = _rgb(lookColorHex(name));
  ({int v, String hex})? best;
  var bd = 1e9;
  for (final s in c.slots) {
    final k = s.n.toLowerCase().replaceAll(RegExp(r'\s+'), '_'), hx = _slotHex[k];
    if (hx == null) continue;
    if (k == n) return (v: s.v, hex: hx);
    final q = _rgb(hx);
    final d = (q[0] - w[0]) * (q[0] - w[0]) + (q[1] - w[1]) * (q[1] - w[1]) + (q[2] - w[2]) * (q[2] - w[2]);
    if (d < bd) {
      bd = d.toDouble();
      best = (v: s.v, hex: hx);
    }
  }
  return best ?? (v: c.slots[0].v, hex: 'ffffff');
}

/// The color called [name] on LED channels: channel to value, ascending.
Map<int, int> _ledColor(ModelCaps c, String name) {
  bool has(String k) => (c.rgb[k] ?? const []).isNotEmpty;
  var [r, g, b] = _rgb(lookColorHex(name));
  var w = 0, a = 0, u = 0;
  if (name == 'White' && has('white')) {
    r = g = b = 0;
    w = 255;
  } else if (name == 'Amber' && has('amber')) {
    r = g = b = 0;
    a = 255;
  } else if (name == 'UV' && has('uv')) {
    r = g = b = 0;
    u = 255;
  }
  final o = <int, int>{};
  for (final (k, v) in [('red', r), ('green', g), ('blue', b), ('white', w), ('amber', a), ('uv', u)]) {
    for (final ix in c.rgb[k] ?? const <int>[]) {
      o[ix] = v;
    }
  }
  return Map.fromEntries(o.entries.toList()..sort((x, y) => x.key.compareTo(y.key)));
}

/// A color on one head: the nearest wheel slot, or the LED mix. Sets only the
/// color, dimmer and shutter, and holds the built-in strobe and effect
/// programs off.
_HeadStep _colorChannels(ModelCaps c, String name, {required bool on, required bool fade}) {
  final out = <List<int>>[];
  final f = fade ? 1 : 0;
  var hex = lookColorHex(name);
  if (c.wheel >= 0) {
    final s = _wheelSlot(c, name);
    out.add([c.wheel, s.v, 0]); // a wheel never fades (it would spin through the slots)
    hex = s.hex;
  } else {
    for (final e in _ledColor(c, name).entries) {
      out.add([e.key, on || c.dim >= 0 ? e.value : 0, f]);
    }
  }
  if (c.dim >= 0) out.add([c.dim, on ? 255 : 0, c.wheel < 0 ? f : 0]);
  final sh = c.shut;
  if (sh != null) out.add([sh.ix, on ? sh.open : sh.closed, 0]);
  for (final k in c.kill) {
    if (!out.any((x) => x[0] == k.$1)) out.add([k.$1, k.$2, 0]);
  }
  return (ch: out, hex: on ? hex : null);
}

/// The prism fan on one head: gobos open, prisms in or spinning, zoom and
/// focus, frost off, lit. No color of its own.
_HeadStep _prismChannels(ModelCaps c, LookOptions o) {
  final out = <List<int>>[
    for (final ix in c.gobos) [ix, 0, 0],
  ];
  for (final (j, p) in c.prisms.indexed) {
    final q = o.prisms.isEmpty ? PrismSetting(PrismMode.off, 0) : o.prisms[j < o.prisms.length ? j : o.prisms.length - 1];
    var v = 0;
    if (q.m == PrismMode.still) {
      v = p.on;
    } else if (q.m == PrismMode.l || q.m == PrismMode.r) {
      final r = q.m == PrismMode.l ? p.l : p.r;
      v = r == null ? p.on : _jsRound(r.$1 + (r.$2 - r.$1) * q.s.clamp(0, 100) / 100);
    }
    out.add([p.ix, v, 0]);
  }
  if (c.focus >= 0) out.add([c.focus, _byte(o.focus), 0]);
  if (c.zoom >= 0) out.add([c.zoom, _byte(o.zoom), 0]);
  if (c.frost >= 0 && !out.any((x) => x[0] == c.frost)) out.add([c.frost, 0, 0]);
  if (c.dim >= 0) out.add([c.dim, 255, 0]);
  final sh = c.shut;
  if (sh != null) out.add([sh.ix, sh.open, 0]);
  return (ch: out, hex: prismHex);
}

/// Seconds to hundredths. Empty counts as 1 s, and 0.01 s to 1 hour is the range.
int _hold(num? v) => _jsRound(((v == null || v == 0) ? 1 : v).clamp(0.01, 3600) * 100);

/// Works out the steps of template [t] for the heads picked in [o].
///
/// Each look sets only what it is about (a color look: color, dimmer and
/// shutter; the prism fan: the beam), so looks can be played together, like
/// the user's own CONTRAST ALL + PRISM FAN.
///
/// Port of `lkBuild` in the old page.
BuiltLook buildLook(LookRig rig, LookTemplate t, LookOptions o) {
  final hs = <_LookHead>[
    for (final g in lookGroups(rig))
      if (lookGroupOn(o, g, t))
        for (final (i, h) in g.heads.indexed) (h: h, c: g.caps!, gi: i, n: g.heads.length),
  ];
  final steps = <BuiltStep>[];
  if (hs.isEmpty) return BuiltLook(steps, err: 'Pick the lights for the look (HEADS).');
  void st(num len, _HeadStep Function(_LookHead x) fn) {
    final s = BuiltStep(_jsRound(len).clamp(1, 360000));
    for (final x in hs) {
      final r = fn(x);
      s.f[x.h.id] = r.ch;
      s.show[x.h.id] = r.hex;
    }
    steps.add(s);
  }

  switch (t) {
    case LookTemplate.contrast:
      final ps = o.pairs.where((p) => p.$1.isNotEmpty && p.$2.isNotEmpty).toList();
      if (ps.isEmpty) return BuiltLook(steps, err: 'Add a pair of colours.');
      int side(_LookHead x) => switch (o.split) {
        ContrastSplit.half => x.gi < (x.n / 2).ceil() ? 0 : 1,
        ContrastSplit.type => x.c.pan ? 0 : 1,
        ContrastSplit.alt => x.gi % 2,
      };
      for (final p in ps) {
        for (final sw in o.swap ? const [0, 1] : const [0]) {
          st(_hold(o.hold), (x) => _colorChannels(x.c, (side(x) + sw) % 2 == 0 ? p.$1 : p.$2, on: true, fade: o.fade));
        }
      }
    case LookTemplate.chase:
      final cs = o.cols.where((c) => c.isNotEmpty).toList();
      if (cs.length < 2) return BuiltLook(steps, err: 'Pick at least 2 colours.');
      // 1..n..2: no jump from the last color back to the first
      final seq = [for (var i = 0; i < cs.length; i++) i];
      if (o.pingPong && cs.length > 2) {
        for (var i = cs.length - 2; i > 0; i--) {
          seq.add(i);
        }
      }
      for (var k = 0; k < seq.length; k++) {
        st(_hold(o.chaseHold), (x) => _colorChannels(x.c, cs[seq[(k + (o.spread ? x.gi : 0)) % seq.length]], on: true, fade: o.chaseFade));
      }
    case LookTemplate.strobe:
      final cn = o.strobeColor.isEmpty ? 'White' : o.strobeColor;
      if (o.beat) {
        // like the user's BEAT STROBE WHITE
        st(8, (x) => _colorChannels(x.c, cn, on: true, fade: false));
        st(6000, (x) => _colorChannels(x.c, cn, on: false, fade: false));
      } else {
        st(_hold(o.strobeOn), (x) => _colorChannels(x.c, cn, on: true, fade: false));
        st(_hold(o.strobeOff), (x) => _colorChannels(x.c, cn, on: false, fade: false));
      }
    case LookTemplate.prism:
      st(500, (x) => _prismChannels(x.c, o));
  }
  return BuiltLook(steps, beat: t == LookTemplate.strobe && o.beat, prism: t == LookTemplate.prism);
}

/// The name a new look gets until the user types one, made unique among [scenes].
String lookAutoName(LookTemplate t, LookOptions o, List<String> scenes) {
  final b = switch (t) {
    LookTemplate.contrast => () {
      final p = o.pairs.where((x) => x.$1.isNotEmpty && x.$2.isNotEmpty).toList();
      return p.length == 1 ? 'CONTRAST ${p[0].$1.toUpperCase()} ${p[0].$2.toUpperCase()}' : 'CONTRAST PAIRS';
    }(),
    LookTemplate.chase => o.spread ? 'RAINBOW COLOR CHASE' : 'COLOR CHASE',
    LookTemplate.strobe => '${(o.strobeColor.isEmpty ? 'White' : o.strobeColor).toUpperCase()}${o.beat ? ' BEAT STROBE' : ' STROBE'}',
    LookTemplate.prism => 'PRISM FAN',
  };
  var n = b, i = 2;
  while (lookNameTaken(n, scenes)) {
    n = '$b ${i++}';
  }
  return n;
}

/// True when the show already has a scene called [name] (without `.scex`), in any capitals.
bool lookNameTaken(String name, List<String> scenes) => scenes.any((s) => s.toLowerCase() == '$name.scex'.toLowerCase());

/// What the user typed, made into a scene name (without `.scex`): no
/// characters a file name can't have, single spaces, at most 100 characters.
String lookCleanName(String typed) {
  var s = typed.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceFirst(RegExp(r'\.scex$', caseSensitive: false), '').replaceFirst(RegExp(r'[. ]+$'), '');
  return s.length > 100 ? s.substring(0, 100) : s;
}
