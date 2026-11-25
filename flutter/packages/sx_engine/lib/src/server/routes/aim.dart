import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';
import '../../sx/pending_presses.dart';
import '../../tools/aim/aim.dart';
import '../api.dart';
import '../engine.dart';
import 'move.dart';

/// `"$($body.mode)" -eq 'room'` in the old server: anything else is the dance floor.
AimMode aimModeOf(String mode) => psEq(mode, 'room') ? AimMode.room : AimMode.floor;

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

  // A saved or reverted GRAND ENTRANCE.gpj makes its step scene again
  // (`Update-MoveScenes`). The old server ran `-Action Rebuild` through
  // `Invoke-Engine`, so any failure became a warning line, not a failed save.
  e.provide(
    MoveSavedHook((env) {
      try {
        aimRebuild(env);
      } on ToolError {
        rethrow;
      } catch (x) {
        throw ToolError('$x');
      }
    }),
  );

  e.api.get('/api/preview', (req) => aimPreview(e.show(), aimModeOf(req.query['mode'] ?? '')));

  e.api.post('/api/apply', queue: aimQueue, (req) {
    final out = applyAims(e.show(), req.body);
    // the CHECK buttons come on when ShowXpress next opens (`Set-PendingPress`)
    final room = aimModeOf(req.body.str('mode')) == AimMode.room;
    e.find<ButtonPresses>()?.pressWhenOpen(room ? const ['ROOM CHECK'] : const ['DF CHECK 140', 'DF CHECK 251'], room ? 'ROOM CHECK' : 'DF CHECK 140 + 251');
    return out;
  });

  e.api.post(
    '/api/home',
    queue: Queueable('Aim Movers (reset)', key: aimQueue.key, detail: aimQueue.detail),
    (req) => aimHome(e.show(), aimModeOf(req.body.str('mode'))),
  );

  // always the room: only the room has buttons to add
  e.api.post('/api/aim/install', queue: const Queueable('ROOM buttons on the SETUP page'), (req) => aimInstall(e.show(), AimMode.room));
}

/// `aimApply` with the old server's input check for `/api/apply`. The route
/// also runs for `/api/live/save`, as the old `Invoke-Action '/api/apply'`.
String applyAims(ShowEnv env, Json body) {
  final w = psInt(body['w']), d = psInt(body['d']);
  if (w < 20 || w > 300 || d < 20 || d > 300) throw ToolError('Size must be 20-300%.');
  return aimApply(env, aimModeOf(body.str('mode')), size: '$w $d', force: psTruthy(body['force']));
}
