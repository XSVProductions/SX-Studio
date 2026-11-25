import '../engine.dart';
import 'auto.dart';
import 'remote.dart';
import 'gdrive.dart';
import 'phone.dart';
import 'settings.dart';
import 'lab.dart';
import 'color.dart';
import 'looks.dart';
import 'apc.dart';
import 'health.dart';
import 'preshow.dart';
import 'speed.dart';
import 'sx.dart';
import 'update.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerRemoteRoutes(e);
  registerAutoRoutes(e);
  registerSettingsRoutes(e);
  registerPhoneRoutes(e);
  registerGdriveRoutes(e);
  registerUpdateRoutes(e);
  registerLabRoutes(e);
  registerColorRoutes(e);
  registerLooksRoutes(e);
  registerApcRoutes(e);
  registerHealthRoutes(e);
  registerPreshowRoutes(e);
}
