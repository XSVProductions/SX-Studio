import '../engine.dart';
import 'aim.dart';
import 'lab.dart';
import 'live.dart';
import 'speed.dart';
import 'sx.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerLabRoutes(e);
  registerAimRoutes(e);
  registerLiveRoutes(e);
}
