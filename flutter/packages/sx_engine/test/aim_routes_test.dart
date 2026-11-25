import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity/parity.dart' show realShowPath;

// The aim and live routes over HTTP, on a copy of the real show, with DMX
// going to a frame log. Skipped when the show isn't on this machine.

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

void main() {
  late Directory tmp;
  late String show;
  late String frameLog;
  late _FakeSx sx;
  late Engine engine;
  late SxClient client;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_aim_routes_');
    show = p.join(tmp.path, 'show');
    for (final e in Directory(realShowPath!).listSync(recursive: true, followLinks: false)) {
      final to = p.join(show, p.relative(e.path, from: realShowPath!));
      if (e is Directory) Directory(to).createSync(recursive: true);
      if (e is File) (File(to)..parent.createSync(recursive: true)).writeAsBytesSync(e.readAsBytesSync());
    }
    frameLog = p.join(tmp.path, 'frame.txt');
    sx = _FakeSx();
    engine = Engine(
      EngineConfig(port: 0, token: 'k', showPath: show, dmx: FakeDmxSpec(frameLog)),
      sx: sx,
    );
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'k');
  });

  tearDown(() async {
    client.close();
    await engine.stop();
    tmp.deleteSync(recursive: true);
  });

  /// The frame log as channel -> value, once it shows [want] (or after 2 s).
  Future<Map<int, int>> frame(bool Function(Map<int, int>) want) async {
    var f = <int, int>{};
    for (var i = 0; i < 40; i++) {
      final text = File(frameLog).existsSync() ? File(frameLog).readAsStringSync() : '';
      f = {
        for (final l in const LineSplitter().convert(text))
          if (l.contains('=')) int.parse(l.split('=')[0]): int.parse(l.split('=')[1]),
      };
      if (want(f)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return f;
  }

  group('aim', skip: realShowPath == null ? 'the real show is not on this machine' : null, () {
    test('preview reads the mode from the query', () async {
      expect((await client.aimPreview(AimMode.room)).mode, 'Room');
      expect((await client.aimPreview(AimMode.floor)).mode, 'Floor');
    });

    test('apply refuses a size outside 20-300', () async {
      final r = await client.aimApply(AimMode.floor, w: 100, d: 301);
      expect((r.ok, r.error), (false, 'Size must be 20-300%.'));
    });

    test('while ShowXpress is open, apply and reset share one queue slot per mode', () async {
      sx.running = true;
      expect((await client.aimApply(AimMode.floor, w: 120, d: 120)).extra['label'], 'Aim Movers - Dance Floor');
      final reset = await client.aimHome(AimMode.floor);
      expect((reset.extra['label'], reset.extra['replaced']), ('Aim Movers (reset) - Dance Floor', true));
      expect((await client.aimApply(AimMode.room, w: 100, d: 100)).extra['label'], 'Aim Movers - Room');
      expect((await client.aimInstall()).extra['label'], 'ROOM buttons on the SETUP page');
      expect(engine.queue.info()['items'], [
        {'key': 'aim-floor', 'label': 'Aim Movers (reset) - Dance Floor'},
        {'key': 'aim-room', 'label': 'Aim Movers - Room'},
        {'key': '/api/aim/install', 'label': 'ROOM buttons on the SETUP page'},
      ]);
    });
  });

  group('live', skip: realShowPath == null ? 'the real show is not on this machine' : null, () {
    test('start refuses while ShowXpress is open or the player runs', () async {
      sx.running = true;
      final open = await client.liveStart();
      expect((open.ok, open.sxOpen), (false, true));
      sx.running = false;
      engine.dmx.playerOn = () => true;
      final player = await client.liveStart();
      expect((player.ok, player.error), (false, 'The SX Player (Lab) is using the DMX interface. Stop it in the Lab first.'));
      expect(engine.dmx.liveOn, isFalse);
    });

    test('a reversed head gets 65535 - v, raw mode reverses nothing', () async {
      final h = (await client.liveStart()).info!.heads.first;
      await client.liveStop();
      File(p.join(show, 'flip_state.json')).writeAsStringSync(
        jsonEncode({
          'heads': {
            h.id: {'pan': true, 'tilt': false},
          },
        }),
      );

      final s = await client.liveStart();
      expect((s.ok, s.test, s.iface), (true, true, 'test interface'));
      expect(s.info!.heads.firstWhere((x) => x.id == h.id).rp, isTrue);
      final a = h.addr;
      // pan 1000 goes out as 64535 (252, 23), tilt 1000 as it is (3, 232)
      expect((await client.liveOut('s:$a:${a + 1}:1000 s:${a + 2}:${a + 3}:1000 b:${a + 4}:10')).ok, isTrue);
      expect(await frame((f) => f[a] == 252), containsPair(a, 252));
      final f = await frame((f) => true);
      expect([f[a], f[a + 1], f[a + 2], f[a + 3], f[a + 4]], [252, 23, 3, 232, 10]);

      final raw = await client.liveStart(raw: true);
      expect((raw.ok, raw.info), (true, null));
      await client.liveOut('z s:$a:${a + 1}:1000');
      expect((await frame((f) => f[a] == 3))[a], 3);
    });

    test('out refuses a bad command, and says when the output is gone', () async {
      await client.liveStart();
      final bad = await client.liveOut('s:1:2:3 x:1');
      expect((bad.ok, bad.error), (false, 'Bad output command.'));
      expect((await client.liveOut('k')).ok, isTrue);
      await client.liveStop();
      final gone = await client.liveOut('k');
      expect((gone.ok, gone.extra['gone'], gone.error), (false, true, 'The DMX output stopped.'));
    });

    test('save stops the output, saves, applies, runs the queue and reopens', () async {
      final info = (await client.liveStart()).info!;
      final h = info.heads.first;
      // a save queued earlier, while ShowXpress was open
      sx.running = true;
      await client.aimInstall();
      sx.running = false;
      final r = await client.liveSave(
        mode: AimMode.floor,
        aims: {h.id: LiveAim(c: (h.c.$1 + 300, h.c.$2))},
        w: 110,
        d: 110,
        reopen: true,
      );
      expect((r.ok, r.saved, r.applied, r.applyError, r.reopened), (true, true, true, '', true));
      expect(r.out, contains('live aims saved into'));
      expect(r.out, contains('\n'));
      expect(engine.dmx.liveOn, isFalse);
      expect(engine.queue.isEmpty, isTrue);
      expect(sx.launches, 1);
      final again = (await client.liveStart()).info!.heads.firstWhere((x) => x.id == h.id);
      expect(again.c, (h.c.$1 + 300, h.c.$2));
    });

    test('save with a bad size still saves the aims', () async {
      final h = (await client.liveStart()).info!.heads.first;
      final r = await client.liveSave(
        mode: AimMode.floor,
        aims: {h.id: LiveAim(c: (h.c.$1 + 300, h.c.$2))},
        w: 10,
        d: 100,
      );
      expect((r.ok, r.saved, r.applied, r.applyError), (true, true, false, 'Size must be 20-300%.'));
      expect(r.reopened, isFalse);
    });
  });
}
