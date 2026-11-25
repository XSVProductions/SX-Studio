import 'dart:io';

import 'package:path/path.dart' as p;
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
  group('the old five-minute rule', () {
    var now = DateTime(2026, 11, 25, 20);
    var busy = false;
    late Lifetime life;

    setUp(() {
      now = DateTime(2026, 11, 25, 20);
      busy = false;
      life = Lifetime(busy: () => busy, clock: () => now);
    });

    test('quits only after more than 300 s without a request', () async {
      now = now.add(const Duration(seconds: 300));
      life.step();
      expect(life.quit, isFalse);
      now = now.add(const Duration(seconds: 1));
      life.step();
      expect(life.quit, isTrue);
      expect(await life.quitting, QuitReason.idle);
    });

    test('each request starts the five minutes again', () {
      now = now.add(const Duration(seconds: 299));
      life.touch();
      now = now.add(const Duration(seconds: 299));
      life.step();
      expect(life.quit, isFalse);
    });

    test('stays while busy, and quits as soon as that ends', () {
      busy = true;
      now = now.add(const Duration(hours: 3));
      life.step();
      expect(life.quit, isFalse);
      busy = false;
      life.step();
      expect(life.quit, isTrue);
    });

    test('an update quits at once, and only one reason wins', () async {
      life.quitFor(QuitReason.update);
      now = now.add(const Duration(hours: 1));
      life.step();
      expect(await life.quitting, QuitReason.update);
    });
  });

  group('in the engine', () {
    late Directory tmp;
    late Engine engine;
    late _FakeSx sx;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('sx_lifetime_');
      sx = _FakeSx();
      engine = Engine(
        EngineConfig(port: 0, token: 't', settingsDir: p.join(tmp.path, 'cfg'), showPath: tmp.path),
        sx: sx,
      );
      await engine.start();
    });

    tearDown(() async {
      await engine.stop();
      tmp.deleteSync(recursive: true);
    });

    test('a request with the key counts, one without does not', () async {
      final life = engine.lifetime;
      final client = HttpClient();
      Future<int> get(String path, {String? key}) async {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:${engine.port}$path'));
        if (key != null) req.headers.set('X-SX-Token', key);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      final start = life.lastRequest;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await get('/api/settings'), 403);
      expect(life.lastRequest, start);
      expect(await get('/api/settings', key: 't'), 200);
      expect(life.lastRequest.isAfter(start), isTrue);
      client.close(force: true);
    });

    test('the Auto Show, the player and the save queue keep it alive', () {
      final life = engine.lifetime;
      expect(life.busy(), isFalse);
      sx.running = true;
      engine.queue.add(engine.api.find('/api/speed/apply')!, const {'changes': <Object?>[]});
      expect(life.busy(), isTrue);
    });
  });

  group('the phone page', () {
    test('a missing web build keeps the phone listener off and says why', () async {
      final tmp = Directory.systemTemp.createTempSync('sx_lifetime_web_');
      final engine = Engine(
        EngineConfig(port: 0, phonePort: 0, token: 't', settingsDir: p.join(tmp.path, 'cfg'), showPath: tmp.path, webDir: p.join(tmp.path, 'web')),
        sx: _FakeSx(),
      );
      await engine.start();
      await engine.setPhoneListener(true);
      expect(engine.phonePort, isNull);
      expect(engine.phoneError, 'The phone page of SX Studio is missing - install SX Studio again.');

      Directory(p.join(tmp.path, 'web')).createSync();
      File(p.join(tmp.path, 'web', 'index.html')).writeAsStringSync('<html></html>');
      await engine.setPhoneListener(true);
      expect(engine.phonePort, isNotNull);
      expect(engine.phoneError, '');
      await engine.stop();
      tmp.deleteSync(recursive: true);
    });
  });
}
