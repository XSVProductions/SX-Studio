import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/color.dart';
import '../api.dart';
import '../engine.dart';

/// Tonight's Color. Port of `/api/color` and `/api/color/apply` in `df_aim_gui.ps1`.
void registerColorRoutes(Engine e) {
  e.api.get('/api/color', (req) => colorPreview(e.show()));

  e.api.post(
    '/api/color/apply',
    // the queue shows which color is waiting: "Tonight's Color (#f4a6b8)"
    queue: Queueable("Tonight's Color", detail: (b) => '(#${b.str('hex').replaceFirst(RegExp('^#+'), '').toLowerCase()})'),
    (req) {
      final hex = req.body.str('hex').trim().replaceFirst(RegExp('^#+'), '');
      if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) throw ToolError('Pick a colour first.');
      var name = req.body.str('name').replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '').trim();
      if (name.length > 30) name = name.substring(0, 30);
      return colorApply(e.show(), hex, name: name);
    },
  );
}
