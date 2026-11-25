import '../../player/player_links.dart';
import '../../show/show_env.dart';
import '../../sx/pending_presses.dart';
import '../../sx/remote_setup.dart';
import '../../sx/sx_remote.dart';
import '../api.dart';
import '../engine.dart';
import '../ps_body.dart';

/// ShowXpress's remote control, as the SX Player's Lab sees it.
class _LabRemote implements PlayerShowXpressLink {
  _LabRemote(this.e, this.pending);

  final Engine e;
  final PendingPresses pending;

  @override
  Future<List<PressedButton>?> pressed() async {
    final r = await remoteAction(e.show(), RemoteAction.state);
    if (!r.connected) return null;
    return [for (final p in r.pressed) (page: p.page, title: p.title)];
  }

  @override
  void setPendingPress(List<String> titles, String label) => pending.pressWhenOpen(titles, label);

  @override
  void clearPendingPress(String label) => pending.cancel(label: label);
}

/// ShowXpress's remote control: read what plays, press, all off, switch the
/// remote on. Shares [ButtonPresses] for "press when ShowXpress opens", and
/// the same as a [PlayerShowXpressLink] for the Lab.
///
/// Port of `/api/remote*` and the SHOWXPRESS REMOTE block in `df_aim_gui.ps1`.
void registerRemoteRoutes(Engine e) {
  final pending = PendingPresses(
    press: (titles) => remoteAction(e.show(), RemoteAction.press, titles: titles, solo: true, idle: true),
    sxOpen: () => e.sx.running,
    live: () => e.dmx.liveOn,
    autoRunning: () => e.find<PlayerAutoShowLink>()?.running ?? false,
  );
  e.provide<PendingPresses>(pending);
  e.onStop(pending.cancel);
  e.provide<ButtonPresses>(pending);
  e.provide<PlayerShowXpressLink>(_LabRemote(e, pending));

  e.api.get('/api/remote', (req) => remoteAction(e.show(), RemoteAction.state));

  e.api.post('/api/remote/press', (req) {
    List<String> titles(String key) => [for (final t in bodyTexts(req.body[key])) t.trim()].where((t) => t.isNotEmpty).toList();
    final ts = titles('titles'), rs = titles('release');
    final valid = RegExp(r'^[^"|\r\n]{1,80}$');
    if (ts.isEmpty || ts.length > 30 || rs.length > 30 || [...ts, ...rs].any((t) => !valid.hasMatch(t))) throw ToolError('Unknown button.');
    return remoteAction(e.show(), RemoteAction.press, titles: ts, release: rs, solo: psTruthy(req.body['solo']), idle: psTruthy(req.body['idle']));
  });

  e.api.post('/api/remote/off', (req) => remoteAction(e.show(), RemoteAction.off));

  e.api.post('/api/remote/enable', queue: const Queueable('ShowXpress remote control'), (req) => remoteEnable(e.show()));
}
