import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

// The movement routes over HTTP on a one-movement show.

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

void main() {
  late Directory tmp;
  late Engine engine;
  late SxClient client;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_move_routes_');
    final g = Directory(p.join(tmp.path, 'show', 'Editor', 'Generator', 'projects'))..createSync(recursive: true);
    File(p.join(tmp.path, 'show', 'fixtures.ini')).writeAsStringSync('[Fixture1]\naddress = 1\nid = 11\n');
    File(p.join(g.path, 'T.gpj')).writeAsStringSync(
      '[Params]\nPanTiltShift = 0.0\n[Fixture_0]\nID = 11\nName = A\nChannels = pan,upan,tilt,utilt\nReversePan = 0\nReverseTilt = 0\n'
      'OffsetPan = 0\nOffsetTilt = 0\nZoomPan = 0\nZoomTilt = 0\n[Pan/Tilt/uPan/uTilt]\nSelected = 1\nTransition = 2\nDuration = 40\nShift = 0\n'
      'Point_0 = 20000,20000\nPoint_1 = 40000,20000\nPoint_2 = 30000,40000\n',
    );
    engine = Engine(
      EngineConfig(port: 0, token: 'k', showPath: p.join(tmp.path, 'show'), settingsDir: p.join(tmp.path, 'settings')),
      sx: _FakeSx(),
    );
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'k');
  });

  tearDown(() async {
    client.close();
    await engine.stop();
    tmp.deleteSync(recursive: true);
  });

  test("a save keeps its backup in the engine's settings folder, and Backups lists it", () async {
    final d = await client.move('T.gpj');
    final r = await client.moveSave(
      MoveSave(
        move: d.file,
        sha: d.sha,
        secs: [const MoveSecChange(name: movePtSection, dur: 55)],
        heads: const [],
      ),
    );
    expect(r.ok, isTrue, reason: r.error);
    final dir = Directory(p.join(tmp.path, 'settings', 'move_backups', 'show', 'T.gpj'));
    expect(dir.listSync().map((f) => p.extension(f.path)).toSet(), {'.gpj', '.json'});
    final b = await client.moveBackups('T.gpj');
    expect(b.backups, hasLength(1));

    final back = await client.moveRevert('T.gpj', b.backups.single.id);
    expect(back.ok, isTrue, reason: back.error);
    expect((await client.move('T.gpj')).secs.single.dur, 40);
  });
}
