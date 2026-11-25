import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/scene_edit.dart';
import '../api.dart';
import '../engine.dart';

/// The old server's `$sceneRx`. `-notmatch` ignores case.
final _sceneRx = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$', caseSensitive: false);

/// Scene Editor routes. Port of `/api/scenes`, `/api/scene`,
/// `/api/scene/backups`, `/api/scene/revert` and `/api/scene/save` in `df_aim_gui.ps1`.
void registerSceneRoutes(Engine e) {
  e.api.get('/api/scenes', (req) => sceneList(e.show()));

  e.api.get('/api/scene', (req) {
    final f = req.query['f'] ?? '';
    if (!_sceneRx.hasMatch(f)) throw ToolError('Unknown scene.');
    return sceneOpen(e.show(), f);
  });

  e.api.get('/api/scene/backups', (req) {
    final f = req.query['f'] ?? '';
    if (!_sceneRx.hasMatch(f)) throw ToolError('Unknown scene.');
    return sceneBackups(e.show(), f);
  });

  e.api.post('/api/scene/revert', (req) {
    final f = req.body.str('f'), id = req.body.str('id');
    if (!_sceneRx.hasMatch(f) || !RegExp(r'^\d{8}-\d{6}-\d{3}$').hasMatch(id)) throw ToolError('Unknown backup.');
    if (e.sx.running) throw ToolError('ShowXpress is open. Close it (save first), then press Revert again.');
    final r = sceneRevert(e.show(), f, id, force: req.body['force'] == true);
    return r.conflict ? {'ok': true, 'conflict': true, 'out': ''} : r.out;
  });

  // Only the changes go to the tool, which changes just those in the file.
  e.api.post(
    '/api/scene/save',
    queue: Queueable(
      'Scene',
      key: (b) => 'scene-${b.str('scene').toLowerCase()}',
      detail: (b) => b.str('scene').replaceFirst(RegExp(r'\.scex$', caseSensitive: false), ''),
    ),
    (req) {
      if (!_sceneRx.hasMatch(req.body.str('scene'))) throw ToolError('Unknown scene.');
      final SceneChanges changes;
      try {
        changes = SceneChanges.fromJson(req.body);
      } on FormatException catch (x) {
        throw ToolError(x.message);
      }
      return sceneSave(e.show(), changes);
    },
  );
}
