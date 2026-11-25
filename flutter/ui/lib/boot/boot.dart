import 'package:sx_api/sx_api.dart';

import 'boot_web.dart' if (dart.library.io) 'boot_io.dart' as impl;

/// Gets a client connected to the engine.
///
/// On the laptop this starts the engine inside the app, on its own isolate,
/// and connects to it. In a browser (a phone or tablet) the engine is the
/// laptop that served the page.
Future<SxClient> boot() => impl.boot();
