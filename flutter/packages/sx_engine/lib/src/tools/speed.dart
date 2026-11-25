import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';

// SPEED FADERS: which master speed fader (MOVEMENTS, COLORS, STROBES...) each
// live button follows. live.ini key `masterspeedfader = K` (0 = first fader).
// A button without the key follows fader 0. Only live.ini changes.
//
// Port of `speed.ps1`.

final _digits = RegExp(r'^\d+$');

/// What the Speed Faders screen shows. Writes nothing.
SpeedPreview speedPreview(ShowEnv env) {
  final info = LiveInfo.read(env);
  final sorted = psSorted<LiveButton>(info.buttons, [(b) => b.page, (b) => psInt(b.keys['line']), (b) => psInt(b.keys['column'])]);
  return SpeedPreview(
    show: env.root,
    faders: info.faders,
    buttons: [
      for (final b in sorted)
        () {
          final path = scenePath(env, b.name);
          final isScene = path != null && path.toLowerCase().endsWith('.scex');
          final fader = b.keys['masterspeedfader'] ?? '';
          return SpeedButton(
            sec: b.sec,
            page: b.page,
            pageName: b.pageName,
            title: b.title,
            scene: b.name,
            fader: _digits.hasMatch(fader) ? int.parse(fader) : 0,
            hasKey: b.keys.containsKey('masterspeedfader'),
            steps: isScene ? RegExp(r'<Step\b').allMatches(readText(path)).length : -1,
            gen: b.name.toLowerCase().endsWith('.gpj'),
            beat: psEq(b.keys['speed'] ?? '', 'auto_bpm'),
            missing: path == null,
          );
        }(),
    ],
  );
}

/// Points buttons at master faders. Returns the report text.
String speedApply(ShowEnv env, List<SpeedChange> changes) {
  final info = LiveInfo.read(env);
  env.requireSxClosed();
  if (changes.isEmpty) throw ToolError('No changes were sent. NOTHING was changed.');
  final bySec = {for (final b in info.buttons) b.sec.toLowerCase(): b};
  final captions = {for (final f in info.faders) f.k: f.caption};
  final out = <String>[];
  for (final c in changes) {
    final b = bySec[c.sec.toLowerCase()];
    if (b == null || !psEq(b.title, c.title)) {
      throw ToolError('The show changed since this page was loaded (${c.title}). Press Refresh and try again. NOTHING was changed.');
    }
    if (!captions.containsKey(c.fader)) throw ToolError('There is no master fader number ${c.fader}. NOTHING was changed.');
    // ShowXpress writes the key after name/title/color/speed/bpm_trigger
    info.ini.setKey(b.sec, 'masterspeedfader', '${c.fader}', after: const ['line', 'column', 'name', 'title', 'imgpath', 'color', 'speed', 'bpm_trigger']);
    out.add('  ${b.title} (${b.pageName}) -> ${captions[c.fader]}');
  }
  if (!info.ini.save()) return '  nothing to change.';
  return ['  live.ini saved - ${out.length} button(s)', ...out].join('\n');
}
