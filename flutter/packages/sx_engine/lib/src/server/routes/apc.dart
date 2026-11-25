import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/apc.dart';
import '../api.dart';
import '../engine.dart';
import '../ps_body.dart';

final _digits = RegExp(r'^\d+$');
final _note = RegExp(r'^-?\d+$');
final _sec = RegExp(r'^page\d+_button\d+$', caseSensitive: false);

/// `[int]` of text that already passed a digits check. Too big to matter is 1000.
int _int(String s) => int.tryParse(s) ?? 1000;

void registerApcRoutes(Engine e) {
  e.api.get('/api/apc', (req) => apcPreview(e.show()));

  e.api.post('/api/apc/apply', queue: const Queueable('APC pads'), (req) {
    // The old server's checks, on the raw values, before anything is parsed.
    final items = [
      for (final c in bodyItems(req.body['changes']))
        if (psTruthy(c))
          (
            sec: bodyText(field(c, 'sec')),
            title: bodyText(field(c, 'title')),
            note: bodyText(field(c, 'note')),
            on: field(c, 'on') == null ? null : bodyText(field(c, 'on')),
            off: field(c, 'on') == null ? null : bodyText(field(c, 'off')),
          ),
    ];
    bool badColour(({String? on, String? off}) c) =>
        c.on != null && (!_digits.hasMatch(c.on!) || !_digits.hasMatch(c.off!) || _int(c.on!) > 127 || _int(c.off!) > 127);
    bool badNote(({String sec, String note}) c) => !_sec.hasMatch(c.sec) || !_note.hasMatch(c.note) || _int(c.note) < -1 || _int(c.note) > 63;
    if (items.any((c) => badColour((on: c.on, off: c.off))) || items.isEmpty || items.any((c) => badNote((sec: c.sec, note: c.note)))) {
      throw ToolError('Nothing valid to save.');
    }
    return apcApply(e.show(), [
      for (final c in items)
        ApcChange(
          sec: c.sec,
          title: c.title,
          note: int.parse(c.note),
          on: c.on == null ? null : int.parse(c.on!),
          off: c.on == null ? null : int.parse(c.off!),
        ),
    ]);
  });
}
