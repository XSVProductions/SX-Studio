// The release key and the signed release.json. Run from packages/sx_release.
//
//   dart run sx_release:release_tool keygen [--out <file>]
//       Makes the release key. Writes the private key to <file> (default
//       %USERPROFILE%\.sx-release\release_key), never inside a git folder and
//       never over an existing key, and prints the public key to put in
//       lib/src/release_key.dart.
//   dart run sx_release:release_tool pubkey
//       Prints the public key of the key file.
//   dart run sx_release:release_tool manifest --version <v> --out <dir> [--windows <exe>] [--mac <pkg>]
//       Writes release.json, release.json.sig and SHA256SUMS.txt into <dir>.
//
// The key file comes from SX_RELEASE_KEY, otherwise the default above.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sx_release/sx_release.dart';

/// The silent install the app's Update runs. The installer opens the app
/// again after any silent install.
const windowsUpdateArgs = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'];

Future<void> main(List<String> args) async {
  try {
    switch (args.firstOrNull) {
      case 'keygen':
        await _keygen(_opt(args, '--out') ?? defaultKeyPath());
      case 'pubkey':
        stdout.writeln(await publicKeyOf(_readKey()));
      case 'manifest':
        await _manifest(args);
      default:
        stderr.writeln('Use: release_tool keygen [--out <file>] | pubkey | manifest --version <v> --out <dir> [--windows <exe>] [--mac <pkg>]');
        exitCode = 64;
    }
  } on _Stop catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}

class _Stop implements Exception {
  const _Stop(this.message);
  final String message;
}

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// `%USERPROFILE%\.sx-release\release_key` (`~/.sx-release/release_key`).
String defaultKeyPath() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  return [home, '.sx-release', 'release_key'].join(Platform.pathSeparator);
}

String _keyPath() => Platform.environment['SX_RELEASE_KEY'] ?? defaultKeyPath();

String _readKey() {
  final f = File(_keyPath());
  if (!f.existsSync()) throw _Stop('No release key at ${f.path}. Set SX_RELEASE_KEY to its file.');
  return f.readAsStringSync().trim();
}

/// The git folder [path] is in, or null.
String? _inGit(String path) {
  for (var d = File(path).absolute.parent; ; d = d.parent) {
    if (FileSystemEntity.typeSync('${d.path}${Platform.pathSeparator}.git') != FileSystemEntityType.notFound) return d.path;
    if (d.parent.path == d.path) return null;
  }
}

Future<void> _keygen(String out) async {
  final f = File(out).absolute;
  if (f.existsSync()) throw _Stop('${f.path} already exists. Keep that key: apps out there trust only it.');
  if (_inGit(f.path) case final repo?) throw _Stop('${f.path} is inside the git folder $repo. Keep the private key out of git.');
  final key = await newReleaseKey();
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${key.private}\n');
  stdout.writeln('Private key: ${f.path}');
  stdout.writeln('Keep it safe and back it up offline. Anyone with it can ship an update every SX Studio installs.');
  stdout.writeln('Public key (put it in packages/sx_release/lib/src/release_key.dart):');
  stdout.writeln(key.public);
}

Future<void> _manifest(List<String> args) async {
  final version = _opt(args, '--version');
  final out = _opt(args, '--out');
  if (version == null || out == null) throw const _Stop('manifest needs --version and --out.');
  final private = _readKey();
  if (await publicKeyOf(private) != releasePublicKey) {
    throw const _Stop('The key file is not the release key built into the app (lib/src/release_key.dart). Nothing was signed.');
  }
  ReleaseAsset asset(String path, List<String> args, List<String> setupArgs) {
    final f = File(path);
    if (!f.existsSync()) throw _Stop('No file $path.');
    final bytes = f.readAsBytesSync();
    return ReleaseAsset(file: f.uri.pathSegments.last, size: bytes.length, sha256: '${sha256.convert(bytes)}', args: args, setupArgs: setupArgs);
  }

  final platforms = {
    if (_opt(args, '--windows') case final w?) 'windows': asset(w, windowsUpdateArgs, const []),
    if (_opt(args, '--mac') case final m?) 'mac': asset(m, const [], const []),
  };
  if (platforms.isEmpty) throw const _Stop('manifest needs --windows or --mac.');
  final manifest = ReleaseManifest(version: version, platforms: platforms).encode();
  final sig = await signManifest(manifest, private);
  await verifyManifest(manifest, sig); // the same check the app makes
  final dir = Directory(out)..createSync(recursive: true);
  String at(String name) => '${dir.path}${Platform.pathSeparator}$name';
  File(at(manifestName)).writeAsBytesSync(manifest);
  File(at(signatureName)).writeAsStringSync('$sig\n');
  final sums = [for (final a in platforms.values) '${a.sha256}  ${a.file}', '${sha256.convert(manifest)}  $manifestName'];
  File(at(sumsName)).writeAsBytesSync(utf8.encode('${sums.join('\n')}\n'));
  stdout.writeln('Signed $manifestName for $version: ${platforms.values.map((a) => a.file).join(', ')}');
}
