import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'sx_test_show.dart';

// `/api/apc40`, `/api/apc40/status` and `/api/apc40/save`, through the real
// server and the shared client. The bridge never runs here: the engine is on
// a development show (and not on Windows).

/// A runner that says the APC40 is in use.
class _BusyRunner extends Apc40Runner {
  _BusyRunner() : super(enabled: false, showRoot: () => '', layoutFile: () => File(''), sxRunning: () => false);

  @override
  bool get busy => true;
}

void main() {
  late SxTestShow t;
  late Directory settings;
  late Engine engine;
  late SxClient client;

  setUp(() async {
    t = await SxTestShow.create();
    settings = Directory(p.join(t.tmp.path, 'settings'))..createSync();
    engine = Engine(EngineConfig(port: 0, token: 'k', showPath: t.root, settingsDir: settings.path));
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'k');
  });

  tearDown(() async {
    client.close();
    await engine.stop();
    await t.dispose();
  });

  Future<Json> post(String path, Object? body) async {
    final c = HttpClient();
    try {
      final req = await c.postUrl(Uri.parse('http://127.0.0.1:${engine.port}$path'));
      req.headers
        ..set('x-sx-token', 'k')
        ..contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, Object?>();
    } finally {
      c.close();
    }
  }

  test('the tab: the defaults, the show buttons, where the layout is kept, no bridge here', () async {
    final i = await client.apc40();
    expect(i.file, p.join(settings.path, 'apc40.json'));
    expect(i.show, 'Test Show');
    expect([for (final pg in i.layout.pages) pg.name], ['Dancefloor']);
    expect(i.layout.faders, {1: 0, 2: 1, 3: 2, 4: 3});
    expect([for (final b in i.buttons) b.title], ['CIRCLE', 'FIGURE 8', 'RED', 'BLUE', 'RIG ID']);
    expect(i.windows, Platform.isWindows);
    expect(i.status, isNull);
    expect(await client.apc40Status(), isNull);
    expect(engine.find<Apc40Runner>()!.alive, false);
  });

  test('save writes the cleaned layout and answers with it', () async {
    final lay = Apc40Layout(
      pages: [
        Apc40Page(name: '  Floor\u0001  ', pads: {0: ' RED ', 39: 'BLUE'}, colors: {0: const Apc40Colors(on: 5, off: 6), 7: const Apc40Colors(on: 1, off: 1)}),
      ],
      faders: {1: 2, 12: 0},
    );
    final i = await client.apc40Save(lay);
    expect(i.layout.pages.single.name, 'Floor');
    expect(i.layout.pages.single.pads, {0: 'RED', 39: 'BLUE'});
    expect(i.layout.pages.single.colors.keys, [0]);
    expect(i.layout.faders, {1: 2});
    final file = File(p.join(settings.path, 'apc40.json'));
    expect(file.readAsStringSync(), apc40LayoutJson(i.layout));
    expect((await client.apc40()).layout.toJson(), i.layout.toJson());
  });

  test('save refuses a layout without pages, and nothing is written', () async {
    for (final body in <Object?>[
      {},
      {'layout': null},
      {'layout': {}},
      {
        'layout': {'faders': {}},
      },
      {'layout': 'text'},
    ]) {
      final r = await post('/api/apc40/save', body);
      expect(r['ok'], false, reason: '$body');
      expect(r['error'], 'Nothing to save.', reason: '$body');
    }
    expect(File(p.join(settings.path, 'apc40.json')).existsSync(), false);
  });

  test('a layout sent as a list of one is saved, as the old server piped it', () async {
    final r = await post('/api/apc40/save', {
      'layout': [
        {
          'pages': [
            {'name': 'Listed'},
          ],
        },
      ],
    });
    expect(r['ok'], true, reason: '$r');
    expect(readApc40Layout(apc40LayoutFile(settings.path)).pages.single.name, 'Listed');
  });

  test('phones reach all three routes, and only save is a POST', () {
    final routes = {for (final r in engine.api.routes) r.path: r};
    expect(routes['/api/apc40']!.method, 'GET');
    expect(routes['/api/apc40/status']!.method, 'GET');
    expect(routes['/api/apc40/save']!.method, 'POST');
    for (final path in ['/api/apc40', '/api/apc40/status', '/api/apc40/save']) {
      expect(routes[path]!.phone, true, reason: path);
      expect(routes[path]!.queue, isNull, reason: path);
    }
  });

  test('SX Studio does not quit when idle while the APC40 is in use', () {
    final idle = Engine(EngineConfig(port: 0, token: 'k', showPath: t.root, settingsDir: settings.path))..provide<Apc40Runner>(_BusyRunner());
    final l = Lifetime(busy: Lifetime.of(idle).busy, max: Duration.zero, clock: () => DateTime.now().add(const Duration(hours: 1)));
    l.step();
    expect(l.quit, false);
  });
}
