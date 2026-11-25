import '../../show/show_env.dart';
import '../../tools/health.dart';
import '../api.dart';
import '../engine.dart';
import '../ps_body.dart';

// The old server's fix keys, plus `color251`. The old list left it out, so
// its "Match the 251s" button always answered "Unknown fix."
final _fixKey = RegExp(r'^(speed|midiout|midilight|pad|color|color251|fixtures)\|(page\d+_button\d+|\d+)$', caseSensitive: false);
final _fixId = RegExp(r'^[0-9a-f]{8}$', caseSensitive: false);

void registerHealthRoutes(Engine e) {
  e.api.get('/api/health', (req) => healthCheck(e.show()));

  e.api.post('/api/health/fix', queue: Queueable('Health fix', key: (b) => 'fix-${bodyText(b['key'])}'), (req) {
    final key = bodyText(req.body['key']);
    if (!_fixKey.hasMatch(key)) throw ToolError('Unknown fix.');
    return healthFix(e.show(), key);
  });

  e.api.post('/api/health/revert', (req) {
    final id = bodyText(req.body['id']);
    if (!_fixId.hasMatch(id)) throw ToolError('Unknown fix.');
    return switch (healthRevert(e.show(), id, force: psTruthy(req.body['force']))) {
      RevertDone(:final report) => report,
      RevertConflict(:final conflict) => {'ok': true, 'conflict': conflict, 'out': ''},
    };
  });

  e.api.post('/api/health/keep', (req) {
    final id = bodyText(req.body['id']);
    if (!_fixId.hasMatch(id)) throw ToolError('Unknown fix.');
    return healthKeep(e.show(), id);
  });
}
