import '../engine.dart';
import 'move.dart';
import 'lab.dart';
import 'color.dart';
import 'looks.dart';
import 'speed.dart';
import 'sx.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerMoveRoutes(e);
  registerLabRoutes(e);
  registerColorRoutes(e);
  registerLooksRoutes(e);
}
