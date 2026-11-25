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

class _FakeHooks implements LabPlayerHooks {
  var synced = 0;

  @override
  void syncExtras() => synced++;
}

class _FakeOpener implements Opener {
  final opened = <String>[];

  @override
  Future<void> open(String target) async => opened.add(target);
}

Json _release(String tag, {String asset = 'SX-Studio-Setup.exe'}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/XSVProductions/SX-Studio/releases/tag/$tag',
  'assets': [
    {'name': asset, 'browser_download_url': 'https://github.com/XSVProductions/SX-Studio/releases/download/$tag/$asset'},
  ],
};

void main() {
  late Directory tmp;
  late Engine engine;
  late SxClient laptop;
  late _FakeOpener opener;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_settings_routes_');
    engine = Engine(
      EngineConfig(port: 0, token: 't', settingsDir: p.join(tmp.path, 'cfg'), showPath: tmp.path, appVersion: '2.0.0'),
      sx: _FakeSx(),
    );
    opener = _FakeOpener();
    engine.provide<Opener>(opener);
    await engine.start();
    laptop = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
  });

  tearDown(() async {
    laptop.close();
    await engine.stop();
    tmp.deleteSync(recursive: true);
  });

  test('settings are saved to the settings folder given, and reopen reaches the queue', () async {
    final info = await laptop.settings();
    expect(info.ver, '2.0.0');
    expect(info.phone, isFalse);
    expect(info.settings.tabOrder, settingsTabIds);

    final s = await laptop.settingsSet(const SettingsChange(reopen: false, tabNames: {'rt': 'Rig'}));
    expect(s.reopen, isFalse);
    expect(s.tabNames, {'rt': 'Rig'});
    expect(engine.queue.reopen, isFalse);
    expect(File(p.join(tmp.path, 'cfg', 'settings.json')).readAsStringSync(), contains('"reopen":false'));
  });

  test("the player's own pages reach the player, and a saved layout syncs it", () async {
    final hooks = _FakeHooks();
    engine.provide<LabPlayerHooks>(hooks);
    await laptop.settingsSet(const SettingsChange(tabHidden: ['rt']));
    expect(hooks.synced, 0);
    await laptop.settingsSet(
      const SettingsChange(
        playerLayout: PlayerLayout(
          custom: [
            PlayerPage(
              id: 'x1',
              name: 'Mine',
              buttons: [PlayerButton(id: 'x1_b1', title: 'Chase', file: 'CHASE.scex', fader: 3, beats: 2)],
            ),
          ],
        ),
      ),
    );
    expect(hooks.synced, 1);
    final page = engine.find<PlayerLayoutSource>()!.customPages.single;
    expect(page.id, 'x1');
    expect(page.buttons.single.file, 'CHASE.scex');
    expect(page.buttons.single.fader, 3);
  });

  test('a Google Drive folder that is not there is refused', () async {
    await expectLater(
      laptop.settingsSet(SettingsChange(driveFolder: p.join(tmp.path, 'nope'))),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', startsWith("That folder doesn't exist"))),
    );
  });

  group('open on the computer', () {
    test('opens only the known places', () async {
      expect((await laptop.openOnComputer(OpenTarget.gddl)).ok, isTrue);
      expect((await laptop.openOnComputer(OpenTarget.show)).ok, isTrue);
      expect(opener.opened, ['https://www.google.com/drive/download/', tmp.path]);
      final r = await laptop.run('/api/open', {'what': '/etc'});
      expect(r.error, 'Nothing to open.');
    });

    test('says so when there are no backups yet', () async {
      final r = await laptop.openOnComputer(OpenTarget.backups);
      expect(r.error, 'No import backups yet - one is made each time you import from Google Drive.');
      expect(opener.opened, isEmpty);
    });
  });

  group('updates', () {
    void github(Json Function() answer) => engine.provide(UpdateChecker(current: '2.0.0', mac: false, fetch: () async => answer()));

    test('a newer release with an installer', () async {
      github(() => _release('v2.1.0'));
      final u = await laptop.update();
      expect(u.newer, isTrue);
      expect(u.latest, '2.1.0');
      expect(u.page, endsWith('/tag/v2.1.0'));
    });

    test('install opens the release page and runs nothing', () async {
      github(() => _release('v2.1.0'));
      final r = await laptop.updateInstall();
      expect(r.ok, isTrue, reason: r.error);
      expect(opener.opened, ['https://github.com/XSVProductions/SX-Studio/releases/tag/v2.1.0']);
    });

    test('nothing newer, or no installer for this computer', () async {
      github(() => _release('v2.0.0'));
      expect((await laptop.update()).newer, isFalse);
      github(() => _release('v3.0.0', asset: 'SX-Studio.pkg'));
      expect((await laptop.update()).newer, isFalse);
      expect((await laptop.updateInstall()).error, 'No newer version found on GitHub.');
      expect(opener.opened, isEmpty);
    });

    test('GitHub out of reach', () async {
      github(() => throw const SocketException('offline'));
      await expectLater(laptop.update(), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Could not reach GitHub.')));
    });

    test('the answer is kept until asked fresh', () async {
      var tag = 'v2.1.0';
      github(() => _release(tag));
      expect((await laptop.update()).latest, '2.1.0');
      tag = 'v2.2.0';
      expect((await laptop.update()).latest, '2.1.0');
      expect((await laptop.update(fresh: true)).latest, '2.2.0');
    });
  });

  test('versions compare like .NET', () {
    expect(versionNewer('1.9.0', '1.9'), isTrue);
    expect(versionNewer('1.10', '1.9.9'), isTrue);
    expect(versionNewer('2.0.0', '2.0.0'), isFalse);
    expect(() => versionNewer('2', '1.0'), throwsFormatException);
    expect(() => versionNewer('2.0-beta', '1.0'), throwsFormatException);
  });
}
