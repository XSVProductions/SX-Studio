import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

void main() {
  late Directory settings;
  late Engine engine;
  late SxClient laptop;

  Future<void> startEngine() async {
    engine = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 'laptop-secret', settingsDir: settings.path),
      sx: _FakeSx(),
    );
    await engine.start();
    laptop = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'laptop-secret');
  }

  setUp(() async {
    settings = Directory.systemTemp.createTempSync('sx_phone_');
    await startEngine();
  });

  tearDown(() async {
    laptop.close();
    await engine.stop();
    settings.deleteSync(recursive: true);
  });

  /// A client on the network port, the way a phone reaches the laptop.
  SxClient phone([String key = '']) {
    final c = SxClient(Uri.parse('http://127.0.0.1:${engine.phonePort}'), token: key);
    addTearDown(c.close);
    return c;
  }

  /// One plain HTTP call. Answers the status code.
  Future<int> raw(String method, int port, String path, {String key = '', Object? body}) async {
    final c = HttpClient();
    try {
      final req = await c.open(method, '127.0.0.1', port, path);
      if (key.isNotEmpty) req.headers.set('X-SX-Token', key);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      c.close(force: true);
    }
  }

  Matcher status(int code) => throwsA(isA<ApiException>().having((e) => e.status, 'status', code));

  Future<String> pairAPhone() async {
    final info = await laptop.phonePin();
    return phone().phonePair(info.pin);
  }

  setUp(() async => laptop.phoneSet(true));

  test('phone access off means nothing listens on the network', () async {
    expect(engine.phonePort, isNotNull);
    final port = engine.phonePort!;
    final info = await laptop.phoneSet(false);
    expect(info.on, isFalse);
    expect(info.running, isFalse);
    await expectLater(raw('GET', port, '/api/settings'), throwsA(isA<SocketException>()));
  });

  test("the laptop's token is refused on the network port", () async {
    await expectLater(phone('laptop-secret').settings(), status(401));
  });

  test('an unpaired phone is refused', () async {
    await expectLater(phone().settings(), status(401));
    await expectLater(phone('made-up-key').settings(), status(401));
  });

  test('pairing with the code on the laptop gives a key that works', () async {
    final info = await laptop.phonePin();
    expect(info.pin, matches(RegExp(r'^\d{6}$')));
    expect(info.pinLeft, greaterThan(500));

    final key = await phone().phonePair(info.pin);
    expect(key.length, greaterThanOrEqualTo(40));
    final s = await phone(key).settings();
    expect(s.phone, isTrue);

    final after = await laptop.phone();
    expect(after.phones, hasLength(1));
    expect(after.pin, isEmpty, reason: 'one phone per code');
    expect(after.lastIp, isNotEmpty);
    // the laptop keeps a hash, never the key
    expect(File('${settings.path}/phones.json').readAsStringSync(), isNot(contains(key)));
  });

  test('a paired phone still gets nothing marked laptop only', () async {
    final key = await pairAPhone();
    for (final call in [
      () => phone(key).phone(),
      () => phone(key).phoneSet(true),
      () => phone(key).phonePin(),
      () => phone(key).phoneUnpair('*'),
      () => phone(key).updateInstall().then((r) => throw ApiException(r.error)),
    ]) {
      await expectLater(call(), status(403));
    }
    expect(await raw('POST', engine.phonePort!, '/api/open', key: key, body: {'what': 'show'}), 403);
  });

  test('a phone cannot change the laptop-only settings', () async {
    final key = await pairAPhone();
    final s = await phone(key).settingsSet(const SettingsChange(reopen: false, tabHidden: ['rt']));
    expect(s.reopen, isTrue);
    expect(s.tabHidden, ['rt']);
  });

  test('pairing is refused on the laptop port', () async {
    final info = await laptop.phonePin();
    await expectLater(laptop.phonePair(info.pin), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Pairing is for phones.')));
  });

  test('pairing without a code showing is refused', () async {
    await expectLater(phone().phonePair('123456'), throwsA(isA<ApiException>().having((e) => e.message, 'message', startsWith('No code is showing'))));
  });

  test('five wrong codes drop the code and shut pairing for a minute', () async {
    final pin = (await laptop.phonePin()).pin;
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var i = 0; i < 5; i++) {
      await expectLater(phone().phonePair(wrong), throwsA(isA<ApiException>().having((e) => e.message, 'message', startsWith('That code is not right'))));
    }
    await expectLater(phone().phonePair(pin), throwsA(isA<ApiException>().having((e) => e.message, 'message', startsWith('Too many wrong codes'))));
    expect((await laptop.phone()).pin, isEmpty);
    expect((await laptop.phone()).phones, isEmpty);
  });

  test('unpairing one phone shuts out that phone only', () async {
    final a = await pairAPhone(), b = await pairAPhone();
    final list = (await laptop.phone()).phones;
    expect(list, hasLength(2));
    await phone(a).settings();
    final aId = (await laptop.phone()).phones.firstWhere((p) => p.lastSeen.isNotEmpty).id;

    await laptop.phoneUnpair(aId);
    await expectLater(phone(a).settings(), status(401));
    expect((await phone(b).settings()).phone, isTrue);

    await laptop.phoneUnpair('*');
    await expectLater(phone(b).settings(), status(401));
  });

  test('paired phones and phone access survive a restart', () async {
    final key = await pairAPhone();
    laptop.close();
    await engine.stop();
    await startEngine();
    expect(engine.phonePort, isNotNull);
    expect((await phone(key).settings()).phone, isTrue);
  });

  test("the old app's shared key keeps working until it is unpaired", () async {
    laptop.close();
    await engine.stop();
    File('${settings.path}/phones.json').deleteSync();
    File('${settings.path}/phone.json').writeAsStringSync('{"on":true,"key":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}');
    await startEngine();
    expect((await phone('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef').settings()).phone, isTrue);
    expect((await laptop.phone()).phones.single.name, 'Paired before the update');
  });
}
