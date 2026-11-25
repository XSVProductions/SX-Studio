import 'dart:io';

import '../../player/cs_compat.dart';
import '../../player/lab_player.dart';
import '../../player/player_commands.dart';
import '../../player/player_links.dart';
import '../../player/player_show.dart';
import '../engine.dart';

/// `"$x"` of a JSON value, as the old server read request fields.
String _psText(Object? v) => switch (v) {
  null => '',
  true => 'True',
  false => 'False',
  double d when d == d.truncateToDouble() && d.abs() < 1e15 => '${d.toInt()}',
  _ => '$v',
};

/// PowerShell's truth of a JSON value: false, 0, '' and null are false.
bool _psTrue(Object? v) => switch (v) {
  null || false || '' => false,
  num n => n != 0,
  _ => true,
};

/// The SX Player: its list, start, stop, commands, status, and the hand-over
/// to ShowXpress. Port of the `/api/lab...` routes of `df_aim_gui.ps1`.
///
/// Shares the player with the other areas: `e.find<PlayerControl>()` for
/// the Auto Show and `e.find<LabPlayerHooks>()` for settings.
void registerLabRoutes(Engine e) {
  final lab = LabPlayer(e);
  e.provide<PlayerControl>(lab);
  e.provide<LabPlayerHooks>(lab);

  e.api.get('/api/lab', (req) => playerList(e.show()));

  e.api.get('/api/lab/status', (req) => {'ok': true, 'running': lab.running, 'status': lab.statusJson, 'event': lab.event?.toJson()});

  e.api.post('/api/lab/snap', (req) async => {'ok': true, 'titles': await lab.snap()});

  e.api.post('/api/lab/handoff', (req) async {
    if (!lab.running) {
      final r = await e.sx.launch();
      return {'ok': r.ok, 'error': r.error, 'titles': <String>[], 'test': lab.test};
    }
    return lab.handoff(launch: true, why: 'Handed over to ShowXpress.');
  });

  e.api.post('/api/lab/start', (req) => lab.startFromScreen(stopNova: _psTrue(req.body['stopNova'])));

  e.api.post('/api/lab/cmd', (req) {
    const gone = {'ok': false, 'gone': true, 'error': 'The SX Player stopped.'};
    if (!lab.running) return gone;
    final body = req.body;
    final c = _psText(body['cmd']);
    PlayerCommand? cmd;
    var err = '';
    const notThere = 'That button is not in the show any more - press Reload.';
    switch (c) {
      case 'press':
        final b = lab.labButton(_psText(body['sec']));
        if (b != null && extraButtonRx.hasMatch(b.sec) && b.kind == 'missing') {
          err = 'The file for ${b.title} is missing.';
        } else if (!lab.isPlayable(b)) {
          err = notThere;
        } else {
          cmd = PressCommand(b!.sec);
        }
      case 'fader':
        final k = csInt(_psText(body['k'])), v = csDouble(_psText(body['v']));
        // NaN is refused here: the old server let it through and it garbled the button's clock
        if (k == null || k < 0 || k > 15 || v == null || v.isNaN) {
          err = 'Bad fader value.';
        } else {
          cmd = FaderCommand(k, double.parse(v.clamp(0.0, 1.0).toStringAsFixed(4)));
        }
      case 'tap':
        cmd = const TapCommand();
      case 'sync':
        cmd = const SyncCommand();
      case 'bpm':
        final v = csDouble(_psText(body['v']));
        if (v != null && v >= 40 && v <= 250) {
          cmd = BpmCommand(double.parse(v.toStringAsFixed(2)));
        } else {
          err = 'The BPM has to be 40 to 250.';
        }
      case 'key':
        final k = _psText(body['key']).toLowerCase();
        if (RegExp(r'^[a-z0-9]$').hasMatch(k)) {
          cmd = KeyCommand(k);
        } else {
          err = 'Bad key.';
        }
      case 'on' || 'off':
        final b = lab.labButton(_psText(body['sec']));
        if (!lab.isPlayable(b)) {
          err = notThere;
        } else if (c == 'off') {
          cmd = PlayOff(b!.sec);
        } else if (!(b!.kind == 'scex' || b.kind == 'gpj') || !File(b.path).existsSync()) {
          err = 'The file for ${b.title} is missing.';
        } else {
          cmd = PlayOn(b.sec, b.path);
        }
      case 'alloff':
        cmd = const AllOffCommand();
      case 'bo':
        cmd = BlackoutCommand(_psTrue(body['on']));
      default:
        err = 'Unknown player command.';
    }
    if (err.isNotEmpty) return {'ok': false, 'error': err};
    if (!lab.send(cmd!)) return gone;
    return {'ok': true};
  });

  e.api.post('/api/lab/stop', (req) async {
    await lab.stop();
    // an Auto Show on the player goes back to ShowXpress (it waits there until ShowXpress is open)
    final auto = e.find<PlayerAutoShowLink>();
    if ((auto?.running ?? false) && auto!.onPlayer) await auto.restart();
    return {'ok': true};
  });
}
