import 'dart:io';

import 'desktop_sx_app.dart';
import 'sx_app.dart';

/// The ShowXpress on this computer. ShowXpress runs on Windows and macOS
/// only, so anywhere else it is never open.
SxApp defaultSxApp() => Platform.isWindows
    ? DesktopSxApp(WindowsSx())
    : Platform.isMacOS
    ? DesktopSxApp(MacSx())
    : const NoSxApp();
