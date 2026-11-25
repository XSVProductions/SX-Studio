import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';
import '../../tools/aim/aim.dart';
import '../api.dart';
import '../engine.dart';

/// `"$($body.mode)" -eq 'room'` in the old server: anything else is the dance floor.
AimMode aimModeOf(String mode) => psEq(mode, 'room') ? AimMode.room : AimMode.floor;

/// PowerShell's `if ($body.x)`: null, false, 0 and '' are false.
bool psTruthy(Object? v) => switch (v) {
  null || false || '' => false,
  num n => n != 0,
  _ => true,
};

/// The Aim Movers tab: preview, apply at a size, reset to normal and the ROOM buttons.
///
/// Port of the `/api/preview`, `/api/apply`, `/api/home` and `/api/aim/install`
/// branches of `df_aim_gui.ps1` (`Invoke-Action` and the GET switch).
void registerAimRoutes(Engine e) {
  final aimQueue = Queueable(
    'Aim Movers',
    key: (b) => 'aim-${aimModeOf(b.str('mode')).name}',
    detail: (b) => aimModeOf(b.str('mode')) == AimMode.room ? '- Room' : '- Dance Floor',
  );

  e.api.get('/api/preview', (req) => aimPreview(e.show(), aimModeOf(req.query['mode'] ?? '')));

  e.api.post('/api/apply', queue: aimQueue, (req) => applyAims(e.show(), req.body));

  e.api.post(
    '/api/home',
    queue: Queueable('Aim Movers (reset)', key: aimQueue.key, detail: aimQueue.detail),
    (req) => aimHome(e.show(), aimModeOf(req.body.str('mode'))),
  );

  // always the room: only the room has buttons to add
  e.api.post('/api/aim/install', queue: const Queueable('ROOM buttons on the SETUP page'), (req) => aimInstall(e.show(), AimMode.room));
}

/// `/api/apply` with the old server's input check. Also called by
/// `/api/live/save`, as the old server's `Invoke-Action '/api/apply'`.
///
/// The old server then sets the CHECK press for when ShowXpress opens
/// (`Set-PendingPress`: DF CHECK 140 + DF CHECK 251, or ROOM CHECK). That
/// belongs to the remote control area and is not done here.
String applyAims(ShowEnv env, Json body) {
  final w = psInt(body['w']), d = psInt(body['d']);
  if (w < 20 || w > 300 || d < 20 || d > 300) throw ToolError('Size must be 20-300%.');
  return aimApply(env, aimModeOf(body.str('mode')), size: '$w $d', force: psTruthy(body['force']));
}
