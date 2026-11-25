import '../engine.dart';
import 'auto.dart';
import 'remote.dart';
import 'speed.dart';
import 'sx.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerRemoteRoutes(e);
  registerAutoRoutes(e);
}
