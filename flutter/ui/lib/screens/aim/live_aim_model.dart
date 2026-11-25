import 'dart:async';

import 'package:sx_api/sx_api.dart';

/// A pan and tilt while aiming. Fractions, because a fine drag moves less
/// than one step per pixel. Rounded when sent and when saved.
typedef Pos = (double, double);

/// 16-bit pan steps per pixel at Normal speed. Tilt gets more, so a pixel is
/// the same angle both ways. The old page's `LVB`.
const panStepsPerPixel = 10;

/// The speed buttons: Fine, Normal, Fast.
const aimSpeeds = [(0.4, 'Fine'), (1.0, 'Normal'), (3.0, 'Fast')];

enum AimStep { center, corner }

double _cl(double v) => v.clamp(0, 65535).toDouble();

Pos _pos(PanTilt p) => (p.$1.toDouble(), p.$2.toDouble());

/// JavaScript's `Math.round`: halves go up.
int jsRound(double v) => (v + .5).floor();

/// One head's aims while aiming live. The old page's `LV.W[id]`.
class HeadWork {
  HeadWork({required this.c, this.k, this.tc = false, this.tk = false});

  /// Step 1 aim.
  Pos c;

  /// Step 2 aim, or null to follow the center.
  Pos? k;

  /// Touched here: center, corner.
  bool tc;
  bool tk;

  HeadWork copy() => HeadWork(c: c, k: k, tc: tc, tk: tk);

  bool same(HeadWork o) => c == o.c && k == o.k && tc == o.tc && tk == o.tk;
}

/// Everything on the live aim screen except the widgets: which head is
/// picked, each head's aims, and where every head points now.
///
/// Port of the LIVE AIM part of `df_aim_gui.ps1`'s page script (`lvPos`,
/// `lvCopies`, `lvMove`, `lvStepTo` and friends).
class LiveAimModel {
  LiveAimModel(LiveAimInfo info, {required this.mode, this.speed = 1, required this.flipOf})
    : heads = info.heads,
      aimTitle = info.aimTitle,
      byId = {for (final h in info.heads) h.id: h},
      towers = info.heads.any((h) => h.order < 99),
      // by walking order. List.sort is not stable and the page's Array.sort
      // is, so ties keep the show's order.
      ordered = [
        for (final (_, h) in info.heads.indexed.toList()..sort((a, b) => a.$2.order != b.$2.order ? a.$2.order.compareTo(b.$2.order) : a.$1.compareTo(b.$1))) h,
      ] {
    for (final h in heads) {
      work[h.id] = HeadWork(c: _pos(h.c), k: h.kSet ? _pos(h.k) : null);
      initial[h.id] = work[h.id]!.copy();
    }
    final first = ordered.where((h) => !towers || h.order < 99);
    sel = first.isEmpty ? ordered.first : first.first;
    flip = flipOf(sel.id);
  }

  final AimMode mode;
  final String aimTitle;
  final List<LiveHead> heads;
  final Map<String, LiveHead> byId;

  /// Some heads are on truss spots (Rig Test was done).
  final bool towers;
  final List<LiveHead> ordered;

  final work = <String, HeadWork>{};
  final initial = <String, HeadWork>{};

  late LiveHead sel;
  var step = AimStep.center;

  /// Light every hung head, not just the picked one.
  var all = false;
  double speed;

  /// Mirror the drag for this head: x = left / right, y = up / down.
  late ({bool x, bool y}) flip;
  final ({bool x, bool y}) Function(String id) flipOf;

  HeadWork w(LiveHead h) => work[h.id]!;

  bool aimed(LiveHead h) => w(h).tc || w(h).tk || !h.free;

  LiveHead? partner(LiveHead h) => h.partner.isEmpty ? null : byId[h.partner];

  /// Not aimed by the user, so it shows its T-bar partner's aim.
  bool copies(LiveHead h) {
    final p = partner(h), x = w(h);
    return p != null && !x.tc && !x.tk && h.free && aimed(p);
  }

  /// The corner aim, or the center moved by the default corner offset.
  Pos corner(LiveHead h) {
    final x = w(h);
    return x.k ?? (_cl(x.c.$1 + h.dk.$1 - h.home.$1), _cl(x.c.$2 + h.dk.$2 - h.home.$2));
  }

