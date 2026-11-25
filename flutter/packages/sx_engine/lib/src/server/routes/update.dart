import 'package:sx_api/sx_api.dart';

import '../../settings/open_on_computer.dart';
import '../../settings/update_check.dart';
import '../../settings/update_install.dart';
import '../engine.dart';
import '../lifetime.dart';

/// The update check and "update". Port of `/api/update` and
/// `/api/update/install`.
void registerUpdateRoutes(Engine e) {
  e.provide(UpdateChecker(current: e.config.appVersion));
  if (e.config.appExe case final exe?) e.provide(UpdateInstaller(appExe: exe));
  UpdateChecker checker() => e.find<UpdateChecker>()!;

  e.api.get('/api/update', (req) => checker().check(fresh: req.query['fresh'] != null));

  // Downloads and checks the installer, then asks the app to quit: the
  // installer starts once the engine has stopped, as the old server stopped
  // itself after answering.
  e.api.post('/api/update/install', phone: false, (req) async {
    final u = await checker().check();
    if (!u.ok || !u.newer || !u.asset.startsWith('https://github.com/')) return const ToolResult.failed('No newer version found on GitHub.');
    final installer = e.find<UpdateInstaller>();
    if (installer != null) {
      await installer.download(u);
      e.lifetime.quitFor(QuitReason.update);
      return const ToolResult(ok: true, extra: {'restarting': true});
    }
    // The engine on its own (development) has no installed app to replace, so
    // the release page opens in the browser instead.
    if (!u.page.startsWith('https://github.com/')) return const ToolResult.failed('No newer version found on GitHub.');
    await (e.find<Opener>() ?? const LaptopOpener()).open(u.page);
    return ToolResult(ok: true, out: '  Version ${u.latest} is on GitHub. Its page is open in the browser: download the installer there and run it.');
  });
}
