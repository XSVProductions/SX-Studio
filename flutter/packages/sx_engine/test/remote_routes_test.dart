import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'sx_test_show.dart';

class _Sx implements SxApp {
  @override
  var running = true;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

void main() {
  late SxTestShow t;
  late _Sx sx;
  late Engine engine;
  late SxClient client;

  setUp(() async {
    t = await SxTestShow.create();
    sx = _Sx();
    engine = Engine(
      EngineConfig(port: 0, token: 'k', showPath: t.root),
      sx: sx,
    );
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'k');
  });

  tearDown(() async {
    await engine.find<AutoShow>()!.stop();
    client.close();
    await engine.stop();
    await t.dispose();
  });

  test('press and read back through the API', () async {
    final r = await client.remotePress(['RED'], solo: true);
    expect(r.connected, isTrue, reason: r.error);
    expect(r.pressedNow, ['RED']);
    final s = await client.remote();
    expect(s.pressed.single.title, 'RED');
    expect((await client.remoteOff()).released, ['RED']);
  });

  test('a title the old server would not pass is refused', () async {
    final r = await client.remotePress(['RED|BLUE']);
    expect(r.ok, isFalse);
    expect(r.error, 'Unknown button.');
    expect(t.sx.log, isEmpty);
  });

  test('turning the remote on waits while ShowXpress is open', () async {
    final r = await client.remoteEnable();
    expect(r.extra['queued'], isTrue);
    expect(r.extra['label'], 'ShowXpress remote control');
  });

  test('save, start, and see it in the status poll', () async {
    final info = await client.auto();
    expect(info.ready, isTrue);
    expect(info.buttons.map((b) => b.title), ['CIRCLE', 'FIGURE 8', 'RED', 'BLUE', 'RIG ID']);
    final cfg = info.config..looks.add(AutoLook(id: 'aaaaaaaa', name: 'Red', bars: 16, on: true, titles: ['RED']));
    final saved = await client.autoSave(cfg);
    expect(saved.ok, isTrue, reason: saved.error);
    expect(File('${t.root}/auto_show.json').readAsStringSync(), contains('"name": "Red"'));

    final started = await client.autoStart();
    expect(started.ok, isTrue, reason: started.error);
    final st = await client.status();
    expect(st.auto!.running, isTrue);
    expect(st.auto!.name, 'Red');
    expect(t.sx.pressed, ['RED']);

    final bad = await client.autoCmd(AutoCmd.bpm, 'fast');
    expect(bad.error, 'Unknown command.');
    final stopped = await client.autoStop();
    expect(stopped.status!.running, isFalse);
    expect((await client.autoCmd(AutoCmd.next)).error, "The Auto Show isn't playing.");
  });

  test('a press asked for while ShowXpress is closed happens when it opens', () async {
    sx.running = false;
    engine.find<ButtonPresses>()!.pressWhenOpen(['FIGURE 8'], 'FIGURE 8');
    expect((await client.status()).pend, isTrue);
    sx.running = true;
    final pend = engine.find<PendingPresses>()!;
    await pend.step();
    final st = await client.status();
    expect(st.pend, isFalse);
    expect(st.rem!.label, 'FIGURE 8');
    expect(t.sx.pressed, ['FIGURE 8']);
  });

  test('closing ShowXpress for live aim holds the save queue', () async {
    final hold = engine.liveHold;
    await client.sxClose();
    expect(hold.on, isFalse);
    await client.sxClose(live: true);
    expect(hold.on, isTrue);
  });

  test('the hold wears off after 180 seconds and ends when cleared', () {
    var now = DateTime(2026);
    final hold = LiveHold(now: () => now)..start();
    now = now.add(const Duration(seconds: 179));
    expect(hold.on, isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(hold.on, isFalse);
    hold
      ..start()
      ..clear();
    expect(hold.on, isFalse);
  });
}
