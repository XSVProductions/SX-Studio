import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

// The old server's (`df_aim_gui.ps1`) own checks, before a tool runs: who may
// call what, when a save is queued, and which request bodies are refused.

class _FakeSx implements SxApp {
  @override
  bool running = false;
  final closes = <bool>[];

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async {
    closes.add(force);
    running = false;
    return const ToolResult(ok: true);
  }
}

const _liveIni =
    '[live]\r\nmaster_faders = 2\r\n\r\n[master_faders]\r\ncaption_fader0 = MOVEMENTS\r\ntype_fader0 = 1\r\ncaption_fader1 = COLORS\r\ntype_fader1 = 1\r\n\r\n'
    '[page1]\r\nname = CHASES\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CHASE.scex\r\ntitle = CHASE\r\n';

/// A raw POST, so a test can send what the typed client never would.
Future<(int, String)> _post(int port, String path, Object? body, {String? token}) async {
  final http = HttpClient();
  try {
    final req = await http.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    if (token != null) req.headers.set('X-SX-Token', token);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body ?? const {}));
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    http.close();
  }
}

void main() {
  late Directory tmp;
  late String show, cfg;
  late _FakeSx sx;
  late Engine engine;
  late SxClient laptop, phone;
  late String phoneKey;

  Future<void> start() async {
    engine = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 'secret', showPath: show, settingsDir: cfg, dmx: const FakeDmxSpec()),
      sx: sx,
    );
    await engine.start();
    laptop = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'secret');
    engine.phones.setOn(true);
    engine.phones.newPin();
    phoneKey = engine.phones.pair(engine.phones.pin);
    await engine.setPhoneListener(true);
    phone = SxClient(Uri.parse('http://127.0.0.1:${engine.phonePort}'), token: phoneKey);
  }

  Future<void> stop() async {
    laptop.close();
    phone.close();
    await engine.stop();
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_old_checks_');
    show = p.join(tmp.path, 'show');
    cfg = p.join(tmp.path, 'cfg');
    Directory(p.join(show, 'Live')).createSync(recursive: true);
    File(p.join(show, 'Live', 'live.ini')).writeAsStringSync(_liveIni);
    sx = _FakeSx();
    await start();
  });

  tearDown(() async {
    await stop();
    tmp.deleteSync(recursive: true);
  });

  String ini() => File(p.join(show, 'Live', 'live.ini')).readAsStringSync();
  Future<Json> speed(Object? body) async {
    final (_, text) = await _post(engine.port, '/api/speed/apply', body, token: 'secret');
    return jsonDecode(text) as Json;
  }

  group('phone', () {
    test("a phone is kept off exactly the old server's six routes", () {
      final never = {
        for (final r in engine.api.routes)
          if (!r.phone) r.path,
      };
      expect(never, {'/api/update/install', '/api/phone', '/api/phone/set', '/api/phone/pin', '/api/phone/unpair', '/api/open'});
    });

    test('a laptop only route says so, before the key is looked at', () async {
      for (final token in [phoneKey, 'wrong', null]) {
        final (code, text) = await _post(engine.phonePort!, '/api/open', {'what': 'show'}, token: token);
        expect(code, 403);
        expect(jsonDecode(text), containsPair('error', 'Only on the computer.'));
      }
    });

    test('a phone without a good key is told to pair again', () async {
      final (code, text) = await _post(engine.phonePort!, '/api/speed/apply', {'changes': []}, token: 'wrong');
      expect(code, 403);
      expect(jsonDecode(text), containsPair('error', 'Pair this phone again.'));
    });

    test('the laptop with a wrong token is sent to the icon', () async {
      final (code, text) = await _post(engine.port, '/api/speed/apply', {'changes': []}, token: 'wrong');
      expect(code, 403);
      expect(jsonDecode(text), containsPair('error', 'Open SX Studio from its icon.'));
    });

    test("leaving the page stops live output with the key in the address, as the old page's beacon did", () async {
      for (final (port, key) in [(engine.phonePort!, phoneKey), (engine.port, 'secret')]) {
        await engine.dmx.startLive();
        final (code, _) = await _post(port, '/api/live/stop?t=${Uri.encodeQueryComponent(key)}', const {});
        expect(code, 200);
        expect(engine.dmx.liveOn, isFalse);
      }
    });

    test('a phone can force close ShowXpress', () async {
      sx.running = true;
      final r = await phone.sxClose(force: true);
      expect(r.ok, isTrue, reason: r.error);
      expect(sx.closes, [true]);
    });
  });

  test('opening ShowXpress stops the SX Player but leaves live output alone', () async {
    var player = true, stops = 0;
    engine.dmx.playerOn = () => player;
    engine.dmx.stopPlayer = () async {
      stops++;
      player = false;
    };
    await engine.dmx.startLive();
    expect((await laptop.sxLaunch()).ok, isTrue);
    expect(stops, 1);
    expect(engine.dmx.liveOn, isTrue);
    await engine.dmx.stopLive();
  });

  group('queue', () {
    test('a save while ShowXpress is open is queued only when it asks to be', () async {
      sx.running = true;
      final direct = await speed({
        'changes': [
          {'sec': 'page1_button1', 'title': 'CHASE', 'fader': 1},
        ],
      });
      expect(direct['ok'], isFalse);
      expect(direct['error'], contains('ShowXpress is OPEN'));
      expect(engine.queue.isEmpty, isTrue);

      final queued = await speed({
        'queue': true,
        'changes': [
          {'sec': 'page1_button1', 'title': 'CHASE', 'fader': 1},
        ],
      });
      expect(queued['queued'], isTrue);
      expect(engine.queue.isEmpty, isFalse);
    });

    test('cancel ignores case, and * drops everything', () async {
      sx.running = true;
      await speed({'queue': 1, 'changes': []});
      await _post(engine.port, '/api/apc/apply', {'queue': 'yes', 'changes': []}, token: 'secret');
      expect(engine.queue.info()['items'], hasLength(2));
      await laptop.queueCancel('/API/SPEED/APPLY');
      expect((engine.queue.info()['items']! as List).single, containsPair('label', 'APC pads'));
      await laptop.queueCancel('*');
      expect(engine.queue.isEmpty, isTrue);
    });

    test('the typed client asks to queue once it has seen ShowXpress open', () async {
      sx.running = true;
      expect((await laptop.speedApply(const [SpeedChange(sec: 'page1_button1', title: 'CHASE', fader: 1)])).ok, isFalse);
      await laptop.status();
      expect((await laptop.speedApply(const [SpeedChange(sec: 'page1_button1', title: 'CHASE', fader: 1)])).ok, isTrue);
      expect(engine.queue.isEmpty, isFalse);
    });

    test('"reopen after" is kept in the settings, as the old server saved it', () async {
      await laptop.queueReopen(false);
      expect((await laptop.settings()).settings.reopen, isFalse);
      await stop();
      await start();
      expect(engine.queue.reopen, isFalse);
      await laptop.queueReopen(true);
      expect((await laptop.settings()).settings.reopen, isTrue);
    });
  });

  group('speed', () {
    test('missing, fractional, text and too high faders are refused, nothing written', () async {
      final before = ini();
      for (final fader in [null, 1.5, 'x', -1, 100, '']) {
        final r = await speed({
          'changes': [
            {'sec': 'page1_button1', 'title': 'CHASE', 'fader': fader},
          ],
        });
        expect(r['error'], 'Nothing valid to save.', reason: '$fader');
      }
      expect(ini(), before);
    });

    test('an empty or missing list is refused by the server', () async {
      for (final changes in [
        <Object?>[],
        null,
        <Object?>[null, false, 0],
      ]) {
        expect((await speed({'changes': changes}))['error'], 'Nothing valid to save.', reason: '$changes');
      }
    });

    test('the section ignores case and a fader may come as text', () async {
      final r = await speed({
        'changes': [
          {'sec': 'PAGE1_BUTTON1', 'title': 'CHASE', 'fader': '1'},
        ],
      });
      expect(r['ok'], isTrue, reason: '${r['error']}');
      expect(r['out'], contains('CHASE (CHASES) -> COLORS'));
    });

    test('a single change sent bare, not in a list, is still read', () async {
      final r = await speed({
        'changes': {'sec': 'page1_button1', 'title': 'CHASE', 'fader': 1},
      });
      expect(r['ok'], isTrue, reason: '${r['error']}');
    });
  });

  group('apc', () {
    Future<Json> apc(Object? changes) async => jsonDecode((await _post(engine.port, '/api/apc/apply', {'changes': changes}, token: 'secret')).$2) as Json;

    test('bad notes and colors are refused by the server', () async {
      for (final c in [
        {'sec': 'page1_button1', 'title': 'CHASE', 'note': 64},
        {'sec': 'page1_button1', 'title': 'CHASE', 'note': -2},
        {'sec': 'page1_button1', 'title': 'CHASE', 'note': 1.5},
        {'sec': 'page1_button1', 'title': 'CHASE'},
        {'sec': 'page1_button1', 'title': 'CHASE', 'note': 3, 'on': 128, 'off': 0},
        {'sec': 'page1_button1', 'title': 'CHASE', 'note': 3, 'on': 5},
        {'sec': 'nope', 'title': 'CHASE', 'note': 3},
      ]) {
        expect((await apc([c]))['error'], 'Nothing valid to save.', reason: '$c');
      }
    });

    test('the section ignores case', () async {
      final r = await apc([
        {'sec': 'Page1_Button1', 'title': 'CHASE', 'note': 3},
      ]);
      expect(r['error'], isNot('Nothing valid to save.'));
    });
  });
}
