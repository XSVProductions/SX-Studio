import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/speed.dart';
import '../api.dart';
import '../engine.dart';

void registerSpeedRoutes(Engine e) {
  e.api.get('/api/speed', (req) => speedPreview(e.show()));

  e.api.post('/api/speed/apply', queue: const Queueable('Speed faders'), (req) {
    final changes = req.body.list('changes', SpeedChange.fromJson);
    final valid = RegExp(r'^page\d+_button\d+$');
    if (changes.isEmpty || changes.any((c) => !valid.hasMatch(c.sec) || c.fader < 0 || c.fader > 99)) {
      throw ToolError('Nothing valid to save.');
    }
    return speedApply(e.show(), changes);
  });
}
