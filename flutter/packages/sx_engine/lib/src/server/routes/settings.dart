import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../../settings/open_on_computer.dart';
import '../../settings/settings_store.dart';
import '../../show/show_env.dart';
import '../engine.dart';
import 'gdrive.dart' show driveShow;

/// Settings (the cogwheel) and "open on the computer".
void registerSettingsRoutes(Engine e) {
  final store = SettingsStore(e.settingsFolder);
  e.provide(store);
  e.queue.reopen = store.read().reopen;

  e.api.get('/api/settings', (req) => SettingsInfo(settings: store.read(), ver: e.config.appVersion, phone: req.fromPhone));

  e.api.post('/api/settings/set', (req) {
    final s = store.apply(req.body, fromPhone: req.fromPhone);
    if (!req.fromPhone) e.queue.reopen = s.reopen;
    return {'ok': true, 'settings': s};
  });

  e.api.post('/api/open', phone: false, (req) => openOnComputer(e, req.body.str('what')));
}

/// Opens one of a few known places on the laptop. Nothing else can be opened.
/// Port of `Open-OnComputer`.
Future<ToolResult> openOnComputer(Engine e, String what) async {
  final t = switch (what) {
    'show' => driveShow(e).root,
    'backups' => p.join(e.settingsFolder, 'backups'),
    'gddl' => 'https://www.google.com/drive/download/',
    'gdapp' =>
      Platform.isMacOS
          ? '/Applications/Google Drive.app'
          : Platform.isWindows
          ? p.join(Platform.environment['ProgramFiles'] ?? r'C:\Program Files', 'Google', 'Drive File Stream', 'launch.bat')
          : '',
    _ => '',
  };
  if (t.isEmpty) return const ToolResult.failed('Nothing to open.');
  if (!t.startsWith('https://') && FileSystemEntity.typeSync(t) == FileSystemEntityType.notFound) {
    return ToolResult.failed(switch (what) {
      'backups' => 'No import backups yet - one is made each time you import from Google Drive.',
      'gdapp' => "Google Drive for desktop isn't installed - press Get Google Drive.",
      _ => 'Not found: $t',
    });
  }
  try {
    await (e.find<Opener>() ?? const LaptopOpener()).open(t);
  } on ProcessException catch (x) {
    throw ToolError("Couldn't open $t (${x.message})");
  }
  return const ToolResult(ok: true);
}
