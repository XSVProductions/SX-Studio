import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/scene/scene_preview.dart';
import 'package:sx_studio/screens/scene/scene_work.dart';

import 'scene_fixture.dart';

void main() {
  late List<Sent> sent;
  setUp(() => sent = []);

  ScenePreview? pv;
  tearDown(() async => pv?.stop());

  Future<ScenePreview?> start() async {
    final client = fakeEngine(sent, {
      '/api/live/start': (_) => {'ok': true, 'test': true, 'iface': ''},
      '/api/live/out': (_) => {'ok': true},
      '/api/live/stop': (_) => {'ok': true},
    });
    final (p, _) = await ScenePreview.start(client, SceneWork(testScene()), onFailed: (_) {}, onStep: (_) {});
    return pv = p;
  }

  test('starts raw on the floor and sends the step on screen', () async {
    final p = await start();
    expect(sent.first.path, '/api/live/start');
    expect(sent.first.body, {'mode': 'floor', 'raw': true});
    expect(p!.test, isTrue);
    p.push(SceneWork(testScene()), 0);
    await pumpEventQueue();
    expect(sent[1].path, '/api/live/out');
    expect('${sent[1].body['l']}'.split(' '), ['z', 'b:1:255', 'b:2:255', 'b:11:0', 'b:12:255']);
  });

  test('sends only what changed', () async {
    final p = await start();
    final w = SceneWork(testScene());
    p!.push(w, 0);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    p.push(w, 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sent.last.body['l'], 'b:1:100 b:2:0');
  });

  test('stop releases the interface once', () async {
    final p = await start();
    await p!.stop();
    await p.stop();
    expect(sent.where((s) => s.path == '/api/live/stop').length, 1);
    expect(p.on, isFalse);
  });

  test('a refused frame stops the preview and says why', () async {
    final client = fakeEngine(sent, {
      '/api/live/start': (_) => {'ok': true, 'iface': 'COM3'},
      '/api/live/out': (_) => {'ok': false, 'error': 'The interface is gone.'},
      '/api/live/stop': (_) => {'ok': true},
    });
    var failed = '';
    final (p, _) = await ScenePreview.start(client, SceneWork(testScene()), onFailed: (e) => failed = e, onStep: (_) {});
    pv = p;
    expect(p!.iface, 'COM3');
    p.push(SceneWork(testScene()), 0);
    await pumpEventQueue();
    expect(failed, 'The interface is gone.');
    expect(sent.last.path, '/api/live/stop');
    expect(p.on, isFalse);
  });

  test('a refused start gives the reason and no preview', () async {
    final client = fakeEngine(sent, {
      '/api/live/start': (_) => {'ok': false, 'error': 'No DMX interface.'},
    });
    final (p, r) = await ScenePreview.start(client, SceneWork(testScene()), onFailed: (_) {}, onStep: (_) {});
    expect(p, isNull);
    expect(r.error, 'No DMX interface.');
  });
}
