import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:sx_release/sx_release.dart';
import 'package:test/test.dart';

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

const _setup = 'SX-Studio-windows-setup-2.1.0.exe';
const _base = 'https://github.com/XSVProductions/SX-Studio/releases/download/v2.1.0';

Json _release(String tag, {List<String> assets = const [_setup, 'SX-Studio-mac-2.1.0.pkg', manifestName, signatureName, sumsName]}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/XSVProductions/SX-Studio/releases/tag/$tag',
  'assets': [
    for (final a in assets) {'name': a, 'browser_download_url': 'https://github.com/XSVProductions/SX-Studio/releases/download/$tag/$a'},
  ],
};

void main() {
  late Directory tmp;
  late Engine engine;
  late SxClient laptop;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sx_update_');
    engine = Engine(
      EngineConfig(port: 0, token: 't', settingsDir: p.join(tmp.path, 'cfg'), showPath: tmp.path, appVersion: '2.0.0'),
      sx: _FakeSx(),
    );
    await engine.start();
    laptop = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 't');
  });

  tearDown(() async {
    laptop.close();
    await engine.stop();
    tmp.deleteSync(recursive: true);
  });

  void github(Json Function() answer, {bool mac = false}) => engine.provide(UpdateChecker(current: '2.0.0', mac: mac, fetch: () async => answer()));

  late ({String private, String public}) key;
  setUpAll(() async => key = await newReleaseKey());

  /// A GitHub that serves [files] by URL: the installer and a release.json
  /// naming it (or [platforms]), signed with the test key, or by [signer].
  Future<Map<String, List<int>>> served({List<int>? body, String version = '2.1.0', String? signer, Map<String, ReleaseAsset>? platforms}) async {
    final bytes = body ?? utf8.encode('installer bytes');
    final real = utf8.encode('installer bytes');
    final m = ReleaseManifest(
      version: version,
      platforms:
          platforms ??
          {
            'windows': ReleaseAsset(file: _setup, size: real.length, sha256: '${sha256.convert(real)}', args: const ['/VERYSILENT', '/SUPPRESSMSGBOXES']),
          },
    ).encode();
    return {'$_base/$_setup': bytes, '$_base/$manifestName': m, '$_base/$signatureName': utf8.encode(await signManifest(m, signer ?? key.private))};
  }

  UpdateInstaller installer(Map<String, List<int>> files, List<String> started, {bool mac = false}) => UpdateInstaller(
    appExe: r'C:\Apps\sx_studio.exe',
    mac: mac,
    tempDir: tmp.path,
    publicKey: key.public,
    download: (from, to) async {
      final body = files['$from'];
      if (body == null) throw DownloadMissing(from);
      to.writeAsBytesSync(body);
    },
    start: (exe, args) async => started.add([exe, ...args].join(' ')),
  );

  group('asset pick', () {
    test('Windows takes the .exe, the Mac the .pkg', () async {
      github(() => _release('v2.1.0'));
      final w = await laptop.update();
      expect((w.newer, w.name, w.asset), (true, _setup, '$_base/$_setup'));
      github(() => _release('v2.1.0'), mac: true);
      final m = await laptop.update();
      expect((m.newer, m.name, m.mac), (true, 'SX-Studio-mac-2.1.0.pkg', true));
    });

    test('a release without an installer for this computer is not newer', () async {
      github(() => _release('v2.1.0', assets: ['SX-Studio-mac-2.1.0.pkg', sumsName]));
      expect((await laptop.update()).newer, isFalse);
      expect((await laptop.updateInstall()).error, 'No newer version found on GitHub.');
    });

    test('versions compare like .NET, the v trimmed', () async {
      github(() => _release('v1.10'));
      expect((await laptop.update(fresh: true)).newer, isFalse);
      github(() => _release('2.0.1'));
      expect((await laptop.update(fresh: true)).latest, '2.0.1');
      expect(versionNewer('2.0.0.1', '2.0.0'), isTrue);
      expect(versionNewer('2.0', '2.0.0'), isFalse);
      expect(versionNewer('10.0', '9.9.9'), isTrue);
    });
  });

  group('install', () {
    test('downloads, checks the signature and the installer, then quits; the installer starts only when launched', () async {
      github(() => _release('v2.1.0'));
      final started = <String>[];
      final inst = installer(await served(), started);
      engine.provide(inst);
      final r = await laptop.updateInstall();
      expect(r.ok, isTrue, reason: r.error);
      expect(r.extra['restarting'], isTrue);
      expect(engine.lifetime.quit, isTrue);
      expect(await engine.lifetime.quitting, QuitReason.update);
      expect(started, isEmpty);
      final exe = p.join(tmp.path, _setup);
      expect(inst.ready, exe);
      expect(File(p.join(tmp.path, 'sxh_$manifestName')).existsSync(), isFalse);

      await inst.launch();
      await inst.launch();
      expect(started, ['$exe /VERYSILENT /SUPPRESSMSGBOXES'], reason: 'the arguments the signed file gives, once');
    });

    test('the Mac opens the pkg, then the app', () async {
      final started = <String>[];
      const pkg = 'SX-Studio-mac-2.1.0.pkg';
      final body = utf8.encode('pkg');
      final files = await served(
        platforms: {'mac': ReleaseAsset(file: pkg, size: body.length, sha256: '${sha256.convert(body)}')},
      );
      files['$_base/$pkg'] = body;
      final inst = installer(files, started, mac: true);
      await inst.download(const UpdateInfo(ok: true, current: '2.0.0', latest: '2.1.0', newer: true, asset: '$_base/$pkg', name: pkg));
      await inst.launch();
      expect(started.single, "/bin/bash -c open -W '${p.join(tmp.path, pkg)}'; sleep 1; open '/Applications/SX Studio.app'");
    });

    Future<void> refused(Map<String, List<int>> files, String error) async {
      github(() => _release('v2.1.0'));
      final started = <String>[];
      final inst = installer(files, started);
      engine.provide(inst);
      final r = await laptop.updateInstall();
      expect((r.ok, r.error), (false, error));
      expect(engine.lifetime.quit, isFalse);
      await inst.launch();
      expect(started, isEmpty);
    }

    const unsigned = "This update isn't signed by SX Studio. It was not installed.";

    test('an unsigned, wrongly signed or tampered release is refused', () async {
      final ok = await served();
      await refused({...ok}..remove('$_base/$manifestName'), unsigned);
      await refused({...ok}..remove('$_base/$signatureName'), unsigned);
      await refused(await served(signer: (await newReleaseKey()).private), unsigned);
      final tampered = utf8.decode(ok['$_base/$manifestName']!).replaceFirst('/SUPPRESSMSGBOXES', '/LOG');
      await refused({...ok, '$_base/$manifestName': utf8.encode(tampered)}, unsigned);
      await refused({...ok, '$_base/$signatureName': utf8.encode('garbage')}, unsigned);
    });

    test("another version's signed file is refused", () async {
      await refused(await served(version: '2.0.5'), unsigned);
    });

    test('an installer that is not the one named is refused and deleted', () async {
      await refused(await served(body: utf8.encode('installer bytez')), 'The download was damaged. Try again.');
      expect(File(p.join(tmp.path, _setup)).existsSync(), isFalse);
      await refused(await served(body: utf8.encode('installer bytes and more')), 'The download was damaged. Try again.');
    });

    test('a missing installer or a failed download says why', () async {
      await refused((await served())..remove('$_base/$_setup'), 'Download failed: GitHub answered 404');
      github(() => _release('v2.1.0'));
      engine.provide(
        UpdateInstaller(
          appExe: 'x',
          mac: false,
          tempDir: tmp.path,
          publicKey: key.public,
          download: (from, to) async => throw const SocketException('No route to host'),
        ),
      );
      expect((await laptop.updateInstall()).error, 'Download failed: No route to host');
    });

    test('a signed file without an installer for this computer installs nothing', () async {
      final mac = ReleaseAsset(file: 'x.pkg', size: 1, sha256: 'a' * 64);
      await refused(await served(platforms: {'mac': mac}), 'No newer version found on GitHub.');
    });

    test('only from github.com, and only when newer', () async {
      github(
        () => {
          'tag_name': 'v2.1.0',
          'assets': [
            {'name': _setup, 'browser_download_url': 'https://example.com/$_setup'},
          ],
        },
      );
      engine.provide(installer(await served(), []));
      expect((await laptop.updateInstall()).error, 'No newer version found on GitHub.');
      github(() => _release('v2.0.0'));
      expect((await laptop.updateInstall()).error, 'No newer version found on GitHub.');
    });

    test('a phone may not install', () async {
      expect(engine.api.find('/api/update/install')!.phone, isFalse);
    });
  });

  test('file names are made safe as before', () {
    expect(safeFileName('SX Studio (1).exe'), 'SX_Studio__1_.exe');
  });
}
