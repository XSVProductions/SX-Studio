import 'aim.dart';
import 'client.dart';
import 'json.dart';

/// A 16-bit pan and tilt, each 0..65535.
typedef PanTilt = (int, int);

PanTilt _pt(Json j, String key) {
  final v = j.intList(key);
  return v.length == 2 ? (v[0], v[1]) : (0, 0);
}

List<int> _ptJson(PanTilt p) => [p.$1, p.$2];

/// One head on the live aim screen, with everything needed to drive it.
///
/// Aims are "as if hung normally". For a head SX Studio reverses ([rp],
/// [rt]) the engine sends `65535 - v` on the way out.
class LiveHead {
  const LiveHead({
    required this.id,
    required this.label,
    required this.is140,
    required this.addr,
    required this.look,
    required this.dimI,
    required this.shutI,
    required this.c,
    required this.k,
    required this.home,
    required this.dk,
    required this.kSet,
    required this.free,
    required this.partner,
    required this.tower,
    required this.side,
    required this.order,
    required this.hung,
    required this.deg,
    required this.rp,
    required this.rt,
  });

  factory LiveHead.fromJson(Json j) {
    final look = <(int, int)>[];
    final raw = j['look'];
    if (raw is List) {
      for (final e in raw) {
        if (e is List && e.length == 2 && e[0] is num && e[1] is num) look.add(((e[0] as num).round(), (e[1] as num).round()));
      }
    }
    return LiveHead(
      id: j.str('id'),
      label: j.str('label'),
      is140: j.boolean('is140'),
      addr: j.integer('addr'),
      look: look,
      dimI: j.integer('dimI'),
      shutI: j.integer('shutI'),
      c: _pt(j, 'c'),
      k: _pt(j, 'k'),
      home: _pt(j, 'home'),
      dk: _pt(j, 'dk'),
      kSet: j.boolean('kSet'),
      free: j.boolean('free'),
      partner: j.str('partner'),
      tower: j.str('tower'),
      side: j.str('side'),
      order: j.integer('order'),
      hung: j.boolean('hung'),
      deg: _pt(j, 'deg'),
      rp: j.boolean('rp'),
      rt: j.boolean('rt'),
    );
  }

  /// ShowXpress fixture id.
  final String id;
  final String label;
  final bool is140;

  /// First DMX channel (1-based). Pan is [addr], fine pan +1, tilt +2, fine tilt +3.
  final int addr;

  /// The aim look's other channels: (offset from [addr], value).
  final List<(int, int)> look;

  /// Offsets of the dimmer and shutter, which go to 0 on heads that are not lit.
  final int dimI;
  final int shutI;

  /// Step 1 (center) and step 2 (corner) aims from the aim scene.
  final PanTilt c;
  final PanTilt k;

  /// Normal center, and the default corner (k equal to this means "no corner set").
  final PanTilt home;
  final PanTilt dk;
  final bool kSet;

  /// True when the head is not aimed by the user (on home, or on last time's partner copy).
  final bool free;

  /// Id of the head on the same T-bar, or ''.
  final String partner;
  final String tower;

  /// 'L', 'R' or ''.
  final String side;

  /// Walking order around the truss, 99 when not on a truss spot.
  final int order;

  /// Hung tonight (Rig Test).
  final bool hung;

  /// The head's full pan and tilt range in degrees.
  final PanTilt deg;
  final bool rp;
  final bool rt;

  Json toJson() => {
    'id': id,
    'label': label,
    'is140': is140,
    'addr': addr,
    'look': [
      for (final (i, v) in look) [i, v],
    ],
    'dimI': dimI,
    'shutI': shutI,
    'c': _ptJson(c),
    'k': _ptJson(k),
    'home': _ptJson(home),
    'dk': _ptJson(dk),
    'kSet': kSet,
    'free': free,
    'partner': partner,
    'tower': tower,
    'side': side,
    'order': order,
    'hung': hung,
    'deg': _ptJson(deg),
    'rp': rp,
    'rt': rt,
  };
}

/// Everything the live aim screen needs. The old tool's `-Action LiveInfo`.
class LiveAimInfo {
  const LiveAimInfo({required this.show, required this.mode, required this.aimTitle, required this.heads});

  factory LiveAimInfo.fromJson(Json j) =>
      LiveAimInfo(show: j.str('show'), mode: j.str('mode'), aimTitle: j.str('aimTitle'), heads: j.list('heads', LiveHead.fromJson));

  final String show;

  /// 'Floor' or 'Room'.
  final String mode;
  final String aimTitle;
  final List<LiveHead> heads;

  Json toJson() => {
    'ok': true,
    'show': show,
    'mode': mode,
    'aimTitle': aimTitle,
    'heads': [for (final h in heads) h.toJson()],
  };
}