  /// Where a head points for [st].
  Pos pos(LiveHead h, AimStep st) {
    if (copies(h)) return pos(partner(h)!, st);
    return st == AimStep.corner ? corner(h) : w(h).c;
  }

  bool lit(LiveHead h) => h == sel || (all && (!towers || h.order < 99 || h.hung));

  /// A head showing its partner's aim starts from there when it is aimed.
  void _take(LiveHead h) {
    if (!copies(h)) return;
    final p = partner(h)!, x = w(h);
    x
      ..c = pos(p, AimStep.center)
      ..k = w(p).k
      ..tc = true;
  }

  /// Moves the picked head by a drag of [dx], [dy] pixels. [fine] is Shift,
  /// [fast] is Ctrl. Returns false when nothing moved.
  bool move(double dx, double dy, {bool fine = false, bool fast = false}) {
    final h = sel, x = w(h), m = speed * (fine ? .25 : 1) * (fast ? 4 : 1);
    final ratio = h.deg.$2 == 0 ? 1 : h.deg.$1 / h.deg.$2;
    final dp = dx * panStepsPerPixel * m * (flip.x ? -1 : 1), dt = -dy * panStepsPerPixel * m * ratio * (flip.y ? -1 : 1);
    if (dp == 0 && dt == 0) return false;
    _take(h);
    if (step == AimStep.corner) {
      final k = x.k ?? corner(h);
      x
        ..k = (_cl(k.$1 + dp), _cl(k.$2 + dt))
        ..tk = true;
    } else {
      x
        ..c = (_cl(x.c.$1 + dp), _cl(x.c.$2 + dt))
        ..tc = true;
    }
    return true;
  }

  /// Heads Next and Previous walk through: the picked one, and the others
  /// that don't just copy a partner (only truss spots once Rig Test was done).
  List<LiveHead> nav() => [
    for (final h in ordered)
      if (h == sel || (!copies(h) && (!towers || h.order < 99))) h,
  ];

  void select(LiveHead h) {
    sel = h;
    flip = flipOf(h.id);
  }

  /// Next (+1) or previous (-1) head. After the last head in step 1, goes to
  /// step 2 on the first head.
  void stepTo(int dir) {
    final n = nav(), j = n.indexOf(sel) + dir;
    if (j >= 0 && j < n.length) return select(n[j]);
    if (dir > 0 && step == AimStep.center) {
      step = AimStep.corner;
      final m = ordered.where((h) => !copies(h) && (!towers || h.order < 99));
      select(m.isEmpty ? sel : m.first);
    }
  }

  bool get canUndo => !w(sel).same(initial[sel.id]!);

  void undo() => work[sel.id] = initial[sel.id]!.copy();

  /// Back to the normal aim. A head that had nothing set just loses this
  /// session's edits.
  void backToNormal() {
    final h = sel;
    work[h.id] = h.free && !h.kSet ? initial[h.id]!.copy() : HeadWork(c: _pos(h.home), tc: true, tk: true);
  }

  /// Gives the picked head its T-bar partner's aims.
  void sameAsPartner() {
    final p = partner(sel);
    if (p == null) return;
    final pk = w(p).k;
    work[sel.id] = HeadWork(c: pos(p, AimStep.center), k: pk, tc: true, tk: pk != null);
  }

  bool get edited => heads.any((h) => !w(h).same(initial[h.id]!));

  /// What Save sends: heads aimed here only. A corner touched but not set
  /// (Back to normal) saves the default corner.
  Map<String, LiveAim> aimsToSave() => {
    for (final h in heads)
      if (w(h).tc || w(h).tk)
        h.id: LiveAim(
          c: (jsRound(w(h).c.$1), jsRound(w(h).c.$2)),
          k: !w(h).tk
              ? null
              : w(h).k == null
              ? h.dk
              : (jsRound(w(h).k!.$1), jsRound(w(h).k!.$2)),
        ),
  };

  /// Degrees from the normal center, the readout and the minimap's unit.
  double degrees(LiveHead h, double v, int axis) => axis == 0 ? (v - h.home.$1) * h.deg.$1 / 65536 : (v - h.home.$2) * h.deg.$2 / 65536;
}

