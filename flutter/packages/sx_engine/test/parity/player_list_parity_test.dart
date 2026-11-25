import 'dart:io';

import 'package:sx_engine/src/player/player_show.dart';
import 'package:test/test.dart';

import 'parity.dart';

void main() {
  parityTest('list', script: 'player.ps1', args: {'List': true}, dart: playerList);

  parityTest(
    'list with a missing scene, a swap page and odd button keys',
    script: 'player.ps1',
    args: {'List': true},
    setup: (env) {
      final f = File(env.path('Live/live.ini'));
      final list = playerList(env);
      final pages = list['pages']! as List;
      final first = ((pages.first as Map)['buttons'] as List).first as Map;
      // the first button's file goes away, and a new page with odd keys is added
      File(first['path'] as String).deleteSync();
      f.writeAsStringSync(
        '${f.readAsStringSync()}\r\n[page99]\r\nname = ODD\r\nswap = YES\r\n\r\n[page99_button2]\r\nline = 2\r\ncolumn = 1\r\nname = NOT THERE.GPJ\r\n'
        'speed = AUTO_BPM\r\nbeats = x\r\ncolor = 12\r\ntrigger_midi_note = 7\r\n\r\n[page99_button1]\r\nline = 1\r\ncolumn = 3\r\nname = ${first['file']}\r\n'
        'title = \r\nbeats = 0.25\r\nbpm_trigger = Flash_Mode\r\n',
      );
    },
    dart: playerList,
  );
}
