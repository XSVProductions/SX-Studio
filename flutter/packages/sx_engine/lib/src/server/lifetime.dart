import 'dart:async';

import '../player/player_links.dart';
import '../sx/auto_player.dart';
import 'engine.dart';

/// How long the engine waits after the last request before it quits, the old
/// server's `$idleMax` (300 s).
const idleMax = Duration(seconds: 300);

/// When the app quits by itself. The old server outlived its window: it kept
/// answering phones and kept the queue, the Auto Show and the SX Player going,
/// and stopped five minutes after the last request once none of those was
/// busy. The laptop window polls every two seconds while it is open, so the
/// rule only bites after the window has been closed.
///
/// Port of the idle check in `df_aim_gui.ps1`'s main loop (`$last`,
/// `$idleMax`, `Test-Auto`, `Test-Player`, `$queue.Count`).
class Lifetime {
  Lifetime({required this.busy, this.max = idleMax, DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _last = _clock();
  }

  /// The engine's rule: work in the save queue, the Auto Show or the SX
  /// Player playing. Live output does not count, as before: the window that
  /// drove it stops it when it closes.
  factory Lifetime.of(Engine e) =>
      Lifetime(busy: () => !e.queue.isEmpty || (e.find<AutoShow>()?.running ?? false) || (e.find<PlayerControl>()?.running ?? false));

  /// True while something must keep the engine alive.
  final bool Function() busy;
  final Duration max;
  final DateTime Function() _clock;
  late DateTime _last;
  final _quit = Completer<QuitReason>();

  /// Completes once when the engine should quit. The app stops the engine
  /// and exits then. Nothing listens in the engine on its own (development)
  /// or in tests, so there nothing quits.
  Future<QuitReason> get quitting => _quit.future;

  /// True once [quitting] has completed.
  bool get quit => _quit.isCompleted;

  /// When the last request came in.
  DateTime get lastRequest => _last;

  /// A request came in, from the laptop window or a paired phone (`$last = Get-Date`).
  void touch() => _last = _clock();

  /// Called every second. Quits when nobody asked anything for [max] and
  /// nothing is busy.
  void step() {
    if (quit || _clock().difference(_last) <= max || busy()) return;
    _quit.complete(QuitReason.idle);
  }

  /// Quits now, for an update: the installer replaces the app.
  void quitFor(QuitReason why) {
    if (!quit) _quit.complete(why);
  }
}

/// Why the engine asked the app to quit.
enum QuitReason {
  /// Nobody used it for five minutes after its window was closed.
  idle,

  /// An update was downloaded. The installer starts once the engine has
  /// stopped, and opens the new version.
  update,
}
