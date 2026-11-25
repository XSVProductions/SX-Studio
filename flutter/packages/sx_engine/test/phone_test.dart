import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// One plain HTTP answer.
typedef _Answer = ({int status, String body, String cookie});

void main() {
  late Directory settings, web;
  late Engine engine;
  late SxClient laptop;

  Future<void> startEngine() async {
    engine = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 'laptop-secret', settingsDir: settings.path, webDir: web.path),
      sx: _FakeSx(),
    );
    await engine.start();
    laptop = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'laptop-secret');
  }

  setUp(() async {
    settings = Directory.systemTemp.createTempSync('sx_phone_');
    web = Directory.systemTemp.createTempSync('sx_phone_web_');
    File('${web.path}/index.html').writeAsStringSync('<meta name="sx-phone-key" content="$phoneKeyMark">');
    File('${web.path}/icon.png').writeAsBytesSync([1, 2, 3]);
    await startEngine();
  });

  tearDown(() async {
    laptop.close();
    await engine.stop();
    settings.deleteSync(recursive: true);
    web.deleteSync(recursive: true);
  });

  /// A client on the network port, the way a phone reaches the laptop.
  SxClient phone([String key = '']) {
    final c = SxClient(Uri.parse('http://127.0.0.1:${engine.phonePort}'), token: key);
    addTearDown(c.close);
    return c;
  }

  /// One plain HTTP call on the network port.
  Future<_Answer> raw(String method, String path, {String key = '', String cookie = '', Object? body, int? port}) async {
    final c = HttpClient();
    try {
      final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:${port ?? engine.phonePort}$path'));
      if (key.isNotEmpty) req.headers.set('X-SX-Token', key);
      if (cookie.isNotEmpty) req.headers.set('Cookie', cookie);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      return (status: res.statusCode, body: await res.transform(utf8.decoder).join(), cookie: res.headers.value('set-cookie') ?? '');
    } finally {
      c.close(force: true);
    }
  }

  Matcher refused(String message) => throwsA(isA<ApiException>().having((e) => e.status, 'status', 403).having((e) => e.message, 'message', message));

  Matcher says(String message) => throwsA(isA<ApiException>().having((e) => e.message, 'message', message));

  Future<String> pairAPhone() async {
    final info = await laptop.phonePin();
    return phone().phonePair(info.pin);
  }

  String savedKey() => (jsonDecode(File('${settings.path}/phone.json').readAsStringSync()) as Map)['key'] as String;

  setUp(() async => laptop.phoneSet(true));

  test('phone access off means nothing listens on the network', () async {
    final port = engine.phonePort!;
    final info = await laptop.phoneSet(false);
    expect(info.on, isFalse);
    expect(info.running, isFalse);
    await expectLater(raw('GET', '/api/settings', port: port), throwsA(isA<SocketException>()));
  });

  test('phone.json is the old one: on and the one key, compact, no byte order mark', () async {
    final bytes = File('${settings.path}/phone.json').readAsBytesSync();
    expect(bytes.first, '{'.codeUnitAt(0));
    expect(utf8.decode(bytes), matches(RegExp(r'^\{"on":true,"key":"[0-9a-f]{64}"\}$')));
  });

  test("the laptop's token is refused on the network port", () async {
    await expectLater(phone('laptop-secret').settings(), refused('Pair this phone again.'));
  });

  test('an unpaired phone is refused with the old words', () async {
    await expectLater(phone().settings(), refused('Pair this phone again.'));
    await expectLater(phone('made-up-key').settings(), refused('Pair this phone again.'));
  });

  test('a laptop-only path is refused before the key is looked at', () async {
    await expectLater(phone().phone(), refused('Only on the computer.'));
  });

  test('with phone access turned off, a phone is told so', () async {
    final key = await pairAPhone();
    engine.phones.setOn(false); // the listener still up for a moment
    await expectLater(phone(key).settings(), refused('Phone access is turned off in SX Studio.'));
    expect((await raw('GET', '/')).body, 'Phone access is turned off in SX Studio.');
  });

  test('one code pairs any number of phones, all with the one key', () async {
    final info = await laptop.phonePin();
    expect(info.pin, matches(RegExp(r'^\d{6}$')));
    expect(info.pinLeft, 600);

    final a = await phone().phonePair(info.pin);
    final b = await phone().phonePair(' ${info.pin} ');
    expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(b, a);
    expect(savedKey(), a);
    expect((await phone(a).settings()).phone, isTrue);

    final after = await laptop.phone();
    expect(after.pin, info.pin, reason: 'the code stays for the next phone');
    expect(after.lastIp, isNotEmpty);
    expect(after.lastSeen, isNotEmpty);
  });

  test('pairing sets the ten year cookie, and the cookie alone lets a phone in', () async {
    final pin = (await laptop.phonePin()).pin;
    final r = await raw('POST', '/api/phone/pair', body: {'pin': pin});
    final key = savedKey();
    expect(jsonDecode(r.body), {'ok': true, 'key': key});
    expect(r.cookie, 'sxh_k=$key; Max-Age=315360000; Path=/; HttpOnly; SameSite=Lax');

    expect((await raw('GET', '/api/settings', cookie: 'sxh_k=$key')).status, 200);
    expect((await raw('GET', '/api/settings?t=$key')).status, 200);
    expect((await raw('GET', '/api/settings', cookie: 'sxh_k=${key.toUpperCase()}')).status, 403, reason: 'case counts');
  });

  test('the page gives a paired phone its key back from the cookie or the address', () async {
    final key = await pairAPhone();
    final byCookie = await raw('GET', '/', cookie: 'other=1; sxh_k=$key');
    expect(byCookie.body, '<meta name="sx-phone-key" content="$key">');
    expect(byCookie.cookie, startsWith('sxh_k=$key;'));

    final byAddress = await raw('GET', '/?k=$key');
    expect(byAddress.body, contains('content="$key"'));
    expect(byAddress.cookie, isNotEmpty);

    final stale = await raw('GET', '/?k=0000', cookie: 'sxh_k=1111');
    expect(stale.body, '<meta name="sx-phone-key" content="">');
    expect(stale.cookie, isEmpty);

    // the old open files need no key
    expect((await raw('GET', '/icon.png')).status, 200);
  });

  test('the laptop page never gets a key', () async {
    final key = await pairAPhone();
    final r = await raw('GET', '/', cookie: 'sxh_k=$key', port: engine.port);
    expect(r.body, contains(phoneKeyMark));
  });

  test('a paired phone still gets nothing marked laptop only', () async {
    final key = await pairAPhone();
    for (final call in [
      () => phone(key).phone(),
      () => phone(key).phoneSet(true),
      () => phone(key).phonePin(),
      () => phone(key).phoneUnpair(),
      () => phone(key).updateInstall().then((r) => throw ApiException(r.error)),
    ]) {
      await expectLater(call(), refused('Only on the computer.'));
    }
    expect((await raw('POST', '/api/open', key: key, body: {'what': 'show'})).status, 403);
  });

  test('a phone cannot change the laptop-only settings', () async {
    final key = await pairAPhone();
    final s = await phone(key).settingsSet(const SettingsChange(reopen: false, tabHidden: ['rt']));
    expect(s.reopen, isTrue);
    expect(s.tabHidden, ['rt']);
  });

  test('pairing is refused on the laptop port', () async {
    final info = await laptop.phonePin();
    await expectLater(laptop.phonePair(info.pin), says('Pairing is for phones.'));
  });

  test('pairing without a code showing is refused', () async {
    await expectLater(
      phone().phonePair('123456'),
      says('No code is showing on the laptop. In SX Studio on the laptop, press the cogwheel (top right) and press "Pair a phone".'),
    );
  });

  test('five wrong codes drop the code and shut pairing for a minute, even for a new code', () async {
    final pin = (await laptop.phonePin()).pin;
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var i = 0; i < 5; i++) {
      await expectLater(phone().phonePair(wrong), says('That code is not right. Check the 6 digits on the laptop.'));
    }
    const locked = 'Too many wrong codes. On the laptop, press "Pair a phone" again for a new code.';
    await expectLater(phone().phonePair(pin), says(locked));
    expect((await laptop.phone()).pin, isEmpty);
    // the old server reset the count for a new code, not the lockout
    final again = (await laptop.phonePin()).pin;
    await expectLater(phone().phonePair(again), says(locked));
  });

  test('unpair all phones makes a new key: every phone pairs again', () async {
    final key = await pairAPhone();
    expect((await laptop.phone()).pin, isNotEmpty);
    final info = await laptop.phoneUnpair();
    expect(info.pin, isEmpty);
    expect(savedKey(), isNot(key));
    await expectLater(phone(key).settings(), refused('Pair this phone again.'));
    expect((await raw('GET', '/api/settings', cookie: 'sxh_k=$key')).status, 403);
  });

  test('the key and phone access survive a restart', () async {
    final key = await pairAPhone();
    laptop.close();
    await engine.stop();
    await startEngine();
    expect(engine.phonePort, isNotNull);
    expect((await phone(key).settings()).phone, isTrue);
  });

  test("a phone paired with the old app's key keeps working", () async {
    laptop.close();
    await engine.stop();
    const old = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    File('${settings.path}/phone.json').writeAsStringSync('{"on":true,"key":"$old"}');
    await startEngine();
    expect((await phone(old).settings()).phone, isTrue);
  });

  test('turning phone access off forgets the last phone, as the stopped relay did', () async {
    final key = await pairAPhone();
    await phone(key).settings();
    expect((await laptop.phone()).lastIp, isNotEmpty);
    await laptop.phoneSet(false);
    final info = await laptop.phoneSet(true);
    expect(info.lastSeen, isEmpty);
    expect(info.lastIp, isEmpty);
  });

  group('PhoneAccess', () {
    test('a broken phone.json reads as off with a new key, saved with the next change', () {
      File('${settings.path}/phone.json').writeAsStringSync('not json');
      final ph = PhoneAccess(settings.path);
      expect(ph.on, isFalse);
      expect(ph.key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(File('${settings.path}/phone.json').readAsStringSync(), 'not json');
      ph.setOn(true);
      expect(savedKey(), ph.key);
    });

    test('the code runs out after ten minutes and shows whole seconds left', () {
      var t = DateTime(2026, 1, 1, 12);
      final ph = PhoneAccess(settings.path, now: () => t);
      ph.newPin();
      t = t.add(const Duration(minutes: 9, seconds: 59, milliseconds: 500));
      expect(ph.pinLeft, 0, reason: '0.5 s rounds to even');
      t = t.add(const Duration(milliseconds: 600));
      expect(ph.pin, isEmpty);
      expect(() => ph.pair('123456'), throwsA(isA<PairRefused>()));
    });

    test('new keys look like two GUIDs', () {
      final k = newPhoneKey(Random(1));
      expect(k, matches(RegExp(r'^[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$')));
    });
  });

  group('local name', () {
    test("a Mac's LocalHostName comes first", () {
      expect(localNameFrom(scutilName('Stage-Laptop\n'), 'whatever.lan'), 'Stage-Laptop.local');
    });

    test("scutil's output is trimmed, and nothing from it falls back to the host name", () {
      expect(scutilName('  My-Mac \r\n'), 'My-Mac');
      expect(scutilName(''), '');
      expect(localNameFrom(scutilName(''), 'studio.local'), 'studio.local');
      expect(localNameFrom('', 'Studio.LOCAL'), 'Studio.local');
    });

    test('a name with other characters gives none', () {
      expect(localNameFrom("Bob's MacBook", 'x'), '');
      expect(localNameFrom('', 'laptop.example.com'), '');
    });
  });
}
