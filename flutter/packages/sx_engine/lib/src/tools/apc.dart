import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';

// APC MINI: which live button each APC mini mk2 pad plays, and moving,
// swapping and clearing pad mappings. Pads: bottom row = notes 0-7, top row =
// 56-63. A move changes the trigger note and the light (midiout) note
// together, so the pad colours move with it. Only live.ini changes. Only MIDI
// device 0 is the APC mini: buttons and faders on another controller are left alone.
//
// Port of `apc.ps1`.

final _wholeNumber = RegExp(r'^-?\d+$');

/// `Get-Int` in the old tools: a whole number from live.ini, or [def] when
/// the value is missing or not a number.
int iniInt(String? v, [int def = -1]) => v != null && _wholeNumber.hasMatch(v) ? int.parse(v) : def;

/// What the APC mini screen shows. Writes nothing.
ApcPreview apcPreview(ShowEnv env) {
  final info = LiveInfo.read(env);
  final pads = [
    for (final b in info.buttons)
      // A button on another controller (device 1 and up, the APC40) isn't an APC mini pad.
      if (b.keys.containsKey('trigger_midi_note') && iniInt(b.keys['trigger_midi_device'], 0) == 0)
        ApcPad(
          sec: b.sec,
          page: b.page,
          pageName: b.pageName,
          title: b.title,
          scene: b.name,
          sceneOk: scenePath(env, b.name) != null,
          note: iniInt(b.keys['trigger_midi_note']),
          type: iniInt(b.keys['trigger_midi_type'], 0),
          channel: iniInt(b.keys['trigger_midi_channel'], 1),
          device: iniInt(b.keys['trigger_midi_device'], 0),
          outNote: iniInt(b.keys['trigger_midiout_note']),
          on: iniInt(b.keys['trigger_midiout_data']),
          off: iniInt(b.keys['trigger_midiout_data_off']),
          color: iniInt(b.keys['color']),
          key: b.keys['trigger_keyboard'] ?? '',
        ),
  ];
  final faderKey = RegExp(r'^fader(\d+)_midi_note$', caseSensitive: false);
  int num(String k) => int.parse(k.replaceAll(RegExp(r'\D'), ''));
  final keys = psSorted<String>(info.live.keys.where(faderKey.hasMatch), [num]);
  final faders = [
    for (final k in keys)
      // A fader on another controller is left out.
      if (iniInt(info.live['fader${num(k)}_midi_device'], 0) == 0)
        () {
          final n = num(k), mf = n - 1;
          // PowerShell reads index -1 as the last fader, so fader0 shows the last caption.
          final i = mf < 0 ? info.faders.length + mf : mf;
          return ApcFader(
            n: n,
            cc: iniInt(info.live[k]),
            type: iniInt(info.live['fader${n}_midi_type']),
            channel: iniInt(info.live['fader${n}_midi_channel']),
            caption: mf < info.faders.length && i >= 0 ? info.faders[i].caption : '',
          );
        }(),
  ];
  return ApcPreview(show: env.root, pads: pads, faders: faders, buttons: info.buttons.length);
}

