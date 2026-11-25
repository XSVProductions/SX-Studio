import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/health.dart';
import '../api.dart';
import '../engine.dart';

// The old server's fix keys, plus `color251`. The old list left it out, so
// its "Match the 251s" button always answered "Unknown fix."
final _fixKey = RegExp(r'^(speed|midiout|midilight|pad|color|color251|fixtures)\|(page\d+_button\d+|\d+)$', caseSensitive: false);
final _fixId = RegExp(r'^[0-9a-f]{8}$', caseSensitive: false);

/// PowerShell's `if ($x)` on a value decoded from JSON.
bool _truthy(Object? v) => switch (v) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  _ => true,
};

void registerHealthRoutes(Engine e) {
  e.api.get('/api/health', (req) => healthCheck(e.show()));

  e.api.post('/api/health/fix', queue: Queueable('Health fix', key: (b) => 'fix-${b.str('key')}'), (req) {
    final key = req.body.str('key');
    if (!_fixKey.hasMatch(key)) throw ToolError('Unknown fix.');
    return healthFix(e.show(), key);
  });

  e.api.post('/api/health/revert', (req) {
    final id = req.body.str('id');
    if (!_fixId.hasMatch(id)) throw ToolError('Unknown fix.');
    return switch (healthRevert(e.show(), id, force: _truthy(req.body['force']))) {
      RevertDone(:final report) => report,
      RevertConflict(:final conflict) => {'ok': true, 'conflict': conflict, 'out': ''},
    };
  });

  e.api.post('/api/health/keep', (req) {
    final id = req.body.str('id');
    if (!_fixId.hasMatch(id)) throw ToolError('Unknown fix.');
    return healthKeep(e.show(), id);
  });
}
