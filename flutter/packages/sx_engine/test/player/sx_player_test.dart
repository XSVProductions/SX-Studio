import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'test_show.dart';

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  late Directory show;
  late File log;
  setUp(() {
    show = makeTestShow();
    log = File(p.join(show.path, '_dmx_frame.txt'));
  });
  tearDown(() => show.deleteSync(recursive: true));

  Future<SxPlayer> start({int os2l = 0}) async {
    final pl = await SxPlayer.start(PlayerConfig(show: show.path, dmx: FakeDmxSpec(log.path), os2lPort: os2l));
    addTearDown(pl.stop);
    return pl;
  }

  test('plays a button, swaps on a swap page, and goes dark on stop', () async {
    final pl = await start();
    expect(pl.iface, 'test interface');
    pl.send(const PressCommand('page1_button1'));
    await until(() => frameOf(log)[1] == 255, reason: 'RED on');
    pl.send(const PressCommand('page1_button2'));
    await until(() => frameOf(log)[2] == 200);
    expect(frameOf(log), {2: 200}, reason: 'BLUE released RED on the swap page');
    await until(() => pl.status?['on'] is List && (pl.status!['on']! as List).length == 1);
    expect(((pl.status!['on']! as List).single as Map)['slot'], 'page1_button2');

    pl.send(const BlackoutCommand(true));
    await until(() => frameOf(log).isEmpty, reason: 'blackout');
    pl.send(const BlackoutCommand(false));
    pl.send(const KeyCommand('R'));
    await until(() => frameOf(log)[1] == 255, reason: 'a keyboard trigger');

    await pl.stop();
    expect(pl.running, isFalse);
    expect(pl.stoppedByItself, isFalse);
    expect(log.readAsStringSync(), '', reason: 'lights out');
    expect(pl.send(const AllOffCommand()), isFalse);
  });

  test('a refusal goes into the status, like a bad stdin line did', () async {
    final pl = await start();
    pl.send(const TitleOnCommand('NOT A BUTTON'));
    await until(() => pl.status?['err'] == 'there is no button called NOT A BUTTON');
    pl.send(const PlayOn('x', '/nowhere/GONE.scex'));
    await until(() => '${pl.status?['err']}'.startsWith("GONE: Could not find file '/nowhere/GONE.scex'"));
  });

  test('an unplugged interface stops the frames, and it comes back by itself', () async {
    final pl = await start();
    pl.send(const PressCommand('page1_button1'));
    await until(() => frameOf(log)[1] == 255);
    final marker = File(p.join(show.path, '_iface_unplugged'))..writeAsStringSync('');
    await until(() => pl.status?['iface'] == 'lost');
    pl.send(const PressCommand('page1_button2'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(frameOf(log), {1: 255}, reason: 'nothing is sent while the interface is gone');
    marker.deleteSync();
    await until(() => pl.status?['iface'] == 'ok' && pl.status?['reconn'] == 1, max: const Duration(seconds: 6));
    await until(() => frameOf(log)[2] == 200, reason: 'frames again');
  });

  test('VirtualDJ over OS2L: beats set the tempo, btn presses by title', () async {
    final port = await _freePort();
    final pl = await start(os2l: port);
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    addTearDown(s.destroy);
    s.write('{"evt":"beat","bpm":128.5}junk{"evt":"btn","na');
    await s.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    s.write('me":"RED","state":"on"}');
    await s.flush();
    await until(() => pl.status?['os2lBeats'] == 1 && (pl.status!['on']! as List).isNotEmpty);
    final st = pl.status!;
    expect(st['src'], 'VirtualDJ');
    expect(st['bpm'], 128.5);
    expect(st['os2l'], '127.0.0.1');
    expect(st['os2lPort'], port);
    expect(frameOf(log)[1], 255);
    s.destroy();
    await until(() => pl.status?['os2l'] == '', reason: 'VirtualDJ gone');
  });

  test("the old player's start refusals", () async {
    File(p.join(show.path, 'fixtures.ini')).writeAsStringSync('[Fixture1]\r\nname = X\r\n');
    await expectLater(start(), throwsA(isA<DmxError>().having((e) => e.message, 'message', "No fixtures found in the show's fixtures.ini.")));
    File(p.join(show.path, 'fixtures.ini')).deleteSync();
    await expectLater(start(), throwsA(isA<DmxError>().having((e) => e.message, 'message', "The show's fixture list (fixtures.ini) was not found.")));
    File(p.join(show.path, 'fixtures.ini')).writeAsStringSync('[Fixture1]\r\naddress = 1\r\nid = 100\r\n');
    File(p.join(show.path, 'Live', 'live.ini')).deleteSync();
    await expectLater(
      start(),
      throwsA(
        isA<DmxError>().having((e) => e.message, 'message', "Could not read the show's live pages: Live/live.ini not found in the show. NOTHING was changed."),
      ),
    );
  });

  test('the show check warns about missing files at start', () async {
    File(p.join(show.path, 'scenes', 'BLUE.scex')).deleteSync();
    final pl = await start();
    await until(() => pl.status != null);
    expect(pl.status!['warn'], ['BLUE: its file is missing']);
  });

  test('OS2L objects are split the way the old player did', () {
    final got = <String>[];
    expect(splitJsonObjects('x{"a":"}{"}{"b":{"c":1}} {"d', got.add), '{"d');
    expect(got, ['{"a":"}{"}', '{"b":{"c":1}}']);
    expect(splitJsonObjects(r'{"e":"\"}"}', got.add), isNull);
    expect(got.last, r'{"e":"\"}"}');
  });
}
