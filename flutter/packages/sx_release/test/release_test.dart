import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sx_release/sx_release.dart';
import 'package:test/test.dart';

const _base = 'https://github.com/XSVProductions/SX-Studio/releases/download/v2.1.0';
const _setup = 'SX-Studio-windows-setup-2.1.0.exe';
final _body = utf8.encode('installer bytes');

void main() {
  late ({String private, String public}) key;
  late Directory tmp;

  setUpAll(() async => key = await newReleaseKey());
  setUp(() => tmp = Directory.systemTemp.createTempSync('sx_release_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ReleaseManifest manifest({List<int>? body, int? size}) => ReleaseManifest(
    version: '2.1.0',
    platforms: {
      'windows': ReleaseAsset(file: _setup, size: size ?? (body ?? _body).length, sha256: '${sha256.convert(body ?? _body)}', args: const ['/VERYSILENT']),
    },
  );

  group('signature', () {
    test('a release signed with the key reads back as written', () async {
      final bytes = manifest().encode();
      final m = await verifyManifest(bytes, await signManifest(bytes, key.private), publicKey: key.public);
      expect(m.version, '2.1.0');
      expect(m.platforms['windows']!.toJson(), manifest().platforms['windows']!.toJson());
    });

    test('another key, a changed byte, a bad or missing signature: all refused', () async {
      final bytes = manifest().encode();
      final sig = await signManifest(bytes, key.private);
      final other = await newReleaseKey();
      Future<void> refused(List<int> b, String s, {String? pub}) =>
          expectLater(verifyManifest(b, s, publicKey: pub ?? key.public), throwsA(isA<ReleaseError>().having((e) => e.message, 'message', unsignedMessage)));
      await refused(bytes, sig, pub: other.public);
      await refused(bytes, await signManifest(bytes, other.private));
      final tampered = utf8.encode(utf8.decode(bytes).replaceFirst('"size": ', '"size": 1'));
      await refused(tampered, sig);
      await refused(bytes, '');
      await refused(bytes, 'not base64!');
      await refused(bytes, base64.encode(List.filled(64, 0)));
    });

    test('a signed file of an unknown format is refused too', () async {
      final bytes = utf8.encode('{"format": 2, "version": "3.0.0", "platforms": {}}');
      expect(verifyManifest(bytes, await signManifest(bytes, key.private), publicKey: key.public), throwsA(isA<ReleaseError>()));
    });

    test('the key built in is a real key', () => expect(base64.decode(releasePublicKey), hasLength(32)));
  });

  group('installer', () {
    test('passes only with the size and hash the release names', () async {
      final f = File('${tmp.path}/a.exe')..writeAsBytesSync(_body);
      await checkInstaller(f, manifest().platforms['windows']!);
      expect(f.existsSync(), isTrue);

      final wrongHash = manifest(body: utf8.encode('other bytes!!!!')).platforms['windows']!;
      await expectLater(checkInstaller(f, wrongHash), throwsA(isA<ReleaseError>().having((e) => e.message, 'message', damagedMessage)));
      expect(f.existsSync(), isFalse, reason: 'a damaged file is deleted');

      f.writeAsBytesSync(_body);
      await expectLater(checkInstaller(f, manifest(size: _body.length + 1).platforms['windows']!), throwsA(isA<ReleaseError>()));
    });

    test('downloads come from github.com only', () {
      expect(isGithubDownload(Uri.parse('$_base/$_setup')), isTrue);
      expect(isGithubDownload(Uri.parse('http://github.com/x')), isFalse);
      expect(isGithubDownload(Uri.parse('https://github.com.evil.example/x')), isFalse);
      expect(isGithubDownload(Uri.parse('https://objects.githubusercontent.com/x')), isFalse);
      expect('${siblingAsset(Uri.parse('$_base/$_setup'), manifestName)}', '$_base/$manifestName');
    });
  });

  group('the setup program', () {
    /// A GitHub serving a release with [assets] (name to body), each at its
    /// github.com URL unless [urls] says otherwise.
    Future<({File installer, ReleaseManifest manifest, ReleaseAsset asset})> run(Map<String, List<int>> assets, {Map<String, String> urls = const {}}) {
      final latest = utf8.encode(
        jsonEncode({
          'tag_name': 'v2.1.0',
          'assets': [
            for (final n in assets.keys) {'name': n, 'browser_download_url': urls[n] ?? '$_base/$n'},
          ],
        }),
      );
      List<int> serve(Uri u) {
        if (u == latestReleaseUrl) return latest;
        final name = u.pathSegments.last;
        final body = assets[name];
        if (body == null || (urls[name] ?? '$_base/$name') != '$u') throw DownloadMissing(u);
        return body;
      }

      return fetchSetup(temp: tmp, publicKey: key.public, get: (u) async => serve(u), save: (u, f) async => f.writeAsBytesSync(serve(u)));
    }

    Future<Map<String, List<int>>> signed({List<int>? body, ReleaseManifest? m, String? signer}) async {
      final bytes = (m ?? manifest()).encode();
      return {
        _setup: body ?? _body,
        manifestName: bytes,
        signatureName: utf8.encode(await signManifest(bytes, signer ?? key.private)),
        'SX-Studio-Setup.exe': [1],
      };
    }

    Matcher says(String m) => throwsA(isA<ReleaseError>().having((e) => e.message, 'message', m));
    const unsigned = "The newest release of SX Studio isn't signed. Nothing was installed.";

    test('downloads and checks the installer the signed file names', () async {
      final got = await run(await signed());
      expect(got.installer.readAsBytesSync(), _body);
      expect(got.manifest.version, '2.1.0');
      expect(got.asset.setupArgs, isEmpty);
    });

    test('refuses an unsigned, wrongly signed or tampered release', () async {
      final ok = await signed();
      await expectLater(run({_setup: _body}), says(unsigned));
      await expectLater(run({...ok}..remove(signatureName)), says(unsigned));
      await expectLater(run(await signed(signer: (await newReleaseKey()).private)), says(unsigned));
      final tampered = {...ok, manifestName: utf8.encode(utf8.decode(ok[manifestName]!).replaceFirst('2.1.0', '2.1.1'))};
      await expectLater(run(tampered), says(unsigned));
    });

    test('refuses a download that is not the named installer', () async {
      await expectLater(run(await signed(body: utf8.encode('something else'))), says('The download was damaged. Run the setup again.'));
      expect(tmp.listSync(), isEmpty);
    });

    test('refuses files not on github.com and a missing installer', () async {
      await expectLater(run(await signed(), urls: {_setup: 'https://example.com/$_setup'}), says('The installer the newest release names is not in it.'));
      await expectLater(run(await signed(), urls: {manifestName: 'https://example.com/$manifestName'}), says(unsigned));
      await expectLater(run((await signed())..remove(_setup)), says('The installer the newest release names is not in it.'));
      final macOnly = ReleaseManifest(version: '2.1.0', platforms: {'mac': manifest().platforms['windows']!});
      await expectLater(run(await signed(m: macOnly)), says('The newest release of SX Studio has no installer for Windows.'));
    });

    test('says when GitHub cannot be reached', () async {
      final err = fetchSetup(temp: tmp, publicKey: key.public, get: (u) async => throw const SocketException('No route to host'));
      await expectLater(err, says('Could not reach GitHub: No route to host'));
    });
  });
}
