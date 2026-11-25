import 'dart:io';

import '../../apc40/runner.dart';
import '../../settings/config_io.dart';
import '../../settings/open_on_computer.dart';
import '../../show/show_env.dart';
import '../../show/text_files.dart';
import '../../tools/apc40.dart';
import '../engine.dart';
import '../ps_body.dart';

/// Export and import SX Studio's settings as one file. Computer only: a
/// phone gets the old refusal as an `ok:false` answer, not the laptop-only
/// list's 403.
///
/// Port of `/api/config/export` and `/api/config/import` in `df_aim_gui.ps1`.
void registerConfigRoutes(Engine e) {
  e.provide(LastExport());

  // The APC40 tab's own file and checks (`tools/apc40.dart`), and its bridge.
  File layout() => apc40LayoutFile(e.settingsFolder);
  final apc40 = Apc40Part(
    readText: () {
      try {
        final f = layout();
        return f.existsSync() ? readText(f.path) : null;
      } on FileSystemException {
        return null;
      }
    },
    save: (raw) {
      try {
        saveApc40Layout(layout(), raw);
      } on ToolError {
        return false;
      } on FileSystemException {
        return false;
      }
      e.find<Apc40Runner>()?.send('reload');
      return true;
    },
  );

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
