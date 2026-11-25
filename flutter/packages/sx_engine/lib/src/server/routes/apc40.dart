import 'dart:io';

import '../../apc40/runner.dart';
import '../../show/show_env.dart';
import '../../tools/apc40.dart';
import '../engine.dart';
import '../ps_body.dart';

/// The APC40 tab, and the bridge that plays its pads. The bridge starts with
/// the engine on Windows (the engine's tick calls [Apc40Runner.step]) and
/// stops with it. Phones reach all three routes, as before.
///
/// Port of `/api/apc40*`, `Send-Apc40Json` and the APC40 block of `df_aim_gui.ps1`.
void registerApc40Routes(Engine e) {
  final runner = Apc40Runner(
    enabled: Platform.isWindows && e.config.showPath == null,
    showRoot: () => e.show().root,
    layoutFile: () => apc40LayoutFile(e.settingsFolder),
    sxRunning: () => e.sx.running,
  );
  e.provide<Apc40Runner>(runner);
  e.onStop(runner.stop);

  // the old server said false on a Mac only. The bridge runs on Windows only.
  final windows = Platform.isWindows;
  File layout() => apc40LayoutFile(e.settingsFolder);

  e.api.get('/api/apc40', (req) => apc40Info(e.show(), layout(), windows: windows, status: runner.status()));

  e.api.get('/api/apc40/status', (req) => {'ok': true, 'status': runner.status()?.toJson()});

  e.api.post('/api/apc40/save', (req) {
    var raw = req.body['layout'];
    if (!psTruthy(raw)) throw ToolError('Nothing to save.');
    // the old server piped it to ConvertTo-Json, which unwraps a list of one
    if (raw is List && raw.length == 1) raw = raw.first;
    final env = e.show();
    if (raw is! Map) throw ToolError('Nothing to save.');
    final saved = saveApc40Layout(layout(), raw.cast<String, Object?>());
    runner.send('reload');
    return apc40Info(env, layout(), layout: saved, windows: windows, status: runner.status());
  });
}
