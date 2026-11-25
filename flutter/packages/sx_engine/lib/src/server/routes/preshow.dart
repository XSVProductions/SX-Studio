import '../../show/show_env.dart';
import '../../system/laptop.dart';
import '../../tools/preshow.dart';
import '../engine.dart';
import '../ps_body.dart';

final _fixKey = RegExp(r'^(sleep|usb|restart)$', caseSensitive: false);

/// The Pre-show Check. A test can hand the engine its own [Laptop] with
/// `engine.provide<Laptop>(...)`.
void registerPreshowRoutes(Engine e) {
  Laptop? real;
  Laptop laptop() => e.find<Laptop>() ?? (real ??= Laptop());

  e.api.get('/api/pre', (req) => preshowCheck(e.show(), laptop()));

  e.api.post('/api/pre/fix', (req) {
    final key = bodyText(req.body['key']);
    if (!_fixKey.hasMatch(key)) throw ToolError('Unknown fix.');
    return preshowFix(laptop(), key);
  });
}
