import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/apc.dart';
import '../api.dart';
import '../engine.dart';

/// `"$v"` in PowerShell for a value decoded from JSON.
String _psText(Object? v) => switch (v) {
  null => '',
  bool b => b ? 'True' : 'False',
  double d when d == d.truncateToDouble() && d.isFinite => '${d.toInt()}',
  _ => '$v',
};

final _digits = RegExp(r'^\d+$');

void registerApcRoutes(Engine e) {
  e.api.get('/api/apc', (req) => apcPreview(e.show()));

  e.api.post('/api/apc/apply', queue: const Queueable('APC pads'), (req) {
    // The old server's checks, on the raw values, before anything is parsed.
    final raw = [
      for (final c in req.body['changes'] is List ? req.body['changes'] as List : [req.body['changes']])
        if (c is Map) c.cast<String, Object?>(),
    ];
    bool badColour(Json c) =>
        c['on'] != null &&
        (!_digits.hasMatch(_psText(c['on'])) ||
            !_digits.hasMatch(_psText(c['off'])) ||
            int.parse(_psText(c['on'])) > 127 ||
            int.parse(_psText(c['off'])) > 127);
    bool badNote(Json c) {
      final n = _psText(c['note']);
      return !RegExp(r'^page\d+_button\d+$').hasMatch(_psText(c['sec'])) || !RegExp(r'^-?\d+$').hasMatch(n) || int.parse(n) < -1 || int.parse(n) > 63;
    }

    if (raw.isEmpty || raw.any(badColour) || raw.any(badNote)) throw ToolError('Nothing valid to save.');
    final changes = [
      for (final c in raw)
        ApcChange(
          sec: _psText(c['sec']),
          title: _psText(c['title']),
          note: int.parse(_psText(c['note'])),
          on: c['on'] == null ? null : int.parse(_psText(c['on'])),
          off: c['on'] == null ? null : int.parse(_psText(c['off'])),
        ),
    ];
    return apcApply(e.show(), changes);
  });
}
