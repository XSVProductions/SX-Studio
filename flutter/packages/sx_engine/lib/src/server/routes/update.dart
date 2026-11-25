import 'package:sx_api/sx_api.dart';

import '../../settings/open_on_computer.dart';
import '../../settings/update_check.dart';
import '../engine.dart';

/// The update check, and "update", which for now opens the release page.
void registerUpdateRoutes(Engine e) {
  e.provide(UpdateChecker(current: e.config.appVersion));
  UpdateChecker checker() => e.find<UpdateChecker>()!;

  e.api.get('/api/update', (req) => checker().check(fresh: req.query['fresh'] != null));

  // The new app's installer isn't decided yet, so nothing is downloaded or
  // run: the release page opens in the browser and the user takes it from there.
  e.api.post('/api/update/install', phone: false, (req) async {
    final u = await checker().check();
    if (!u.ok || !u.newer || !u.asset.startsWith('https://github.com/') || !u.page.startsWith('https://github.com/')) {
      return const ToolResult.failed('No newer version found on GitHub.');
    }
    await (e.find<Opener>() ?? const LaptopOpener()).open(u.page);
    return ToolResult(ok: true, out: '  Version ${u.latest} is on GitHub. Its page is open in the browser: download the installer there and run it.');
  });
}
