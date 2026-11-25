import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../ps_compat.dart';
import '../../system/laptop.dart';
import '../../tools/preshow.dart';
import '../engine.dart';

final _fixKey = RegExp(r'^(sleep|usb|restart)$', caseSensitive: false);

/// The Pre-show Check. A test can hand the engine its own [Laptop] with
/// `engine.provide<Laptop>(...)`.
void registerPreshowRoutes(Engine e) {
  Laptop? real;
  Laptop laptop() => e.find<Laptop>() ?? (real ??= Laptop());

  e.api.get('/api/pre', (req) => preshowCheck(e.show(), laptop()));

  e.api.post('/api/pre/fix', (req) {
    final key = req.body.str('key');
    if (!_fixKey.hasMatch(key)) throw ToolError('Unknown fix.');
    // Restarting the laptop is never something a phone may do.
    if (req.fromPhone && psEq(key, 'restart')) throw ToolError('Only on the laptop.');
    return preshowFix(laptop(), key);
  });
}
