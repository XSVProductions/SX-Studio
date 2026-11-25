import 'dart:async';

import 'package:sx_api/sx_api.dart';

import 'scene_work.dart';

// The Scene Editor's preview on the real lights: the step on screen, or the
// whole scene playing, sent straight from this screen through the engine's
// live DMX output. The scene's own values go out as they are (`raw`).
//
// Port of `sePush`, `seKick`, `seFlush`, `sePvGo` and `sePvStop` in
// `df_aim_gui.ps1`. Talks to `/api/live/start`, `/api/live/out` and
// `/api/live/stop` with the old server's bodies.

/// A running preview. Create it with [ScenePreview.start]; call [stop] when
/// the user stops it, leaves the scene or leaves the tab.
class ScenePreview {
  ScenePreview._(this._client, this._work, this.test, this.iface, this.onFailed, this.onStep);

  final SxClient _client;
  SceneWork _work;

  /// The engine has no real interface (development) and sends nowhere.
  final bool test;

  /// The interface the DMX goes out on.
  final String iface;

  /// Called once when the output stops by itself, with the reason.
  final void Function(String error) onFailed;

  /// Called while playing when the step being played changes.
  final void Function(int at) onStep;

  var _on = true;
  final _sent = <int, int>{};
  final _pend = <int, String>{};
  var _z = true, _ka = false, _flushing = false;
  Timer? _wait, _keepAlive, _player;
  var _last = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _t0;
  var _at = -1;
  var _hold = 0;

  bool get on => _on;
  bool get playing => _player != null;

  /// The step being played, or -1.
  int get playingAt => playing ? _at : -1;

  /// Starts the engine's live output. Returns the preview, or the engine's
  /// answer when it refused (`ok` false, with `error`, and `nova` when the
  /// NovaStar software holds the interface).
  static Future<(ScenePreview?, ToolResult)> start(
    SxClient client,
    SceneWork work, {
    bool stopNova = false,
    required void Function(String error) onFailed,
    required void Function(int at) onStep,
  }) async {
    ToolResult r;
    try {
      r = await client.run('/api/live/start', {'mode': 'floor', 'raw': true, if (stopNova) 'stopNova': true});
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!r.ok) return (null, r);
    final p = ScenePreview._(client, work, r.extra['test'] == true, '${r.extra['iface'] ?? ''}', onFailed, onStep);
    p._keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {
      if (p._on && DateTime.now().difference(p._last).inMilliseconds > 1000) {
        p._ka = true;
        p._kick();
      }
    });
    return (p, r);
  }

  /// Sends what changed since the last frame: step [hold] when not playing.
  void push(SceneWork work, int hold) {
    if (!_on) return;
    _work = work;
    _hold = hold;
    final Map<int, int> fr;
    if (playing) {
      final (at, frac) = work.playAt(DateTime.now().difference(_t0!).inMilliseconds);
      if (at != _at) {
        _at = at;
        onStep(at);
      }
      fr = work.frame(at, frac: frac);
    } else {
      fr = work.frame(hold);
    }
    for (final ch in _sent.keys.toList()) {
      if (!fr.containsKey(ch) && _sent[ch] != 0) {
        _sent[ch] = 0;
        _pend[ch] = 'b:$ch:0';
      }
    }
    fr.forEach((ch, v) {
      if (_sent[ch] != v) {
        _sent[ch] = v;
        _pend[ch] = 'b:$ch:$v';
      }
    });
    _kick();
  }

  /// Plays the whole scene, looping, with its fades ([on] true), or holds the
  /// step last pushed. Read [playingAt] before holding to know where it was.
  void play(bool on) {
    _player?.cancel();
    _player = null;
    if (on) {
      _t0 = DateTime.now();
      _at = -1;
      _player = Timer.periodic(const Duration(milliseconds: 40), (_) => push(_work, _hold));
    }
    push(_work, _hold);
  }

  /// At most one send every 30 ms.
  void _kick() {
    if (!_on || _wait != null || _flushing) return;
    final d = 30 - DateTime.now().difference(_last).inMilliseconds;
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
    if (!_on || _flushing) return;
    var l = '${_z ? 'z ' : ''}${_pend.values.join(' ')}'.trim();
    if (l.isEmpty) {
      if (!_ka) return;
      l = 'k';
    }
    _z = false;
    _ka = false;
    _pend.clear();
    _flushing = true;
    _last = DateTime.now();
    ToolResult r;
    try {
      r = await _client.run('/api/live/out', {'l': l});
    } on ApiException {
      r = const ToolResult.failed('Lost connection to SX Studio.');
    }
    _flushing = false;
    if (!_on) return;
    if (!r.ok) {
      await stop();
      onFailed(r.error.isEmpty ? 'The DMX output stopped.' : r.error);
      return;
    }
    if (_pend.isNotEmpty) _kick();
  }

  /// Stops sending and releases the interface. Safe to call twice.
  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    _keepAlive?.cancel();
    _player?.cancel();
    _player = null;
    _wait?.cancel();
    try {
      await _client.run('/api/live/stop', const {});
    } on ApiException {
      // the engine is gone, and its output with it
    }
  }
}
