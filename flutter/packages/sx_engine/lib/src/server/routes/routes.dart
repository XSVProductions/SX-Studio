import '../engine.dart';
import 'apc.dart';
import 'health.dart';
import 'preshow.dart';
import 'speed.dart';
import 'sx.dart';

/// Every area's routes. One line per area, each in its own file.
void registerRoutes(Engine e) {
  registerSxRoutes(e);
  registerSpeedRoutes(e);
  registerApcRoutes(e);
  registerHealthRoutes(e);
  registerPreshowRoutes(e);
}
