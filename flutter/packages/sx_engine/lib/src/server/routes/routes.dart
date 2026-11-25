import '../engine.dart';
import 'gdrive.dart';
import 'phone.dart';
import 'settings.dart';
import 'speed.dart';
import 'sx.dart';
import 'update.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerSettingsRoutes(e);
  registerPhoneRoutes(e);
  registerGdriveRoutes(e);
  registerUpdateRoutes(e);
}
