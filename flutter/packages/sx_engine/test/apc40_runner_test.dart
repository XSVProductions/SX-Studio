import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'sx_test_show.dart';

// The bridge on its own isolate, without an APC40 (the old -NoMidi), against
// a fake ShowXpress on a real TCP port: start, commands, status, restarts and
// stopping, as the old server's APC40 block did them.

/// Waits up to 10 s for [ok].
Future<void> until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late SxTestShow t;
  late File layout;
  var now = DateTime(2026, 11, 25, 20);
  var open = true;
  Apc40Runner? made;

  Apc40Runner runner({bool enabled = true, String Function()? root}) =>
      made = Apc40Runner(enabled: enabled, showRoot: root ?? () => t.root, layoutFile: () => layout, sxRunning: () => open, noMidi: true, clock: () => now);

  setUp(() async {
    t = await SxTestShow.create();
    layout = File(p.join(t.tmp.path, 'settings', 'apc40.json'));
    saveApc40Layout(layout, {
      'pages': [
        {
          'name': 'Main',
          'pads': {'0': 'RED', '1': 'BLUE'},
        },
      ],
    });
    open = true;
  });

  tearDown(() async {
    // the fake ShowXpress first: it doesn't expect a client to hang up while it answers
    await t.sx.close();
    await made?.stop();
    made = null;
    await t.dispose();
  });

  test('starts, connects, plays pads and faders, reloads, and stops with a last status', () async {
    final r = runner();
    expect(r.status(), isNull);
    r.step();
    await until(() => r.status()?.sx == 'ok', 'ShowXpress');
    final s = r.status()!;
    expect(s.running, true);
    expect(s.apc, 'sim');
    expect(s.pageName, 'Main');
    expect(r.alive, true);
    expect(r.busy, false, reason: 'only a real APC40 keeps SX Studio from quitting');
    expect(t.sx.log.first, 'HELLO|SX Studio APC40|pw');

    expect(r.send('pad 0'), true);
    await until(() => t.sx.pressed.contains('RED'), 'the press');
    r.send('fader 1 127');
    await until(() => t.sx.log.contains('FADER_CHANGE|0|99'), 'the fader');

    saveApc40Layout(layout, {
      'pages': [
        {'name': 'Other'},
      ],
    });
    r.send('reload');
    await until(() => r.status()?.pageName == 'Other', 'the reload');

    await t.sx.close();
    await r.stop();
    expect(r.alive, false);
    await until(() => r.status()?.apc == 'stopped', 'the last status');
    expect(r.status()!.running, false);
    expect(r.send('reload'), false);
  });

  test('a bridge that ended is started again, at most every 20 s, with no status until its first', () async {
    open = false; // no connection to ShowXpress needed here
    final r = runner();
    r.step();
    await until(() => r.status() != null, 'the first status');
    r.send('q');
    await until(() => !r.alive, 'the end');
    await until(() => r.status()?.apc == 'stopped', 'the last status');
    expect(r.status()!.running, false);
    now = now.add(const Duration(seconds: 19));
    r.step();
    expect(r.alive, false);
    now = now.add(const Duration(seconds: 1));
    r.step();
    expect(r.status(), isNull);
    await until(() => r.alive && r.status()?.running == true, 'the restart');
  });

  test('tells the bridge when ShowXpress opens and closes', () async {
    open = false;
    final r = runner();
    r.step();
    await until(() => r.status()?.sx == 'closed', 'closed');
    open = true;
    r.step();
    // the bridge asks again 3 s after its last try
    await until(() => r.status()?.sx == 'ok', 'connected');
  });

  test('nothing starts when it is not enabled, or before there is a show', () async {
    final off = runner(enabled: false);
    off.step();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(off.alive, false);
    expect(off.status(), isNull);
    expect(off.busy, false);
    await off.stop();

    var tries = 0;
    final r = runner(
      root: () {
        tries++;
        throw ToolError('No show.');
      },
    );
    r.step();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    r.step();
    expect(tries, 1);
    expect(r.alive, false);
    now = now.add(const Duration(seconds: 20));
    r.step();
    expect(tries, 2);
  });

  test('the TCP link: text as it comes, null once ShowXpress hangs up, and no writing after', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    server.listen(accepted.complete);
    final link = (await TcpSxLink.connect(server.port))!;
    final s = await accepted.future;
    expect(link.read(), '');
    link.write('HELLO|x|y\r\n');
    s.add(utf8.encode('HEL'));
    s.add([0xC3]); // half of a two-byte character
    await Future<void>.delayed(const Duration(milliseconds: 50));
    s.add([0xA9, ...utf8.encode('LO\r\n')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    var got = '';
    got += link.read()!;
    expect(got, 'HELéLO\r\n');
    await s.close();
    await until(() => link.read() == null, 'the hang up');
    expect(() => link.write('x\r\n'), throwsA(isA<SocketException>()));
    link.close();
    await server.close();
    expect(await TcpSxLink.connect(server.port), isNull);
  });
}
