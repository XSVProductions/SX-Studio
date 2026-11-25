import '../../settings/config_io.dart';
import '../../settings/open_on_computer.dart';
import '../engine.dart';
import '../ps_body.dart';

/// Export and import SX Studio's settings as one file. Computer only: a
/// phone gets the old refusal as an `ok:false` answer, not the laptop-only
/// list's 403.
///
/// Port of `/api/config/export` and `/api/config/import` in `df_aim_gui.ps1`.
void registerConfigRoutes(Engine e) {
  e.provide(LastExport());

  // TODO(merge): connect the APC40 tab's functions from `tools/apc40.dart`:
  //   readText: the text of `apc40LayoutFile(e.settingsFolder)` when it exists, else null.
  //   save: `saveApc40Layout(apc40LayoutFile(e.settingsFolder), raw)`, true when it
  //   returns, false on `ToolError`, then have the bridge reload the layout.
  // `readApc40Layout(File)` and `cleanApc40Layout(Json?)` are the APC40 tab's own
  // reader and checks, which `saveApc40Layout` uses.
  final apc40 = Apc40Part(readText: () => null, save: (raw) => false);

  e.api.post('/api/config/export', (req) {
    if (req.fromPhone) return {'ok': false, 'error': 'Export the settings on the computer.'};
    final folders = e.find<ExportFolders>()?.dirs ?? downloadFolders(e.settingsFolder);
    return saveConfigExport(e, apc40, field(req.body, 'device'), folders: folders);
  });

  e.api.post('/api/config/import', (req) {
    if (req.fromPhone) return {'ok': false, 'error': 'Import the settings on the computer.'};
    return importConfig(e, apc40, field(req.body, 'data'));
  });
}
