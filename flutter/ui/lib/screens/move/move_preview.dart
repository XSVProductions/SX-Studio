import 'dart:async';

import 'package:sx_api/sx_api.dart';

/// Plays the movement on the real lights while it is edited: the movement as
/// the screen has it, straight to the DMX interface, through the live output
/// routes (`/api/live/start` with `raw`, `/api/live/out`, `/api/live/stop`).
///
/// A frame is worked out every 40 ms and only the channels that changed go
/// out, one request at a time. When nothing changed for a second a keep-alive
/// goes out. Port of the old page's `mvPush`, `mvKick`, `mvFlush` and
/// `mvPvGo`/`mvPvStop`.
class MovePreview {
  MovePreview(this.client, {required this.frame, required this.onLost});

  final SxClient client;

  /// The DMX values to send now: 1-based channel to value.
  final Map<int, int> Function() frame;

  /// Called when the output stopped by itself, with the reason.
  final void Function(String error) onLost;

  var _on = false;
  final _sent = <int, int>{};
  final _pend = <int, String>{};
  var _zero = true, _keepAlive = false, _flushing = false;
  var _last = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _tick, _alive, _kick;

  /// Output name the engine reported, and whether it is the fake test output.
  String iface = '';
  bool test = false;

  bool get on => _on;

  /// Opens the output. A refusal comes back as `ok == false`; `extra['nova']`
  /// is true when the NovaStar software holds the interface and pausing it
  /// may help (call again with [stopNova]).
  Future<ToolResult> start({bool stopNova = false}) async {
    final r = await client.run('/api/live/start', {'mode': 'floor', 'raw': true, if (stopNova) 'stopNova': true});
    if (!r.ok) return r;
    iface = '${r.extra['iface'] ?? ''}';
    test = r.extra['test'] == true;
    _on = true;
    _zero = true;
    _sent.clear();
    _pend.clear();
    _alive = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_on && DateTime.now().difference(_last).inMilliseconds > 1000) {
        _keepAlive = true;
        _schedule();
      }
    });
    _tick = Timer.periodic(const Duration(milliseconds: 40), (_) => push());
    push();
    return r;
  }

  /// Works out the frame now and sends what changed.
  void push() {
    if (!_on) return;
    final fr = frame();
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
    _schedule();
  }

  void _schedule() {
    if (!_on || _kick != null || _flushing) return;
    final wait = 40 - DateTime.now().difference(_last).inMilliseconds;
    if (wait > 0) {
      _kick = Timer(Duration(milliseconds: wait), () {
        _kick = null;
        _flush();
      });
    } else {
      _flush();
    }
  }

  Future<void> _flush() async {
    if (!_on || _flushing) return;
    var l = '${_zero ? 'z ' : ''}${_pend.values.join(' ')}'.trim();
    if (l.isEmpty) {
      if (!_keepAlive) return;
      l = 'k';
    }
    _zero = false;
    _keepAlive = false;
    _pend.clear();
    _flushing = true;
    _last = DateTime.now();
    ToolResult r;
    try {
      r = await client.run('/api/live/out', {'l': l});
    } on ApiException {
      r = const ToolResult.failed('Lost connection to SX Studio.');
    }
    _flushing = false;
    if (!_on) return;
    if (!r.ok) {
      await stop();
      onLost(r.error.isEmpty ? 'The DMX output stopped.' : r.error);
      return;
    }
    if (_pend.isNotEmpty) _schedule();
  }

  /// Stops the output. Safe to call when it isn't running.
  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    _tick?.cancel();
    _alive?.cancel();
    _kick?.cancel();
    _kick = null;
    try {
      await client.run('/api/live/stop', const {});
    } on ApiException {
      // The engine is gone; so is the output.
    }
  }
}
