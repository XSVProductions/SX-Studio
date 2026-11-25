import 'package:sx_api/sx_api.dart';

import '../../show/show_env.dart';
import '../../tools/flip.dart';
import '../../tools/rig.dart';
import '../../tools/rig_test.dart';
import '../../tools/skip_flash.dart';
import '../api.dart';
import '../engine.dart';

final _digits = RegExp(r'^\d+$');

/// Tonight's Rig (with Reverse Heads), Skip Flash and Rig Test.
///
/// Port of their cases in `Invoke-Action` and the request loop of `df_aim_gui.ps1`.
void registerRigRoutes(Engine e) {
  e.api.get('/api/rig', (req) => rigPreview(e.show()));
  e.api.get('/api/skip', (req) => skipPreview(e.show()));
  e.api.get('/api/rt', (req) => rtPreview(e.show()));

  e.api.post('/api/skip/apply', queue: const Queueable('Skip Flash'), (req) {
    final ids = req.body.strList('heads');
    if (ids.any((i) => !_digits.hasMatch(i)) || ids.length < 2) throw ToolError('Pick at least 2 heads.');
    return skipApply(e.show(), ids);
  });

  e.api.post('/api/rig/apply', queue: const Queueable("Tonight's Rig"), (req) {
    final ids = req.body.strList('heads');
    if (ids.any((i) => !_digits.hasMatch(i)) || ids.isEmpty) throw ToolError('Tick at least one head.');
    final env = e.show();
    // Reversed heads are saved from this tab too, always the full list, so a
    // queued save that replaces an older one keeps it
    var fo = '';
    final flipBody = req.body.objOrNull('flip');
    if (flipBody != null) {
      final flip = <String, Flip>{};
      for (final MapEntry(:key, :value) in flipBody.entries) {
        if (!_digits.hasMatch(key)) throw ToolError('Unknown head.');
        final v = value is Map ? value.cast<String, Object?>() : const <String, Object?>{};
        final pan = _truthy(v['pan']), tilt = _truthy(v['tilt']);
        if (pan || tilt) flip[key] = (pan: pan, tilt: tilt);
      }
      final String fout;
      try {
        fout = flipApply(env, flip);
      } on ToolError catch (x) {
        throw ToolError('Reversed heads NOT saved (nothing was changed): ${x.message}');
      }
      if (!fout.contains('nothing to change')) fo = "  Reversed heads:\n${fout.trimRight()}\n\n  Tonight's Rig:\n";
    }
    final String out;
    try {
      out = rigApply(env, ids);
    } on ToolError catch (x) {
      if (fo.isEmpty) rethrow;
      return ToolResult(ok: false, out: fo, error: "The reversed heads WERE saved, but Tonight's Rig was not: ${x.message}");
    }
    return '$fo$out\n${_updateSkipFlash(env, ids)}';
  });

  e.api.post('/api/rt/install', queue: const Queueable('RIG ID button'), (req) => rtInstall(e.show()));

  e.api.post('/api/rt/apply', queue: const Queueable('Rig Test (2D view)'), (req) {
    final assign = <String, String>{};
    final slot = RegExp(r'^(tl|tr|tm|bl|br|bm)-(l|r)$', caseSensitive: false);
    for (final MapEntry(:key, :value) in req.body.obj('assign').entries) {
      final id = value == null ? '' : '$value';
      if (slot.hasMatch(key) && _digits.hasMatch(id)) assign[key] = id;
    }
    if (assign.isEmpty) throw ToolError('Put at least one mover on a truss.');
    final env = e.show();
    var out = rtApply(env, assign, extra: _truthy(req.body['extra']));
    if (_truthy(req.body['rig'])) {
      String? last(String prefix) => out.split('\n').where((l) => RegExp('^$prefix: [\\d,]+\$').hasMatch(l)).lastOrNull?.substring(prefix.length + 2);
      final rigHeads = last('RIGHEADS');
      if (rigHeads != null) {
        try {
          out += "\n\n  Tonight's Rig:\n${rigApply(env, rigHeadIds([rigHeads]))}";
        } on ToolError catch (x) {
          out += "\n\n  Tonight's Rig NOT updated: ${x.message}";
        }
      }
      final skipHeads = last('SKIPHEADS');
      if (skipHeads != null) out += '\n${_updateSkipFlash(env, skipHeads.split(','))}';
    }
    return out;
  });
}

/// SKIP FLASH follows the hung heads too. It needs 2 or more.
///
/// Port of `Update-SkipFlash`. Starts with a line break, like the old one.
String _updateSkipFlash(ShowEnv env, List<String> heads) {
  final ids = heads.where(_digits.hasMatch).toList();
  if (ids.length < 2) return '\n  SKIP FLASH not changed (it needs at least 2 heads)';
  final String out;
  try {
    out = skipApply(env, ids);
  } on ToolError catch (x) {
    return '\n  SKIP FLASH NOT updated: ${x.message}';
  }
  return out.contains('nothing to change') ? '\n  SKIP FLASH already flashes these ${ids.length} heads' : '\n  SKIP FLASH now flashes ${ids.length} heads';
}

/// PowerShell's `[bool]` of a JSON value.
bool _truthy(Object? v) => switch (v) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  List l => l.isNotEmpty,
  _ => true,
};