/// The DMX commands still to send. Only channels that changed go out, and
/// a channel changed twice before a send goes once with the latest value.
/// The old page's `lvPair`, `lvByte` and `lvPush`.
class LiveOutputBuffer {
  final _sent = <String, int>{};
  final _pend = <String, String>{};

  /// Clear everything first ("z"): the first send, and after a reconnect.
  var zero = true;

  bool get isEmpty => _pend.isEmpty;

  void _pair(int c, double value, bool snap) {
    final v = jsRound(value), k = 'p$c';
    if (!snap && _sent[k] == v) return;
    _sent[k] = v;
    final o = _pend[k];
    _pend[k] = '${snap || (o != null && o.startsWith('s')) ? 's' : 'p'}:$c:${c + 1}:$v';
  }

  void _byte(int ch, int v) {
    final k = 'b$ch';
    if (_sent[k] == v) return;
    _sent[k] = v;
    _pend[k] = 'b:$ch:$v';
  }

  /// Every head's position and look. [snap] jumps instead of gliding.
  void push(LiveAimModel m, {bool snap = false}) {
    for (final h in m.heads) {
      final p = m.pos(h, m.step), lit = m.lit(h);
      _pair(h.addr, p.$1, snap);
      _pair(h.addr + 2, p.$2, snap);
      for (final (i, v) in h.look) {
        _byte(h.addr + i, !lit && (i == h.dimI || i == h.shutI) ? 0 : v);
      }
    }
  }

  /// Forget what was sent, for a reconnect.
  void reset() {
    _sent.clear();
    _pend.clear();
    zero = true;
  }

  /// The next line to send, and clears it. Empty when there is nothing.
  String take() {
    final l = '${zero ? 'z ' : ''}${_pend.values.join(' ')}'.trim();
    zero = false;
    _pend.clear();
    return l;
  }
}

/// Sends a [LiveOutputBuffer] to the engine: one request at a time, at most
/// one every 30 ms, and a keep-alive after 2 seconds of nothing so the
/// engine's 30 second safety stop doesn't turn the heads off.
/// The old page's `lvKick`, `lvFlush` and keep-alive interval.
class LiveOutputPump {
  LiveOutputPump(this.buffer, {required this.send, required this.onGone, DateTime Function()? now}) : _now = now ?? DateTime.now {
    _keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_now().difference(_last) > const Duration(seconds: 2)) {
        _ka = true;
        kick();
      }
    });
  }

  final LiveOutputBuffer buffer;
  final Future<ToolResult> Function(String line) send;

  /// The output stopped (unplugged, or the engine lost it). Called once.
  final void Function(String error) onGone;
  final DateTime Function() _now;

  late final Timer _keepAlive;
  Timer? _wait;
  var _inFlight = false;
  var _ka = false;
  var _last = DateTime.fromMillisecondsSinceEpoch(0);
  var gone = false;
  var _closed = false;

  /// Sends soon, waiting for the request in flight and the 30 ms gap.
  void kick() {
    if (_closed || _wait != null || _inFlight) return;
    final d = 30 - _now().difference(_last).inMilliseconds;
    if (d > 0) {
      _wait = Timer(Duration(milliseconds: d), () {
        _wait = null;
        _flush();
      });
    } else {
      _flush();
    }
  }

  Future<void> _flush() async {
    if (_closed || gone || _inFlight) return;
    var l = buffer.take();
    if (l.isEmpty) {
      if (!_ka) return;
      l = 'k';
    }
    _ka = false;
    _inFlight = true;
    _last = _now();
    ToolResult r;
    try {
      r = await send(l);
    } on ApiException {
      r = ToolResult(ok: false, error: 'Lost connection to SX Studio.', extra: const {'gone': true});
    }
    if (_closed) return;
    _inFlight = false;
    if (!r.ok) {
      gone = true;
      onGone(r.error);
      return;
    }
    if (!buffer.isEmpty) kick();
  }

  /// Sending again after a reconnect.
  void resume() {
    gone = false;
    _inFlight = false;
  }

  void close() {
    _closed = true;
    _keepAlive.cancel();
    _wait?.cancel();
  }
}
