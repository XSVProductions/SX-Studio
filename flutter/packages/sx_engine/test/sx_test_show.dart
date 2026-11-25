import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';

import 'fake_sx_remote.dart';

const _liveIni =
    '[live]\r\nallow_live_mobile = yes\r\nlive_mobile_password = pw\r\nmaster_faders = 0\r\n\r\n'
    '[page1]\r\nname = MOVEMENTS\r\nswap = yes\r\nlive_mobile = yes\r\nnb_buttons = 2\r\n\r\n'
    '[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CIRCLE.gpj\r\ntitle = CIRCLE\r\n\r\n'
    '[page1_button2]\r\nline = 1\r\ncolumn = 2\r\nname = FIGURE 8.gpj\r\ntitle = FIGURE 8\r\n\r\n'
    '[page2]\r\nname = COLORS\r\nlive_mobile = yes\r\nnb_buttons = 2\r\n\r\n'
    '[page2_button1]\r\nline = 1\r\ncolumn = 1\r\nname = RED.scex\r\ntitle = RED\r\n\r\n'
    '[page2_button2]\r\nline = 1\r\ncolumn = 2\r\nname = BLUE.scex\r\ntitle = BLUE\r\n\r\n'
    '[page3]\r\nname = SETUP\r\nlive_mobile = yes\r\nnb_buttons = 1\r\n\r\n'
    '[page3_button1]\r\nline = 1\r\ncolumn = 1\r\nname = RIG ID.scex\r\ntitle = RIG ID\r\n';

/// A small show laid out like ShowXpress's own folders
/// (`<tmp>/TheLightingController/LightShows/Test Show`, with param.ini two
/// levels up), its remote switched on and pointing at a [FakeSxRemote].
class SxTestShow {
  SxTestShow._(this.tmp, this.root, this.sx);

  static Future<SxTestShow> create() async {
    final tmp = Directory.systemTemp.createTempSync('sx_auto_');
    final root = p.join(tmp.path, 'TheLightingController', 'LightShows', 'Test Show');
    Directory(p.join(root, 'Live')).createSync(recursive: true);
    File(p.join(root, 'Live', 'live.ini')).writeAsStringSync(_liveIni);
    final sx = await FakeSxRemote.start(password: 'pw');
    File(paramIniPath(ShowEnv(root))).writeAsStringSync('[Network]\r\nLIVEMOBILEENABLE = yes\r\nLIVEMOBILEPORT = ${sx.port}\r\n');
    sx.buttons = [
      FakeButton('MOVEMENTS', 'CIRCLE'),
      FakeButton('MOVEMENTS', 'FIGURE 8'),
      FakeButton('COLORS', 'RED'),
      FakeButton('COLORS', 'BLUE'),
      FakeButton('SETUP', 'RIG ID'),
    ];
    return SxTestShow._(tmp, root, sx);
  }

  final Directory tmp;
  final String root;
  final FakeSxRemote sx;

  /// Sets ShowXpress open or closed for [env].
  var open = true;

  ShowEnv env() => ShowEnv(root, sxRunning: () => open);

  void writeLooks(String json) => File(p.join(root, 'auto_show.json')).writeAsStringSync(json);

  Future<void> dispose() async {
    await sx.close();
    tmp.deleteSync(recursive: true);
  }
}
