import 'dart:async';

import 'package:sx_api/sx_api.dart';

/// "Press these buttons in ShowXpress now, or as soon as it is open."
///
/// Other areas find it with `e.find<ButtonPresses>()`. Aim asks for the CHECK
/// buttons after an apply. The Lab asks for what the SX Player was playing when
/// it hands over to ShowXpress, and cancels that again when the player starts.
abstract interface class ButtonPresses {
  /// Presses [titles] (and releases everything else) once ShowXpress is open
  /// and answering, unless the show plays then. Replaces an earlier request.
  /// [label] names the buttons on screen ("DF CHECK 140 + 251"). Gives up
  /// after [within].
  void pressWhenOpen(List<String> titles, String label, {Duration within});

  /// Drops the waiting request, or only one with this [label].
  void cancel({String? label});
}

/// The waiting request, if any, and the last automatic press.
///
/// Every second while something waits: if ShowXpress is open and live aim
/// is off, at most every 3 seconds it tries an idle solo press. A press that
/// got through, or a remote that is switched off, ends the wait.
///
/// Port of `Set-PendingPress` and `Step-Pending` in `df_aim_gui.ps1`.
class PendingPresses implements ButtonPresses {
  PendingPresses({required this.press, required this.sxOpen, required this.live, required this.autoRunning, DateTime Function()? now, this.timer = true})
    : now = now ?? DateTime.now;

  /// An idle solo press of these titles (`Press -Solo -Idle`).
  final Future<RemoteState> Function(List<String> titles) press;
  final bool Function() sxOpen;

  /// Live aim holds the lights.
  final bool Function() live;

  /// The Auto Show plays. It owns the buttons, so a waiting press is dropped.
  final bool Function() autoRunning;
  final DateTime Function() now;

  /// Runs [step] every second while something waits. Tests step by hand.
  final bool timer;

  ({List<String> titles, String label, DateTime until})? _pend;
  DateTime _tried = DateTime(0);
  Timer? _timer;
  var _stepping = false;

  /// The last automatic press, for the status poll (`rem`).
  RemoteLast? last;

  /// Something waits for ShowXpress (`pend` in the status poll).
  bool get pending => _pend != null;

  @override
  void pressWhenOpen(List<String> titles, String label, {Duration within = const Duration(seconds: 1200)}) {
    _pend = (titles: [...titles], label: label, until: now().add(within));
    if (timer) _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => step());
  }

  @override
  void cancel({String? label}) {
    if (label == null || _pend?.label == label) _done();
  }

  void _done() {
    _pend = null;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> step() async {
    final p = _pend;
    if (p == null || _stepping) return;
    final t = now();
    if (t.isAfter(p.until) || autoRunning()) return _done();
    if (t.difference(_tried) < const Duration(seconds: 3) || !sxOpen() || live()) return;
    _tried = t;
    _stepping = true;
    try {
      final RemoteState r;
      try {
        r = await press(p.titles);
      } on Object {
        return; // tries again in 3 seconds
      }
      // a failed engine call has no setup, and then it tries again
      if (r.connected || (r.setup != null && !r.ready)) {
        if (identical(_pend, p)) _done();
        last = RemoteLast(
          at: now().toUtc().toIso8601String(),
          label: p.label,
          ok: r.connected && !r.skipped,
          skipped: r.skipped,
          playing: r.playing,
          error: r.error,
        );
      }
    } finally {
      _stepping = false;
    }
  }
}
