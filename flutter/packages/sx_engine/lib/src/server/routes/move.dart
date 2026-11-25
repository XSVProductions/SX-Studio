import 'dart:async';

import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';
import '../../tools/move_edit.dart';
import '../api.dart';
import '../engine.dart';

/// Makes the step scenes that follow a movement again after it changed.
///
/// The old server rebuilt `GRAND ENTRANCE.scex` from `GRAND ENTRANCE.gpj`
/// after every save or revert that changed it (`Update-MoveScenes`, which runs
/// the aim tool's `-Action Rebuild`). The aim area provides this with
/// `e.provide(MoveSavedHook(...))`. [rebuild] throws `ToolError` with the
/// reason when it can't. Without a hook nothing is rebuilt.
class MoveSavedHook {
  const MoveSavedHook(this.rebuild);

  final FutureOr<void> Function(ShowEnv env) rebuild;
}

void registerMoveRoutes(Engine e) {
  e.api.get('/api/moves', (req) => moveList(e.show()));

  e.api.get('/api/move', (req) {
    final f = req.query['f'] ?? '';
    if (!isMoveName(f)) throw ToolError('Unknown movement.');
    return moveOpen(e.show(), f);
  });

  e.api.get('/api/move/backups', (req) {
    final f = req.query['f'] ?? '';
    if (!isMoveName(f)) throw ToolError('Unknown movement.');
    return moveBackups(e.show(), f, backups: moveBackupsIn(e.settingsFolder));
  });

  e.api.post(
    '/api/move/save',
    queue: Queueable(
      'Movement',
      key: (b) => 'move-${b.str('move').toLowerCase()}',
      detail: (b) => b.str('move').replaceFirst(RegExp(r'\.gpj$', caseSensitive: false), ''),
    ),
    (req) async {
      // Only the changes go to the tool, which changes just those lines of the .gpj.
      final f = req.body.str('move');
      if (!isMoveName(f)) throw ToolError('Unknown movement.');
      List<Object?> items(String k) => switch (req.body[k]) {
        null => const [],
        final List<Object?> l => [...l.where((x) => x != null)],
        final x => [x],
      };
      final env = e.show();
      final out = moveSave(env, {
        'move': f,
        'sha': req.body.str('sha'),
        'secs': items('secs'),
        'heads': items('heads'),
      }, backups: moveBackupsIn(e.settingsFolder));
      return _afterChange(e, env, f, out);
    },
  );

  e.api.post('/api/move/revert', (req) async {
    final f = req.body.str('f'), id = req.body.str('id');
    if (!isMoveName(f) || !RegExp(r'^\d{8}-\d{6}-\d{3}$').hasMatch(id)) throw ToolError('Unknown backup.');
    if (e.sx.running) throw ToolError('ShowXpress is open. Close it (save first), then press Revert again.');
    final env = e.show();
    return switch (moveRevert(env, f, id, force: req.body['force'] == true, backups: moveBackupsIn(e.settingsFolder))) {
      MoveRevertConflict() => {'ok': true, 'conflict': true, 'out': ''},
      MoveReverted(:final out) => _afterChange(e, env, f, out),
    };
  });
}

/// Port of `Update-MoveScenes`.
Future<String> _afterChange(Engine e, ShowEnv env, String f, String out) async {
  final hook = e.find<MoveSavedHook>();
  if (hook == null || !psEq(f, 'GRAND ENTRANCE.gpj') || !out.toLowerCase().contains('changed')) return out;
  try {
    await hook.rebuild(env);
    return '$out\n  GRAND ENTRANCE scene made again from the movement.';
  } on ToolError catch (x) {
    return '$out\n  WARNING: the GRAND ENTRANCE scene was NOT made again: ${x.message}';
  }
}
