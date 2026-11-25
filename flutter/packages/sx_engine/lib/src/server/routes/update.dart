import 'package:sx_api/sx_api.dart';

import '../../settings/open_on_computer.dart';
import '../../settings/update_check.dart';
import '../../settings/update_install.dart';
import '../engine.dart';

/// The update check and "update". Port of `/api/update` and
/// `/api/update/install`.
void registerUpdateRoutes(Engine e) {
  e.provide(UpdateChecker(current: e.config.appVersion));
  if (e.config.appExe case final exe?) e.provide(UpdateInstaller(appExe: exe));
  UpdateChecker checker() => e.find<UpdateChecker>()!;

  e.api.get('/api/update', (req) => checker().check(fresh: req.query['fresh'] != null));

  e.api.post('/api/update/install', phone: false, (req) async {
    final u = await checker().check();
    if (!u.ok || !u.newer || !u.asset.startsWith('https://github.com/')) return const ToolResult.failed('No newer version found on GitHub.');
    final installer = e.find<UpdateInstaller>();
    if (installer != null) {
      await installer.install(u);
      // the app closes when it reads this, as the old server stopped itself
      return const ToolResult(ok: true, extra: {'restarting': true});
    }
    // The engine on its own (development) has no installed app to replace, so
    // the release page opens in the browser instead.
    if (!u.page.startsWith('https://github.com/')) return const ToolResult.failed('No newer version found on GitHub.');
    await (e.find<Opener>() ?? const LaptopOpener()).open(u.page);
    return ToolResult(ok: true, out: '  Version ${u.latest} is on GitHub. Its page is open in the browser: download the installer there and run it.');
  });
}
