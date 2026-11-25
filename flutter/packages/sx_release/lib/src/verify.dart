import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart';

import 'manifest.dart';
import 'release_key.dart';

/// What the app says when a release's signature doesn't check out.
const unsignedMessage = "This update isn't signed by SX Studio. It was not installed.";

/// What the app says when a download isn't the file the release names.
const damagedMessage = 'The download was damaged. Try again.';

/// A refusal, in words for the user.
class ReleaseError implements Exception {
  const ReleaseError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// GitHub has no such file (404).
class DownloadMissing implements Exception {
  const DownloadMissing(this.url);

  final Uri url;

  @override
  String toString() => 'GitHub answered 404';
}

/// True for a URL this app downloads from: GitHub's own site only, as the
/// old `-notmatch '^https://github\.com/'`.
bool isGithubDownload(Uri u) => '$u'.startsWith('https://github.com/');

/// The file [name] of the release [asset] belongs to: the one next to it.
Uri siblingAsset(Uri asset, String name) => asset.replace(pathSegments: [...asset.pathSegments.take(asset.pathSegments.length - 1), name]);

final _ed = DartEd25519();

/// Checks [signature] (base64) over [manifest] against [publicKey] (base64)
/// and reads it. Throws [ReleaseError] with [unsignedMessage] for a missing,
/// wrong or tampered signature, and for a signed file it can't read.
Future<ReleaseManifest> verifyManifest(List<int> manifest, String signature, {String publicKey = releasePublicKey}) async {
  final List<int> sig, key;
  try {
    sig = base64.decode(signature.trim());
    key = base64.decode(publicKey);
  } on FormatException {
    throw const ReleaseError(unsignedMessage);
  }
  if (sig.length != 64 || key.length != 32) throw const ReleaseError(unsignedMessage);
  final ok = await _ed.verify(
    manifest,
    signature: Signature(sig, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
  );
  if (!ok) throw const ReleaseError(unsignedMessage);
  try {
    return ReleaseManifest.parse(manifest);
  } on FormatException {
    throw const ReleaseError(unsignedMessage);
  }
}

/// Throws [ReleaseError] with [damagedMessage] unless [f] has [a]'s size and
/// SHA-256. Deletes it then.
Future<void> checkInstaller(File f, ReleaseAsset a) async {
  final good = f.existsSync() && f.lengthSync() == a.size && '${await hash.sha256.bind(f.openRead()).first}' == a.sha256;
  if (good) return;
  try {
    if (f.existsSync()) f.deleteSync();
  } on FileSystemException {
    // the temp folder clears itself
  }
  throw const ReleaseError(damagedMessage);
}

/// A new release key: the private seed and the public key, base64.
Future<({String private, String public})> newReleaseKey() async {
  final kp = await _ed.newKeyPair();
  final seed = await kp.extractPrivateKeyBytes();
  return (private: base64.encode(seed), public: await publicKeyOf(base64.encode(seed)));
}

/// The public key (base64) of the private seed [private] (base64).
Future<String> publicKeyOf(String private) async {
  final kp = await _ed.newKeyPairFromSeed(base64.decode(private.trim()));
  return base64.encode((await kp.extractPublicKey()).bytes);
}

/// Signs [manifest] with the private seed [private] (base64). The base64
/// signature, the `release.json.sig` file.
Future<String> signManifest(List<int> manifest, String private) async {
  final kp = await _ed.newKeyPairFromSeed(base64.decode(private.trim()));
  return base64.encode((await _ed.sign(manifest, keyPair: kp)).bytes);
}

/// Downloads [from] whole. GitHub sends a download on to its file store,
/// which `HttpClient` follows. Sends a generic User-Agent and nothing else.
/// Throws [DownloadMissing] on 404 and [HttpException] on another answer.
Future<List<int>> httpGetBytes(Uri from) async {
  final b = BytesBuilder(copy: false);
  await _get(from, (res) => res.forEach(b.add));
  return b.takeBytes();
}

/// Downloads [from] into [to], as [httpGetBytes].
Future<void> httpSave(Uri from, File to) => _get(from, (res) => res.pipe(to.openWrite()));

Future<void> _get(Uri from, Future<void> Function(HttpClientResponse) body) async {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..userAgent = 'SX-Studio';
  try {
    final req = await http.getUrl(from);
    req.headers.set('Accept', from.host == 'api.github.com' ? 'application/vnd.github+json' : '*/*');
    final res = await req.close();
    if (res.statusCode == 404) throw DownloadMissing(from);
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}', uri: from);
    await body(res).timeout(const Duration(minutes: 5));
  } finally {
    http.close(force: true);
  }
}
