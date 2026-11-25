import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/speed.dart';
import '../api.dart';
import '../engine.dart';
import '../ps_body.dart';

final _sec = RegExp(r'^page\d+_button\d+$', caseSensitive: false);
final _digits = RegExp(r'^\d+$');

void registerSpeedRoutes(Engine e) {
  e.api.get('/api/speed', (req) => speedPreview(e.show()));

  e.api.post('/api/speed/apply', queue: const Queueable('Speed faders'), (req) {
    // The old server's checks, on the raw values, before anything is parsed:
    // a missing or fractional fader is refused, not read as a number.
    final items = [
      for (final c in bodyItems(req.body['changes']))
        if (psTruthy(c)) (sec: bodyText(field(c, 'sec')), title: bodyText(field(c, 'title')), fader: bodyText(field(c, 'fader'))),
    ];
    if (items.isEmpty || items.any((c) => !_sec.hasMatch(c.sec) || !_digits.hasMatch(c.fader) || (int.tryParse(c.fader) ?? 100) > 99)) {
      throw ToolError('Nothing valid to save.');
    }
    return speedApply(e.show(), [for (final c in items) SpeedChange(sec: c.sec, title: c.title, fader: int.parse(c.fader))]);
  });
}
