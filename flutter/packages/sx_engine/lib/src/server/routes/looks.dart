import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/looks.dart';
import '../engine.dart';
import '../ps_body.dart';

/// One-click Looks. Port of `/api/looks` and `/api/looks/make` in `df_aim_gui.ps1`.
///
/// Making a look writes a new file and never touches live.ini, so it is not
/// queued while ShowXpress is open (the old server didn't queue it either).
void registerLooksRoutes(Engine e) {
  e.api.get('/api/looks', (req) => looksRig(e.show()));

  e.api.post('/api/looks/make', (req) {
    if (!RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.scex$', caseSensitive: false).hasMatch(bodyText(req.body['name']))) {
      throw ToolError('Give the look a name.');
    }
    return looksMake(e.show(), LookDraft.fromJson(req.body));
  });
}
