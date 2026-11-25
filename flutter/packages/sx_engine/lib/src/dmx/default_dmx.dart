import 'dart:io';

import 'package:path/path.dart' as p;

import 'dmx_output.dart';
import 'helper_dmx.dart';

/// This computer's real DMX output: Chauvet's driver from the ShowXpress
/// install. A computer that is neither Windows nor a Mac has no driver, so it
/// gets the fake output (development and tests).
///
/// Windows: the folder of `TheLightingController.exe` (`Get-SxExe`), 64-bit
/// Program Files first. When ShowXpress isn't found the driver is looked for
/// in `%ProgramFiles%\ShowXpress`, as the old player's default was, and the
/// error names that folder.
///
/// Mac: the folder `TheLightingController.app` is in (`Find-SxMacApp`). When
/// ShowXpress isn't found the folder is '' and opening says so.
DmxSpec defaultDmxSpec() {
  if (Platform.isWindows) {
    final env = Platform.environment;
    for (final pf in [env['ProgramW6432'], env['ProgramFiles'], env['ProgramFiles(x86)']]) {
      if (pf == null || pf.isEmpty) continue;
      final dir = p.join(pf, 'ShowXpress');
      if (File(p.join(dir, 'TheLightingController.exe')).existsSync()) return EfkDmxSpec(dir);
    }
    return EfkDmxSpec(p.join(env['ProgramFiles'] ?? r'C:\Program Files', 'ShowXpress'));
  }
  if (Platform.isMacOS) return EfkDmxSpec(findSxMacFolder() ?? '');
  return const FakeDmxSpec();
}
