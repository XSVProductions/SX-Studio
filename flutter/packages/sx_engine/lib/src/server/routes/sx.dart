import 'package:sx_api/sx_api.dart';

import '../../sx/auto_player.dart';
import '../../sx/pending_presses.dart';
import '../../settings/settings_store.dart';
import '../engine.dart';
import '../ps_body.dart';

/// ShowXpress open/close, the status poll and the save queue.
void registerSxRoutes(Engine e) {
  e.api.get('/api/sx', (req) {
    final pending = e.find<PendingPresses>();
    return SxStatus(
      open: e.sx.running,
      queue: QueueInfo.fromJson(e.queue.info()),
      live: e.dmx.liveOn,
      play: e.dmx.playerOn(),
      auto: e.find<AutoShow>()?.status(),
      pend: pending?.pending ?? false,
      rem: pending?.last,
    );
  });

  e.api.post('/api/sx/launch', (req) async {
    // the SX Player gives the DMX interface back. Live output is left alone,
    // as the old `Stop-Player; Start-Sx`.
    if (e.dmx.playerOn()) await e.dmx.stopPlayer();
    return e.sx.launch();
  });

  e.api.post('/api/sx/close', (req) {
    // live aim or the player asked: the queue must not reopen ShowXpress now
    if (psTruthy(req.body['live'])) e.liveHold.start();
    // Force closing loses whatever ShowXpress hasn't saved. A phone may do it
    // too, as before.
    final force = psTruthy(req.body['force']);
    if (!e.sx.running) return {'ok': true, 'out': "  ShowXpress isn't open", 'error': '', 'none': true};
    return e.sx.close(force: force);
  });

  e.api.post('/api/queue/cancel', (req) {
    e.queue.cancel(bodyText(req.body['key']));
    return {'ok': true, 'q': e.queue.info()};
  });

  e.api.post('/api/queue/reopen', (req) {
    // kept in the settings too, so it lasts and shows in Settings
    e.queue.reopen = psTruthy(req.body['on']);
    e.find<SettingsStore>()?.setReopen(e.queue.reopen);
    return {'ok': true, 'q': e.queue.info()};
  });

  e.api.post('/api/queue/seen', (req) {
    e.queue.done = null;
    return {'ok': true};
  });
}