/// Moves, swaps and clears pad mappings and sets pad colours. Returns the
/// report text.
String apcApply(ShowEnv env, List<ApcChange> changes) {
  final info = LiveInfo.read(env);
  env.requireSxClosed();
  if (changes.isEmpty) throw ToolError('No changes were sent. NOTHING was changed.');
  final bySec = psMap<LiveButton>();
  for (final b in info.buttons) {
    bySec[b.sec] = b;
  }
  final touched = psMap<int>();
  final colors = psMap<Map<String, int>>();
  for (final c in changes) {
    final b = bySec[c.sec];
    if (b == null || !psEq(b.title, c.title)) {
      throw ToolError('The show changed since this page was loaded (${c.title}). Press Refresh and try again. NOTHING was changed.');
    }
    if (!b.keys.containsKey('trigger_midi_note')) throw ToolError("${b.title} isn't on a pad. NOTHING was changed.");
    if (iniInt(b.keys['trigger_midi_device'], 0) != 0) {
      throw ToolError('${b.title} is on another MIDI controller, not the APC mini. NOTHING was changed.');
    }
    final n = c.note;
    if (n != -1 && (n < 0 || n > 63)) throw ToolError('Pad note $n is not on the 8x8 grid. NOTHING was changed.');
    if (n != -1 && iniInt(b.keys['trigger_midi_type'], 0) != 0) {
      throw ToolError('${b.title} is mapped to a MIDI controller, not a note - it can only be removed. NOTHING was changed.');
    }
    touched[b.sec] = n;
    for (final (w, v) in [('on', c.on), ('off', c.off)]) {
      if (v == null) continue;
      if (v < 0 || v > 127) throw ToolError('Pad colour $v is not 0-127. NOTHING was changed.');
      colors.putIfAbsent(b.sec, () => {})[w] = v;
    }
  }

  // No two buttons may end up on the same pad.
  final finalPads = <int, LiveButton>{};
  for (final b in info.buttons) {
    if (!b.keys.containsKey('trigger_midi_note')) continue;
    final n = touched[b.sec] ?? iniInt(b.keys['trigger_midi_note']);
    if (n < 0 || n > 63 || iniInt(b.keys['trigger_midi_type'], 0) != 0 || iniInt(b.keys['trigger_midi_device'], 0) != 0) continue;
    final there = finalPads[n];
    if (there != null && (touched.containsKey(b.sec) || touched.containsKey(there.sec))) {
      throw ToolError('Two buttons would be on the same pad (${there.title} and ${b.title}). NOTHING was changed.');
    }
    finalPads[n] = b;
  }

  final ini = info.ini;
  final out = <String>[];
  for (final MapEntry(key: sec, value: n) in touched.entries) {
    final b = bySec[sec]!, old = iniInt(b.keys['trigger_midi_note']);
    if (n == -1) {
      ini.removeKeys(sec, r'^trigger_midi(out)?_');
      out.add('  removed from the pads: ${b.title} (${b.pageName})');
    } else if (n != old) {
      ini.setKey(sec, 'trigger_midi_note', '$n');
      if (b.keys.containsKey('trigger_midiout_note')) ini.setKey(sec, 'trigger_midiout_note', '$n');
      out.add('  moved: ${b.title} (${b.pageName}) -> row ${8 - n ~/ 8}, column ${n % 8 + 1}  (note $old -> $n)');
    }
    final cl = colors[sec];
    if (n != -1 && cl != null) {
      if (!b.keys.containsKey('trigger_midiout_note')) {
        // Pad light not set up yet. APC mini mk2: the trigger's device, channel 7 (full brightness), the pad's own note.
        const after = ['trigger_midi_note', 'trigger_midiout_device', 'trigger_midiout_channel', 'trigger_midiout_type'];
        ini.setKey(sec, 'trigger_midiout_device', '${iniInt(b.keys['trigger_midi_device'], 0)}', after: after);
        ini.setKey(sec, 'trigger_midiout_channel', '7', after: after);
        ini.setKey(sec, 'trigger_midiout_type', '0', after: after);
        ini.setKey(sec, 'trigger_midiout_note', '$n', after: after);
      }
      final msg = <String>[];
      if (cl.containsKey('on')) {
        ini.setKey(sec, 'trigger_midiout_data', '${cl['on']}', after: const ['trigger_midiout_note']);
        msg.add('playing ${cl['on']}');
      }
      if (cl.containsKey('off')) {
        ini.setKey(sec, 'trigger_midiout_data_off', '${cl['off']}', after: const ['trigger_midiout_data', 'trigger_midiout_note']);
        msg.add('idle ${cl['off']}');
      }
      out.add('  pad colour: ${b.title} (${b.pageName}) -> ${msg.join(', ')}');
    }
  }
  if (!ini.save()) return '  nothing to change.';
  return ['  live.ini saved - ${out.length} pad change(s)', ...out].join('\n');
}
