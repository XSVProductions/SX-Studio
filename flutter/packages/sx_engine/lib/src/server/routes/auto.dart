import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';
import '../../sx/auto_player.dart';
import '../../tools/auto_show.dart';
import '../engine.dart';

/// The Auto Show: its settings, and start, stop and commands while it plays.
/// Shares [AutoShowControl] for the Lab.
///
/// Port of `/api/auto*` and the AUTO SHOW block in `df_aim_gui.ps1`.
void registerAutoRoutes(Engine e) {
  final auto = AutoShow(show: e.show, sxOpen: () => e.sx.running, player: () => e.find<AutoPlayerLink>());
  e.provide<AutoShow>(auto);
  e.provide<AutoShowControl>(auto);

  e.api.get('/api/auto', (req) {
    final i = autoGet(e.show());
    return AutoInfo(
      show: i.show,
      config: i.config,
      buttons: i.buttons,
      ready: i.ready,
      open: i.open,
      setup: i.setup,
      player: e.find<AutoPlayerLink>()?.playing ?? false,
      status: auto.status(),
    );
  });

  e.api.get('/api/auto/status', (req) => AutoAnswer(ok: true, status: auto.status()));

  e.api.post('/api/auto/save', (req) {
    final config = req.body.objOrNull('config');
    if (config == null) throw ToolError('Nothing to save.');
    final r = autoSave(e.show(), config);
    auto.reload();
    return {'ok': true, 'out': r.report, 'error': '', 'config': autoConfigJson(r.config)};
  });

  e.api.post('/api/auto/start', (req) => auto.start(req.body.str('look')));

  e.api.post('/api/auto/stop', (req) async => AutoAnswer(ok: true, status: await auto.stop()));

  e.api.post('/api/auto/cmd', (req) async {
    final c = req.body.str('cmd'), v = req.body.str('v');
    final cmd = AutoCmd.values.where((x) => psEq(x.name, c)).firstOrNull;
    if (cmd == null ||
        (cmd == AutoCmd.bpm && !RegExp(r'^\d{2,3}(\.\d)?$').hasMatch(v)) ||
        (cmd == AutoCmd.go && !RegExp(r'^[0-9a-f]{8}$', caseSensitive: false).hasMatch(v))) {
      throw ToolError('Unknown command.');
    }
    final ok = auto.command(cmd, v);
    await auto.tick();
    return AutoAnswer(ok: ok, error: ok ? '' : "The Auto Show isn't playing.", status: auto.status());
  });
}
