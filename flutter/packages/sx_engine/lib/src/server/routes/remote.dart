import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../sx/auto_player.dart';
import '../../sx/pending_presses.dart';
import '../../sx/remote_setup.dart';
import '../../sx/sx_remote.dart';
import '../api.dart';
import '../engine.dart';

/// ShowXpress's remote control: read what plays, press, all off, switch the
/// remote on. Shares [ButtonPresses] for "press when ShowXpress opens".
///
/// Port of `/api/remote*` and the SHOWXPRESS REMOTE block in `df_aim_gui.ps1`.
void registerRemoteRoutes(Engine e) {
  final pending = PendingPresses(
    press: (titles) => remoteAction(e.show(), RemoteAction.press, titles: titles, solo: true, idle: true),
    sxOpen: () => e.sx.running,
    live: () => e.dmx.liveOn,
    autoRunning: () => e.find<AutoShowControl>()?.running ?? false,
  );
  e.provide<PendingPresses>(pending);
  e.provide<ButtonPresses>(pending);

  e.api.get('/api/remote', (req) => remoteAction(e.show(), RemoteAction.state));

  e.api.post('/api/remote/press', (req) {
    List<String> titles(String key) => [for (final t in req.body.strList(key)) t.trim()].where((t) => t.isNotEmpty).toList();
    final ts = titles('titles'), rs = titles('release');
    final valid = RegExp(r'^[^"|\r\n]{1,80}$');
    if (ts.isEmpty || ts.length > 30 || rs.length > 30 || [...ts, ...rs].any((t) => !valid.hasMatch(t))) throw ToolError('Unknown button.');
    return remoteAction(e.show(), RemoteAction.press, titles: ts, release: rs, solo: req.body.boolean('solo'), idle: req.body.boolean('idle'));
  });

  e.api.post('/api/remote/off', (req) => remoteAction(e.show(), RemoteAction.off));

  e.api.post('/api/remote/enable', queue: const Queueable('ShowXpress remote control'), (req) => remoteEnable(e.show()));
}