/// The answer to `/api/live/start`.
class LiveStart {
  const LiveStart({required this.ok, this.error = '', this.sxOpen = false, this.nova = false, this.iface = '', this.test = false, this.info});

  factory LiveStart.fromJson(Json j) {
    final info = j.objOrNull('info');
    return LiveStart(
      ok: j.boolean('ok'),
      error: j.str('error'),
      sxOpen: j.boolean('sxopen'),
      nova: j.boolean('nova'),
      iface: j.str('iface'),
      test: j.boolean('test'),
      // raw mode sends {} instead of heads
      info: info == null || !info.containsKey('heads') ? null : LiveAimInfo.fromJson(info),
    );
  }

  final bool ok;
  final String error;

  /// Refused because ShowXpress is open.
  final bool sxOpen;

  /// The NovaStar LED-screen software holds the interface (Windows).
  final bool nova;

  /// The interface's name.
  final String iface;

  /// True when there is no real output (development, tests).
  final bool test;

  /// Null in raw mode.
  final LiveAimInfo? info;
}

/// One head's new aims from the live aim screen. Null leaves that step as it is.
class LiveAim {
  const LiveAim({this.c, this.k});

  /// Reads one entry of `aims` the way the old tool does: a step counts only
  /// when it is two whole numbers from 0 to 65535.
  factory LiveAim.fromJson(Json j) => LiveAim(c: _ok16(j['c']), k: _ok16(j['k']));

  final PanTilt? c;
  final PanTilt? k;

  Json toJson() => {'c': c == null ? null : _ptJson(c!), 'k': k == null ? null : _ptJson(k!)};
}

PanTilt? _ok16(Object? v) {
  if (v is! List || v.length != 2) return null;
  final a = _digits(v[0]), b = _digits(v[1]);
  if (a == null || b == null || a > 65535 || b > 65535) return null;
  return (a, b);
}

/// PowerShell's `"$x" -match '^\d+$'` then `[int]$x`.
int? _digits(Object? x) {
  final s = switch (x) {
    double d when d == d.truncateToDouble() && d.isFinite => '${d.toInt()}',
    _ => '$x',
  };
  return RegExp(r'^\d+$').hasMatch(s) ? int.tryParse(s) : null;
}

/// The answer to `/api/live/save`.
class LiveSaveResult {
  const LiveSaveResult({
    required this.ok,
    required this.saved,
    required this.applied,
    required this.error,
    required this.out,
    required this.applyError,
    this.reopened = false,
    this.reopenError = '',
  });

  factory LiveSaveResult.fromJson(Json j) => LiveSaveResult(
    ok: j.boolean('ok'),
    saved: j.boolean('saved'),
    applied: j.boolean('applied'),
    error: j.str('error'),
    out: j.str('out'),
    applyError: j.str('applyError'),
    reopened: j.boolean('reopened'),
    reopenError: j.str('reopenError'),
  );

  final bool ok;
  final bool saved;
  final bool applied;
  final String error;
  final String out;
  final String applyError;
  final bool reopened;
  final String reopenError;

  Json toJson() => {
    'ok': ok,
    'saved': saved,
    'applied': applied,
    'error': error,
    'out': out,
    'applyError': applyError,
    'reopened': reopened,
    'reopenError': reopenError,
  };
}

extension LiveApi on SxClient {
  /// Opens the DMX output. [raw] is for the editors' previews: no head info
  /// and no reversing. [stopNova] pauses the NovaStar scanner first.
  Future<LiveStart> liveStart({AimMode mode = AimMode.floor, bool raw = false, bool stopNova = false}) async =>
      LiveStart.fromJson((await run('/api/live/start', {'mode': mode.name, 'raw': raw, if (stopNova) 'stopNova': true})).toJson());

  /// Sends one command line to the output (see `LiveDmx` for the commands).
  Future<ToolResult> liveOut(String line) => run('/api/live/out', {'l': line});

  Future<ToolResult> liveStop() => run('/api/live/stop');

  /// Stops the output, saves [aims] (by head id) into the aim scene, applies
  /// them at [w] x [d] percent when [apply], and opens ShowXpress again when [reopen].
  Future<LiveSaveResult> liveSave({
    required AimMode mode,
    required Map<String, LiveAim> aims,
    bool apply = true,
    required int w,
    required int d,
    bool force = false,
    bool reopen = false,
  }) async => LiveSaveResult.fromJson(
    (await run('/api/live/save', {
      'mode': mode.name,
      'aims': {for (final e in aims.entries) e.key: e.value.toJson()},
      'apply': apply,
      'w': w,
      'd': d,
      'force': force,
      'reopen': reopen,
    })).toJson(),
  );
}
