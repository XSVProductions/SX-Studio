import '../engine.dart';
import 'gdrive.dart';
import 'phone.dart';
import 'settings.dart';
import 'move.dart';
import 'lab.dart';
import 'color.dart';
import 'looks.dart';
import 'apc.dart';
import 'health.dart';
import 'preshow.dart';
import 'aim.dart';
import 'live.dart';
import 'scene.dart';
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
  registerMoveRoutes(e);
  registerLabRoutes(e);
  registerColorRoutes(e);
  registerLooksRoutes(e);
  registerApcRoutes(e);
  registerHealthRoutes(e);
  registerPreshowRoutes(e);
  registerAimRoutes(e);
  registerLiveRoutes(e);
  registerSceneRoutes(e);
}
