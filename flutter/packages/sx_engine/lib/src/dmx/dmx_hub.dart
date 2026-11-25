import 'dart:async';

import 'dmx_output.dart';
import 'live_dmx.dart';

/// Who holds the DMX interface. Only one of ShowXpress, live output (live
/// aim, editor previews) and the SX Player can have it at a time.
class DmxHub {
  DmxHub(this.spec);

  /// Which output to open. Fake in tests and development.
  DmxSpec spec;

  LiveDmx? _live;

  /// The SX Player's side, set by the player when it exists.
  bool Function() playerOn = () => false;
  Future<void> Function() stopPlayer = () async {};

  /// The running live output, or null.
  LiveDmx? get live => (_live?.running ?? false) ? _live : null;

  bool get liveOn => live != null;

  /// True while SX Studio itself is sending DMX.
  bool get busy => liveOn || playerOn();

  /// Starts live output, stopping an earlier one. Right after ShowXpress
  /// closes the interface can take a moment to be free, so this tries three
  /// times. Throws [DmxError] with a message for the user.
  Future<LiveDmx> startLive() async {
    await stopLive();
    DmxError? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 1500));
      try {
        return _live = await LiveDmx.start(spec);
      } on DmxError catch (e) {
        last = e;
        if (!e.message.startsWith('The DMX interface (D512S) was not found')) break;
      }
    }
    throw last!;
  }

  Future<void> stopLive() async {
    final l = _live;
    _live = null;
    if (l != null && l.running) await l.stop();
  }

  /// Lights out and everything released, for when the app quits or
  /// ShowXpress is about to open.
  Future<void> stopAll() async {
    await stopLive();
    if (playerOn()) await stopPlayer();
  }
}
