import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../sx/auto_player.dart';
import '../../sx/pending_presses.dart';
import '../engine.dart';
import 'aim.dart' show psTruthy;

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
    // ShowXpress needs the DMX interface to itself.
    await e.dmx.stopAll();
    return e.sx.launch();
  });

  e.api.post('/api/sx/close', (req) {
    // live aim or the player asked: the queue must not reopen ShowXpress now
    if (psTruthy(req.body['live'])) e.liveHold.start(); // `if ($body.live)`
    // Force closing loses whatever ShowXpress hasn't saved. Never from a phone.
    final force = req.body.boolean('force');
    if (force && req.fromPhone) throw ToolError('Only on the laptop.');
    if (!e.sx.running) return {'ok': true, 'out': "  ShowXpress isn't open", 'error': '', 'none': true};
    return e.sx.close(force: force);
  });

  e.api.post('/api/queue/cancel', (req) {
    final key = req.body.str('key');
    e.queue.cancel(key == '*' ? null : key);
    return {'ok': true, 'q': e.queue.info()};
  });

  e.api.post('/api/queue/reopen', (req) {
    e.queue.reopen = req.body.boolean('on');
    return {'ok': true, 'q': e.queue.info()};
  });

  e.api.post('/api/queue/seen', (req) {
    e.queue.done = null;
    return {'ok': true};
  });
}
