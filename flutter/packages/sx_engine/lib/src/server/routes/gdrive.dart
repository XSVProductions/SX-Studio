import '../../show/show_env.dart';
import '../../tools/gdrive.dart';
import '../api.dart';
import '../engine.dart';

/// The show and this computer's Google Drive. With no show here yet, the
/// show on Google Drive picks the folder an import would fill.
({ShowEnv env, DrivePlaces at}) driveSetup(Engine e) {
  final found = findDrive(e.settingsFolder);
  ShowEnv env;
  try {
    env = e.show();
  } on ToolError catch (err) {
    env = ShowEnv(showFromDrive(found.my, err), sxRunning: () => e.sx.running);
  }
  return (env: env, at: drivePlaces(found, env.root, e.settingsFolder));
}

/// The show folder as the Google Drive card names it.
ShowEnv driveShow(Engine e) => driveSetup(e).env;

/// Google Drive sync and import.
void registerGdriveRoutes(Engine e) {
  e.api.get('/api/gdrive', (req) {
    final d = driveSetup(e);
    return drivePreview(d.env, d.at);
  });

  e.api.post('/api/gdrive/sync', queue: const Queueable('Sync to Google Drive'), (req) {
    final d = driveSetup(e);
    return driveSync(d.env, d.at);
  });

  e.api.post('/api/gdrive/import', queue: const Queueable('Import from Google Drive'), (req) {
    final d = driveSetup(e);
    return driveImport(d.env, d.at);
  });
}
