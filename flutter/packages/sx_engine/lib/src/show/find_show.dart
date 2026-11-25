import 'dart:io';

import 'package:path/path.dart' as p;

import 'show_env.dart';
import 'text_files.dart';

/// The user's home folder.
String get homeDir => Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';

/// Where SX Studio keeps its own settings. The same folders the old app used,
/// so an existing install's settings carry over.
String get settingsDir => Platform.isWindows ? p.join(Platform.environment['APPDATA'] ?? homeDir, 'ShowXpress Helper') : p.join(homeDir, 'AwaazTools');

bool _isShow(String dir) => File(p.join(dir, 'Live', 'live.ini')).existsSync();

/// Finds the show folder:
///  1. the path in `show_path.txt` in the settings folder
///  2. `~/TheLightingController/LightShows/Awaaz Lightshow`
///  3. the only show in LightShows that has a CENTER SPOT scene
///
/// Port of `Find-Show` in `show_common.ps1`.
String findShow() {
  final pathFiles = [
    p.join(settingsDir, 'show_path.txt'),
    if (Platform.isWindows) p.join(Platform.environment['APPDATA'] ?? homeDir, 'AIM MOVERS', 'show_path.txt'),
  ];
  for (final pf in pathFiles) {
    if (!File(pf).existsSync()) continue;
    final lines = readLines(pf);
    final dir = lines.isEmpty ? '' : lines.first.trim();
    if (dir.isNotEmpty && _isShow(dir)) return dir;
  }
  final shows = p.join(homeDir, 'TheLightingController', 'LightShows');
  final usual = p.join(shows, 'Awaaz Lightshow');
  if (_isShow(usual)) return usual;
  if (Directory(shows).existsSync()) {
    final found = Directory(
      shows,
    ).listSync().whereType<Directory>().where((d) => _isShow(d.path) && File(p.join(d.path, 'scenes', 'CENTER SPOT.scex')).existsSync()).toList();
    if (found.length == 1) return found.single.path;
  }
  if (Platform.isMacOS) {
    throw ToolError(
      'Mac show folder not found. Copy the show from Google Drive > AWAAZ > Lighting into ~/TheLightingController/LightShows, '
      'or write its folder path into ~/AwaazTools/show_path.txt. NOTHING was changed.',
    );
  }
  throw ToolError("Can't find the show. Write its folder path into ${pathFiles.first} and try again. NOTHING was changed.");
}
