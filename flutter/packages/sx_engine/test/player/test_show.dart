import 'dart:io';

import 'package:path/path.dart' as p;

/// A tiny show for the player's tests. Page 1 swaps (RED, BLUE), page 2 has
/// a BPM button on pad 5 whose light is 3 when on and 1 when off.
Directory makeTestShow() {
  final d = Directory.systemTemp.createTempSync('sx_player_show_');
  void put(String rel, String text) {
    File(p.join(d.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  put('fixtures.ini', '[Fixture1]\r\naddress = 1\r\nid = 100\r\n');
  String scene(String steps) => '<?xml version="1.0" encoding="UTF-8"?>\n<Scene><Steps>$steps</Steps></Scene>';
  put('scenes/RED.scex', scene('<Step length="100"><Fixture id="100"><Channel index="0" value="255"/></Fixture></Step>'));
  put('scenes/BLUE.scex', scene('<Step length="100"><Fixture id="100"><Channel index="1" value="200"/></Fixture></Step>'));
  put(
    'scenes/BEAT.scex',
    scene(
      '<Step length="50"><Fixture id="100"><Channel index="2" value="10"/></Fixture></Step>'
      '<Step length="50"><Fixture id="100"><Channel index="2" value="20"/></Fixture></Step>',
    ),
  );
  put(
    'Live/live.ini',
    '[live]\r\nmaster_faders = 1\r\n\r\n[master_faders]\r\ncaption_fader0 = SPEED\r\ntype_fader0 = 1\r\n\r\n'
        '[page1]\r\nname = COLORS\r\nswap = yes\r\n\r\n'
        '[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = RED.scex\r\ntitle = RED\r\ntrigger_keyboard = r\r\n\r\n'
        '[page1_button2]\r\nline = 1\r\ncolumn = 2\r\nname = BLUE.scex\r\ntitle = BLUE\r\n\r\n'
        '[page2]\r\nname = BEATS\r\n\r\n'
        '[page2_button1]\r\nline = 1\r\ncolumn = 1\r\nname = BEAT.scex\r\ntitle = BEAT\r\nspeed = auto_bpm\r\nbeats = 1\r\n'
        'trigger_midi_type = 0\r\ntrigger_midi_channel = 1\r\ntrigger_midi_note = 5\r\n'
        'trigger_midiout_type = 0\r\ntrigger_midiout_channel = 1\r\ntrigger_midiout_note = 5\r\ntrigger_midiout_data = 3\r\ntrigger_midiout_data_off = 1\r\n',
  );
  return d;
}

/// The channels above 0 in a fake output's frame file.
Map<int, int> frameOf(File log) => {
  for (final l in log.existsSync() ? log.readAsLinesSync().where((l) => l.contains('=')) : const <String>[])
    int.parse(l.split('=')[0]): int.parse(l.split('=')[1]),
};

/// Waits until [ok] holds, or fails after [max].
Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 5), String? reason}) async {
  final end = DateTime.now().add(max);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
