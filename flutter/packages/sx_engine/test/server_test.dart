import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;
  var launches = 0;

  @override
  Future<ToolResult> launch() async {
    launches++;
    return const ToolResult(ok: true);
  }

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

const _liveIni =
    '[live]\r\nmaster_faders = 2\r\n\r\n[master_faders]\r\ncaption_fader0 = MOVEMENTS\r\ntype_fader0 = 1\r\ncaption_fader1 = COLORS\r\ntype_fader1 = 1\r\n\r\n'
    '[page1]\r\nname = CHASES\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CHASE.scex\r\ntitle = CHASE\r\n';

void main() {
  late Directory show;
  late _FakeSx sx;
  late Engine engine;
  late SxClient client;

  setUp(() async {
    show = Directory.systemTemp.createTempSync('sx_server_');
    Directory('${show.path}/Live').createSync();
    File('${show.path}/Live/live.ini').writeAsStringSync(_liveIni);
    sx = _FakeSx();
    engine = Engine(
      EngineConfig(port: 0, token: 'secret', showPath: show.path),
      sx: sx,
    );
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'secret');
  });

  tearDown(() async {
    client.close();
    await engine.stop();
    show.deleteSync(recursive: true);
  });

  String ini() => File('${show.path}/Live/live.ini').readAsStringSync();
  const change = [SpeedChange(sec: 'page1_button1', title: 'CHASE', fader: 1)];

  test('a read and a save go through the typed client', () async {
    final p = await client.speed();
    expect(p.buttons.single.title, 'CHASE');
    expect(p.buttons.single.missing, isTrue);
    final r = await client.speedApply(change);
    expect(r.ok, isTrue, reason: r.error);
    expect(r.out, contains('CHASE (CHASES) -> COLORS'));
    expect(ini(), contains('title = CHASE\r\nmasterspeedfader = 1\r\n'));
  });

  test('a tool refusal comes back as ok false with the reason', () async {
    final r = await client.speedApply(const [SpeedChange(sec: 'page1_button1', title: 'OTHER', fader: 1)]);
    expect(r.ok, isFalse);
    expect(r.error, contains('The show changed since this page was loaded'));
  });

  test('the brand image comes from the settings folder, without a key', () async {
    final url = Uri.parse('http://127.0.0.1:${engine.port}/brand.png');
    final http = HttpClient();
    addTearDown(http.close);
    Future<HttpClientResponse> ask() async => (await http.getUrl(url)).close();

    final none = await ask();
    expect(none.statusCode, 404);
    await none.drain<void>();

    File('${engine.settingsFolder}/brand.png').writeAsBytesSync([1, 2, 3]);
    final found = await ask();
    expect(found.statusCode, 200);
    expect(found.headers.contentType?.mimeType, 'image/png');
    expect(await found.expand((b) => b).toList(), [1, 2, 3]);
  });

  test('a call without the token is refused', () async {
    final stranger = SxClient(client.base, token: 'guess');
    addTearDown(stranger.close);
    await expectLater(stranger.speed(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
  });

  test('a save cannot be sent as a GET', () async {
    await expectLater(client.get('/api/speed/apply', ToolResult.fromJson), throwsA(isA<ApiException>().having((e) => e.status, 'status', 405)));
  });

  test('a save made while ShowXpress is open waits, then runs and reopens it', () async {
    sx.running = true;
    await client.status();
    final r = await client.speedApply(change);
    expect(r.extra['queued'], isTrue);
    expect(ini(), isNot(contains('masterspeedfader')), reason: 'nothing written while ShowXpress is open');
    sx.running = false;
    await engine.queue.run(reopen: true);
    expect(ini(), contains('masterspeedfader = 1'));
    expect(sx.launches, 1);
    expect((engine.queue.done!['results'] as List).single, containsPair('ok', true));
  });
}
