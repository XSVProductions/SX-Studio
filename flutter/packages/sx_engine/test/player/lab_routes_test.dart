import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'test_show.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;
  var launches = 0;

  @override
  Future<ToolResult> launch() async {
    launches++;
    return const ToolResult(ok: true, out: '  (test) ShowXpress would open now');
  }

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

class _FakeAuto implements PlayerAutoShowLink {
  @override
  bool running = false;
  @override
  bool onPlayer = false;
  var restarts = 0;

  @override
  Future<void> restart() async => restarts++;
}

class _FakeRemote implements PlayerShowXpressLink {
  List<PressedButton>? now;
  final pending = <(List<String>, String)>[];
  final cleared = <String>[];

  @override
  Future<List<PressedButton>?> pressed() async => now;

  @override
  void setPendingPress(List<String> titles, String label) => pending.add((titles, label));

  @override
  void clearPendingPress(String label) => cleared.add(label);
}

class _FakeLayout implements PlayerLayoutSource {
  @override
  List<PlayerPageSpec> customPages = const [];
}

void main() {
  late Directory show;
  late File log;
  late _FakeSx sx;
  late Engine engine;
  late HttpClient http;

  setUp(() async {
    show = makeTestShow();
    log = File(p.join(show.path, '_dmx_frame.txt'));
    sx = _FakeSx();
    engine = Engine(
      EngineConfig(port: 0, token: 'dev', showPath: show.path, dmx: FakeDmxSpec(log.path)),
      sx: sx,
    );
    await engine.start();
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await engine.stop();
    show.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> call(String path, [Map<String, Object?>? body]) async {
    final uri = Uri.parse('http://127.0.0.1:${engine.port}$path');
    final req = body == null ? await http.getUrl(uri) : await http.postUrl(uri);
    req.headers.set('x-sx-token', 'dev');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> cmd(Map<String, Object?> body) => call('/api/lab/cmd', body);
  LabPlayer lab() => engine.find<PlayerControl>()! as LabPlayer;

  test('start, press, refusals, status and stop', () async {
    expect(await cmd({'cmd': 'tap'}), {'ok': false, 'gone': true, 'error': 'The SX Player stopped.'});
    final list = await call('/api/lab');
    expect((list['pages']! as List).length, 2);

    final s = await call('/api/lab/start', {});
    expect(s['ok'], isTrue, reason: '${s['error']}');
    expect(s['iface'], 'test interface');
    expect(s['test'], isTrue);
    expect(s['carried'], isEmpty);
    expect((s['list']! as Map)['pages'], list['pages']);
    expect(s.containsKey('auto'), isFalse);
    expect((await call('/api/sx'))['play'], isTrue);

    expect(await cmd({'cmd': 'press', 'sec': 'PAGE1_BUTTON1'}), {'ok': true});
    await until(() => frameOf(log)[1] == 255, reason: 'RED, found ignoring case like the old hashtable');

    expect(await cmd({'cmd': 'press', 'sec': 'page9_button1'}), {'ok': false, 'error': 'That button is not in the show any more - press Reload.'});
    expect(await cmd({'cmd': 'fader', 'k': 16, 'v': 0.5}), {'ok': false, 'error': 'Bad fader value.'});
    expect(await cmd({'cmd': 'fader', 'k': '1.5', 'v': 0.5}), {'ok': false, 'error': 'Bad fader value.'});
    expect(await cmd({'cmd': 'fader', 'k': 0, 'v': 'NaN'}), {'ok': false, 'error': 'Bad fader value.'});
    expect(await cmd({'cmd': 'fader', 'k': '0', 'v': 7}), {'ok': true});
    expect(await cmd({'cmd': 'bpm', 'v': 39.9}), {'ok': false, 'error': 'The BPM has to be 40 to 250.'});
    expect(await cmd({'cmd': 'bpm', 'v': '133.456'}), {'ok': true});
    expect(await cmd({'cmd': 'key', 'key': 'ab'}), {'ok': false, 'error': 'Bad key.'});
    expect(await cmd({'cmd': 'nope'}), {'ok': false, 'error': 'Unknown player command.'});
    File(p.join(show.path, 'scenes', 'BLUE.scex')).deleteSync();
    expect(await cmd({'cmd': 'on', 'sec': 'page1_button2'}), {'ok': false, 'error': 'The file for BLUE is missing.'});
    expect(await cmd({'cmd': 'bo', 'on': 1}), {'ok': true});
    await until(() => frameOf(log).isEmpty, reason: 'blackout');

    await until(() => ((lab().statusJson?['fd'] as List?)?.first) == 1);
    final st = await call('/api/lab/status');
    expect(st['running'], isTrue);
    final status = st['status']! as Map;
    expect(status['bpm'], 133.46);
    expect(status['bo'], isTrue);
    expect((status['on']! as List).single, {'slot': 'page1_button1', 'step': 1, 'of': 1});
    expect(st['event'], isNull);

    expect(await call('/api/lab/stop', {}), {'ok': true});
    expect(log.readAsStringSync(), '');
    expect((await call('/api/lab/status'))['running'], isFalse);
    expect((await call('/api/sx'))['play'], isFalse);
  });

  test('start refuses while ShowXpress or live output has the interface', () async {
    sx.running = true;
    final r = await call('/api/lab/start', {});
    expect(r['sxopen'], isTrue);
    expect(r['error'], 'ShowXpress is open - it has to be closed while the SX Player plays (only one program can use the DMX interface).');
    sx.running = false;
    await engine.dmx.startLive();
    expect((await call('/api/lab/start', {}))['error'], 'Aim live or the colour preview is using the DMX interface. Finish that first.');
    await engine.dmx.stopLive();
  });

  test('hand-over: ShowXpress gets what was playing, and the screen hears about it', () async {
    final remote = _FakeRemote();
    engine.provide<PlayerShowXpressLink>(remote);
    await call('/api/lab/start', {});
    await cmd({'cmd': 'press', 'sec': 'page1_button1'});
    await cmd({'cmd': 'press', 'sec': 'page2_button1'});
    await until(() => (lab().statusJson?['on'] as List?)?.length == 2);
    final r = await call('/api/lab/handoff', {});
    expect(r, {
      'ok': true,
      'error': '',
      'out': '  (test) ShowXpress would open now',
      'titles': ['RED', 'BEAT'],
      'auto': false,
      'test': true,
    });
    expect(sx.launches, 1);
    expect(remote.pending.single.$1, ['RED', 'BEAT']);
    expect(remote.pending.single.$2, 'what the SX Player was playing');
    expect(log.readAsStringSync(), '');
    final ev = (await call('/api/lab/status'))['event']! as Map;
    expect(ev['kind'], 'handoff');
    expect(ev['text'], 'Handed over to ShowXpress.');
    expect(ev['n'], 1);
    expect(ev['at'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}[+-]\d\d:\d\d$')));

    // not running: just open ShowXpress
    expect(await call('/api/lab/handoff', {}), {'ok': true, 'error': '', 'titles': [], 'test': true});
    expect(sx.launches, 2);
  });

  test('ShowXpress opening while the player plays makes the player hand over', () async {
    await call('/api/lab/start', {});
    sx.running = true;
    await until(() => lab().event != null, max: const Duration(seconds: 3));
    expect(lab().running, isFalse);
    expect(lab().event?.text, 'ShowXpress was opened, so the SX Player stopped and handed over to it.');
    expect(sx.launches, 0);
  });

  test('a player that stops by itself is started again with what it was playing', () async {
    await call('/api/lab/start', {});
    await cmd({'cmd': 'press', 'sec': 'page1_button2'});
    await cmd({'cmd': 'fader', 'k': 0, 'v': 0.25});
    await cmd({'cmd': 'bo', 'on': true});
    await until(() => (lab().statusJson?['on'] as List?)?.length == 1 && lab().statusJson?['bo'] == true);
    final pl = engine.find<PlayerControl>()!;
    expect(pl.status!.on, ['page1_button2']);
    // what a crash looks like from outside
    lab().player!.kill();
    await until(() => lab().event?.kind == 'restart', max: const Duration(seconds: 4));
    expect(lab().event?.text, 'The SX Player stopped by itself and was started again - the lights were dark for a few seconds.');
    await until(() => lab().statusJson?['bo'] == true && (lab().statusJson?['on'] as List).isNotEmpty);
    expect(lab().status!.on, ['page1_button2']);
    expect((lab().statusJson!['fd']! as List).first, 0.25);
  });

  test('the Auto Show moves to the player and back', () async {
    final auto = _FakeAuto()..running = true;
    engine.provide<PlayerAutoShowLink>(auto);
    final s = await call('/api/lab/start', {});
    expect(s['auto'], isTrue);
    expect(auto.restarts, 1);
    auto.onPlayer = true;
    expect(lab().titleOn('RED'), isTrue);
    await until(() => frameOf(log)[1] == 255, reason: 'the Auto Show pressed RED by title');
    expect(lab().setBpm(100), isTrue);
    await until(() => lab().status?.bpm == 100);
    await call('/api/lab/stop', {});
    expect(auto.restarts, 2, reason: 'back to ShowXpress');
    expect(lab().titleOn('RED'), isFalse);
  });

  test('carries on with what ShowXpress was playing', () async {
    final remote = _FakeRemote()
      ..now = [(page: ' Setup ', title: 'BLUE'), (page: 'COLORS', title: 'RED'), (page: 'BEATS', title: 'RED'), (page: 'BEATS', title: 'A|B')];
    engine.provide<PlayerShowXpressLink>(remote);
    sx.running = true;
    expect(await call('/api/lab/snap', {}), {
      'ok': true,
      'titles': ['RED'],
    });
    sx.running = false;
    final s = await call('/api/lab/start', {});
    expect(s['carried'], ['RED']);
    expect(remote.cleared, ['what the SX Player was playing']);
    await until(() => frameOf(log)[1] == 255);
  });

  test("the player's own pages", () async {
    final layout = _FakeLayout()
      ..customPages = [
        const PlayerPageSpec(
          id: 'x1',
          swap: true,
          buttons: [
            PlayerButtonSpec(id: 'x1_b1', title: 'MY BLUE', file: 'BLUE.scex', fader: 0, bpm: false, flash: false, beats: 1),
            PlayerButtonSpec(id: 'x1_b2', title: 'GONE', file: 'GONE.scex', fader: 0, bpm: false, flash: false, beats: 1),
          ],
        ),
      ];
    engine.provide<PlayerLayoutSource>(layout);
    await call('/api/lab/start', {});
    expect(await cmd({'cmd': 'press', 'sec': 'x1_b2'}), {'ok': false, 'error': 'The file for GONE is missing.'});
    expect(await cmd({'cmd': 'press', 'sec': 'X1_B1'}), {'ok': true});
    await until(() => frameOf(log)[2] == 200);
    // the layout changes: the button goes away and stops
    layout.customPages = const [];
    engine.find<LabPlayerHooks>()!.syncExtras();
    await until(() => frameOf(log).isEmpty);
    expect(await cmd({'cmd': 'press', 'sec': 'x1_b1'}), {'ok': false, 'error': 'That button is not in the show any more - press Reload.'});
  });
}
