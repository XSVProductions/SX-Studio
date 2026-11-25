import 'package:sx_api/sx_api.dart';

// The Scene Editor's working copy of a scene: the steps as the user has them
// now. A save sends only what differs from the file.
//
// Port of the Scene Editor script in `df_aim_gui.ps1` (`SW`, `seBody`,
// `seDirty`, `seWhat`, `seLit`, `seVals`, `seFrame` and the step and channel
// actions).

/// `head id|channel index`, the key of one channel of one head.
String chKey(String fx, int ix) => '$fx|$ix';

/// A channel's value and fade in the working copy.
class ChVal {
  ChVal(this.v, this.fade);

  int v;
  bool fade;
}

/// One step of the working copy: a copy of file step [src], with its own
/// length and values.
class WorkStep {
  WorkStep(this.src, this.len, this.ch);

  final int src;
  int? len;

  /// Channel key to value. A key that is missing is not in this step.
  final Map<String, ChVal> ch;

  /// Hundredths of a second. A step without a length plays for one second.
  int get cs => len ?? 100;
}

/// The channels of the picked heads at one index, in one step.
class ChRow {
  ChRow(this.ix, this.keys);

  final int ix;
  final List<String> keys;
}

/// Seconds for hundredths, the old page's `seSec`: 50 is "0.5", 125 is "1.25".
String stepSeconds(int cs) {
  final s = (cs / 100).toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

/// JavaScript's `Math.round`: halves go up.
int jsRound(double v) => (v + .5).floor();

/// The working copy of an opened scene.
class SceneWork {
  SceneWork(this.scene) : heads = scene.heads ?? const [], file = scene.steps ?? const [] {
    for (final h in heads) {
      byId[h.id] = h;
    }
    for (final s in file) {
      final m = <String, SceneChannel>{};
      for (final f in s.fx) {
        for (final c in f.ch) {
          m[chKey(f.id, c.ix)] = c;
        }
      }
      maps.add(m);
      ids.add({for (final f in s.fx) f.id});
    }
    reset();
  }

  final SceneOpen scene;
  final List<SceneHead> heads;

  /// The steps as they are in the file.
  final List<SceneEditStep> file;
  final byId = <String, SceneHead>{};

  /// Per file step: channel key to the channel as found.
  final maps = <Map<String, SceneChannel>>[];

  /// Per file step: the heads it has.
  final ids = <Set<String>>[];

  var steps = <WorkStep>[];
  var add = <SceneChannelRef>[];
  var del = <SceneChannelRef>[];

  /// Goes up on every change, so drawings and the preview know to redo their work.
  var ver = 0;

  bool get readonly => scene.readonly.isNotEmpty;

  /// Back to the file as it is.
  void reset() {
    steps = readonly ? [] : [for (var i = 0; i < file.length; i++) fromFile(i)];
    add = [];
    del = [];
    ver++;
  }

  WorkStep fromFile(int i) => WorkStep(i, file[i].len, {for (final e in maps[i].entries) e.key: ChVal(e.value.v, e.value.fade)});

  /// The change file for a save: only what differs from the file.
  SceneChanges body() => SceneChanges(
    scene: scene.file,
    sha: scene.sha,
    steps: [
      for (final w in steps)
        () {
          final o = maps[w.src];
          final set = <SceneSet>[];
          for (final e in w.ch.entries) {
            final bar = e.key.lastIndexOf('|');
            final fx = e.key.substring(0, bar), ix = int.parse(e.key.substring(bar + 1));
            final c = o[e.key], v = e.value;
            if (c == null) {
              if (v.v != 0 || v.fade) set.add(SceneSet(fx: fx, ix: ix, v: v.v, fade: v.fade));
              continue;
            }
            final nv = v.v != c.v ? v.v : null, nf = v.fade != c.fade ? v.fade : null;
            if (nv != null || nf != null) set.add(SceneSet(fx: fx, ix: ix, v: nv, fade: nf));
          }
          return SceneStepChange(src: w.src, len: w.len != file[w.src].len ? w.len : null, set: set);
        }(),
    ],
    addch: [...add],
    delch: [...del],
  );

  bool get dirty {
    if (readonly) return false;
    final b = body();
    if (b.addch.isNotEmpty || b.delch.isNotEmpty || b.steps.length != file.length) return true;
    for (final (i, s) in b.steps.indexed) {
      if (s.src != i || s.set.isNotEmpty || s.len != null) return true;
    }
    return false;
  }

  /// What a save would change, in words.
  String what() {
    final b = body();
    var v = 0, l = 0;
    for (final s in b.steps) {
      v += s.set.length;
      if (s.len != null) l++;
    }
    String n(int k, String one) => '$k $one${k == 1 ? '' : 's'}';
    return [
      if (b.steps.length != file.length) '${file.length} to ${b.steps.length} steps' else if (b.steps.indexed.any((e) => e.$2.src != e.$1)) 'steps moved',
      if (v > 0) n(v, 'value'),
      if (l > 0) n(l, 'step time'),
      if (b.addch.isNotEmpty) '${n(b.addch.length, 'channel')} added',
      if (b.delch.isNotEmpty) '${b.delch.length} taken out',
    ].join(', ');
  }

  /// True when step [i] of the working copy differs from the file step it copies.
  bool stepChanged(int i) {
    final w = steps[i], o = maps[w.src];
    if (w.len != file[w.src].len) return true;
    for (final e in w.ch.entries) {
      final c = o[e.key];
      if (c == null ? (e.value.v != 0 || e.value.fade) : (c.v != e.value.v || c.fade != e.value.fade)) return true;
    }
    return false;
  }

  /// True when step [i] is a second copy of a file step (drawn dashed).
  bool isCopy(int i) => steps.take(i).any((w) => w.src == steps[i].src);

  bool inStep(WorkStep w, String id) => ids[w.src].contains(id);

  // ---- lit or dark (same rule as Tonight's Rig: dimmer above 0 and the shutter not closed; no dimmer = any channel above 0)

  bool closed(String model, int v) => (scene.models?[model]?.ranges['shutter'] ?? const []).any((x) => x.n == 'closed' && v >= x.lo && v <= x.hi);

  /// The channel's name: as the show's scenes name it for the model, or as
  /// this scene does, or "channel N".
  String chName(String model, int ix, String key) {
    for (final c in scene.models?[model]?.chans ?? const <SceneChannelName>[]) {
      if (c.ix == ix) return c.name;
    }
    for (final m in maps) {
      final c = m[key];
      if (c != null) return c.name;
    }
    return 'channel ${ix + 1}';
  }

  bool lit(WorkStep w, SceneHead h) {
    int? dim, sh;
    var any = false;
    for (final e in w.ch.entries) {
      if (!e.key.startsWith('${h.id}|')) continue;
      final ix = int.parse(e.key.substring(h.id.length + 1));
      final n = chName(h.model, ix, e.key).toLowerCase(), v = e.value.v;
      if (n == 'dimmer') {
        dim = v;
      } else if (n == 'shutter') {
        sh = v;
      }
      if (v > 0) any = true;
    }
    if (dim == null) return any;
    return dim > 0 && !(sh != null && closed(h.model, sh));
  }

  /// The channels of heads [sel] in step [i], by index.
  List<ChRow> rows(int i, Iterable<String> sel) {
    if (i < 0 || i >= steps.length) return [];
    final w = steps[i], r = <int, ChRow>{};
    for (final id in sel) {
      for (final k in w.ch.keys) {
        if (!k.startsWith('$id|')) continue;
        final ix = int.parse(k.substring(id.length + 1));
        r.putIfAbsent(ix, () => ChRow(ix, [])).keys.add(k);
      }
    }
    return r.values.toList()..sort((a, b) => a.ix.compareTo(b.ix));
  }

  /// True when the file's value of [key] in step [i] is not a plain number,
  /// so the editor doesn't change it.
  bool fixedValue(int i, String key) => (maps[steps[i].src][key]?.v ?? 0) < 0;

  // ---- actions

  void setValue(int i, Iterable<String> keys, int v) {
    for (final k in keys) {
      steps[i].ch[k]?.v = v.clamp(0, 255);
    }
    ver++;
  }

  void setFade(int i, Iterable<String> keys, bool on) {
    for (final k in keys) {
      steps[i].ch[k]?.fade = on;
    }
    ver++;
  }

  /// Swaps step [i] with its neighbour. Returns the step's new place.
  int move(int i, int dir) {
    final j = i + dir;
    if (j < 0 || j >= steps.length) return i;
    final s = steps[i];
    steps[i] = steps[j];
    steps[j] = s;
    ver++;
    return j;
  }

  /// A copy of step [i], right after it.
  void copy(int i) {
    final w = steps[i];
    steps.insert(i + 1, WorkStep(w.src, w.len, {for (final e in w.ch.entries) e.key: ChVal(e.value.v, e.value.fade)}));
    ver++;
  }

  void delete(int i) {
    if (steps.length < 2) return;
    steps.removeAt(i);
    ver++;
  }

  void setLen(int i, int cs) {
    steps[i].len = cs;
    ver++;
  }

  void setLenAll(int cs) {
    for (final w in steps) {
      w.len = cs;
    }
    ver++;
  }

  /// Heads of [sel] that have channel [ix] in some step.
  List<String> withChannel(Iterable<String> sel, int ix) => [
    for (final id in sel)
      if (steps.any((w) => w.ch.containsKey(chKey(id, ix)))) id,
  ];

  /// Takes channel [ix] out of heads [ids] in every step.
  void delCh(Iterable<String> ids, int ix) {
    for (final id in ids) {
      final k = chKey(id, ix);
      for (final w in steps) {
        w.ch.remove(k);
      }
      final a = add.indexWhere((x) => x.fx == id && x.ix == ix);
      if (a >= 0) {
        add.removeAt(a);
      } else if (maps.any((m) => m.containsKey(k))) {
        del.add(SceneChannelRef(fx: id, ix: ix));
      }
    }
    ver++;
  }

  /// Adds channel [ix] to heads [ids] in every step that has them (value 0,
  /// no fade). One taken out before is put back as it was.
  void addCh(Iterable<String> ids, int ix) {
    for (final id in ids) {
      final k = chKey(id, ix);
      final d = del.indexWhere((x) => x.fx == id && x.ix == ix);
      if (d >= 0) {
        del.removeAt(d);
        for (final w in steps) {
          final c = maps[w.src][k];
          if (c != null) w.ch[k] = ChVal(c.v, c.fade);
        }
        continue;
      }
      if (maps.any((m) => m.containsKey(k)) || add.any((x) => x.fx == id && x.ix == ix)) continue;
      add.add(SceneChannelRef(fx: id, ix: ix));
      for (final w in steps) {
        if (inStep(w, id)) w.ch[k] = ChVal(0, false);
      }
    }
    ver++;
  }

  /// Channels the model has (as the show's scenes name them) that none of
  /// heads [sel] has in step [i], and that can be added to one of them.
  List<SceneChannelName> addable(int i, String model, Iterable<String> sel) {
    if (i < 0 || i >= steps.length) return [];
    final have = {for (final r in rows(i, sel)) r.ix};
    final w = steps[i];
    return [
      for (final c in scene.models?[model]?.chans ?? const <SceneChannelName>[])
        if (!have.contains(c.ix) && sel.any((id) => inStep(w, id))) c,
    ];
  }

  // ---- on the lights

  int _tabVer = -1;
  late List<String> _keys;
  late List<Map<String, int>> _v;
  late List<Map<String, bool>> _f;

  /// Step by key to value. A channel missing from a step keeps the step
  /// before's value, like the SX Player.
  void _table() {
    if (_tabVer == ver) return;
    final keys = <String>{for (final w in steps) ...w.ch.keys};
    _v = [];
    _f = [];
    var prev = <String, int>{};
    for (final w in steps) {
      final a = <String, int>{}, b = <String, bool>{};
      for (final k in keys) {
        final c = w.ch[k];
        if (c != null) {
          a[k] = c.v;
          b[k] = c.fade;
        } else {
          a[k] = prev[k] ?? 0;
        }
      }
      _v.add(a);
      _f.add(b);
      prev = a;
    }
    _keys = keys.toList();
    _tabVer = ver;
  }

  /// Where a playing scene is after [ms] milliseconds: (step, how far into it, 0..1).
  (int, double) playAt(int ms) {
    final lens = [for (final w in steps) w.cs * 10 < 10 ? 10 : w.cs * 10];
    final tot = lens.fold(0, (a, b) => a + b);
    var p = ms % tot, at = 0;
    while (p >= lens[at]) {
      p -= lens[at];
      at++;
    }
    return (at, p / lens[at]);
  }

  /// DMX channel (1-based) to value for step [at]. When [frac] is given the
  /// scene is playing and fading channels are [frac] of the way from the
  /// step before. Heads without an address are left out.
  Map<int, int> frame(int at, {double? frac}) {
    final out = <int, int>{};
    final n = steps.length;
    if (n == 0) return out;
    _table();
    final pv = _v[(at - 1 + n) % n];
    for (final k in _keys) {
      final bar = k.lastIndexOf('|');
      final h = byId[k.substring(0, bar)];
      if (h == null || h.addr == 0) continue;
      final ch = h.addr + int.parse(k.substring(bar + 1));
      if (ch < 1 || ch > 8192) continue;
      var v = _v[at][k]!.toDouble();
      if (frac != null && (_f[at][k] ?? false)) v = pv[k]! + (v - pv[k]!) * frac;
      out[ch] = jsRound(v).clamp(0, 255);
    }
    return out;
  }
}
