import 'package:sx_api/sx_api.dart';

/// ShowXpress itself, as far as the engine needs it: is it open, open it,
/// close it. Only one program can hold the DMX interface and ShowXpress
/// rewrites the show when it closes, so most tools ask [running] first.
abstract interface class SxApp {
  bool get running;

  Future<ToolResult> launch();

  /// Asks ShowXpress to close. [force] kills it without letting it save.
  Future<ToolResult> close({bool force = false});
}

/// A machine without ShowXpress (tests, Linux): never running.
class NoSxApp implements SxApp {
  const NoSxApp();

  @override
  bool get running => false;

  @override
  Future<ToolResult> launch() async => const ToolResult.failed('ShowXpress is not installed on this computer.');

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}
