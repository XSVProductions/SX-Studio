import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../dmx/dmx_output.dart';
import '../../dmx/nova.dart';
import '../../show/show_env.dart';
import '../../tools/aim/aim.dart';
import '../api.dart';
import '../engine.dart';
import 'aim.dart';

/// Live output's state between calls.
class _LiveAimSession {
  /// Channels (1-based) whose values go out reversed: 65535 - v, or 255 - v
  /// for a raw byte. Pan and fine pan of heads with `rp`, tilt and fine tilt
  /// of heads with `rt`. Empty in raw mode. The old server's `$liveInv`.
  final inv = <int>{};
}

final _token = RegExp(r'^(z|k|b:\d{1,4}:\d{1,3}|[ps]:\d{1,4}:\d{1,4}:\d{1,5})$', caseSensitive: false);
final _pair = RegExp(r'^([ps]):(\d+):(\d+):(\d+)$', caseSensitive: false);
final _byte = RegExp(r'^b:(\d+):(\d+)$', caseSensitive: false);

/// Live aim and the editors' previews: the laptop sends DMX itself while
/// ShowXpress is closed.
///
/// Port of the `/api/live/start`, `/api/live/out`, `/api/live/stop` and
/// `/api/live/save` branches of `df_aim_gui.ps1`.
void registerLiveRoutes(Engine e) {
  final session = _LiveAimSession();

  e.api.post('/api/live/start', (req) async {
    if (e.sx.running) {
      return {
        'ok': false,
        'sxopen': true,
        'error': 'ShowXpress is open - it has to be closed while you aim live (only one program can use the DMX interface).',
        'out': '',
      };
    }
    if (e.dmx.playerOn()) throw ToolError('The SX Player (Lab) is using the DMX interface. Stop it in the Lab first.');
    // raw is the editors' preview: the scene's own values go out as they are
    // (the show files already hold what reversed heads need), so no head info
    // and no reversing
    final raw = psTruthy(req.body['raw']);
    Json info = const {};
    if (!raw) {
      try {
        info = aimLiveInfo(e.show(), aimModeOf(req.body.str('mode'))).toJson();
      } on ToolError catch (err) {
        throw ToolError(err.message.isEmpty ? 'Could not read the show.' : err.message);
      }
    }
    e.liveHold.start();
    // the screen works "as if hung normally"; reversed heads get 65535 - v on the way out
    session.inv.clear();
    if (!raw) {
      for (final h in LiveAimInfo.fromJson(info).heads) {
        if (h.rp) session.inv.addAll([h.addr, h.addr + 1]);
        if (h.rt) session.inv.addAll([h.addr + 2, h.addr + 3]);
      }
    }
    if (psTruthy(req.body['stopNova']) && Platform.isWindows) await pauseNova();
    try {
      final live = await e.dmx.startLive();
      return {'ok': true, 'iface': live.iface, 'test': e.dmx.spec is FakeDmxSpec, 'info': info};
    } on DmxError catch (err) {
      if (Platform.isWindows && err.message.toLowerCase().contains('was not found') && await novaRunning()) {
        return {
          'ok': false,
          'nova': true,
          'error':
              'The NovaStar LED-screen software (NovaLCT) is holding the DMX interface. Its USB scanner can be paused while you aim - NovaLCT starts it again by itself.',
          'out': '',
        };
      }
      return {'ok': false, 'error': err.message, 'out': ''};
    }
  });

  e.api.post('/api/live/out', (req) {
    var line = req.body.str('l');
    final tokens = line.split(' ');
    if (line.length > 60000 || tokens.any((t) => t.isNotEmpty && !_token.hasMatch(t))) {
      return {'ok': false, 'error': 'Bad output command.'};
    }
    final live = e.dmx.live;
    if (live == null) return {'ok': false, 'gone': true, 'error': 'The DMX output stopped.'};
    if (session.inv.isNotEmpty) {
      line = tokens
          .map((t) {
            final p = _pair.firstMatch(t);
            if (p != null && session.inv.contains(int.parse(p[2]!))) return '${p[1]}:${p[2]}:${p[3]}:${65535 - int.parse(p[4]!)}';
            final b = _byte.firstMatch(t);
            if (b != null && session.inv.contains(int.parse(b[1]!))) return 'b:${b[1]}:${255 - int.parse(b[2]!)}';
            return t;
          })
          .join(' ');
    }
    live.send(line);
    return {'ok': true};
  });

  e.api.post('/api/live/stop', (req) async {
    await e.dmx.stopLive();
    e.liveHold.clear();
    return {'ok': true};
  });

  // stop the output, write the aims into the aim scene, apply (size from the
  // Aim tab), run anything queued, open ShowXpress again
  e.api.post('/api/live/save', (req) async {
    await e.dmx.stopLive();
    final mode = aimModeOf(req.body.str('mode'));
    final aims = {for (final MapEntry(:key, :value) in req.body.obj('aims').entries) key: value is Map ? LiveAim.fromJson(value.cast()) : const LiveAim()};
    final res = <String, Object?>{'ok': false, 'saved': false, 'applied': false, 'error': '', 'out': '', 'applyError': ''};
    try {
      res['out'] = aimLiveSave(e.show(), mode, aims);
      res['ok'] = res['saved'] = true;
    } on ToolError catch (err) {
      res['error'] = err.message;
    }
    if (res['ok'] == true && psTruthy(req.body['apply'])) {
      final b = req.body;
      final applied = await runRoute(
        e.api.find('/api/apply')!,
        ApiRequest(body: {'w': b['w'], 'd': b['d'], 'force': psTruthy(b['force']), 'mode': mode.name}, query: const {}, fromPhone: req.fromPhone),
      );
      res['out'] = '${res['out']}\n${applied['out'] ?? ''}';
      res['applied'] = applied['ok'] == true;
      res['applyError'] = '${applied['error'] ?? ''}';
    }
    e.liveHold.clear();
    if (!e.queue.isEmpty) await e.queue.run(reopen: false);
    if (psTruthy(req.body['reopen'])) {
      try {
        final r = await e.sx.launch();
        res['reopened'] = r.ok;
        res['reopenError'] = r.error;
      } catch (err) {
        res['reopened'] = false;
        res['reopenError'] = '$err';
      }
    }
    return res;
  });
}
