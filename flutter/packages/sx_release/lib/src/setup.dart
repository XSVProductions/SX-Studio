import 'dart:convert';
import 'dart:io';

import 'manifest.dart';
import 'release_key.dart';
import 'verify.dart';

/// Where the setup program asks for the newest release. The same question
/// the app's Update asks.
final latestReleaseUrl = Uri.parse('https://api.github.com/repos/XSVProductions/SX-Studio/releases/latest');

/// A release as GitHub's API describes it: the tag and each asset's
/// download URL by file name.
class LatestRelease {
  const LatestRelease({required this.tag, required this.assets});

  /// Reads GitHub's answer. Throws [ReleaseError] when it isn't a release.
  factory LatestRelease.parse(List<int> bytes) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ReleaseError('GitHub did not answer as expected.');
    }
    if (j is! Map || j['tag_name'] is! String) throw const ReleaseError('GitHub did not answer as expected.');
    final list = j['assets'];
    return LatestRelease(
      tag: j['tag_name'] as String,
      assets: {
        if (list is List)
          for (final a in list)
            if (a is Map && a['name'] is String && a['browser_download_url'] is String) a['name'] as String: Uri.parse(a['browser_download_url'] as String),
      },
    );
  }

  final String tag;
  final Map<String, Uri> assets;

  /// The URL of asset [name] on github.com. Throws [ReleaseError] with
  /// [missing] when the release has none.
  Uri asset(String name, String missing) {
    final u = assets[name];
    if (u == null || !isGithubDownload(u)) throw ReleaseError(missing);
    return u;
  }
}

/// Downloads a URL whole.
typedef GetBytes = Future<List<int>> Function(Uri from);

/// Downloads a URL into a file.
typedef SaveTo = Future<void> Function(Uri from, File to);

/// The setup program's work up to starting the installer: asks GitHub for
/// the newest release, checks its `release.json` against the key built in,
/// downloads the Windows installer it names into [temp] and checks its size
/// and SHA-256. Returns the installer and how to start it. Throws
/// [ReleaseError] in plain words; nothing is run before every check passed.
Future<({File installer, ReleaseManifest manifest, ReleaseAsset asset})> fetchSetup({
  required Directory temp,
  GetBytes get = httpGetBytes,
  SaveTo save = httpSave,
  void Function(String line) say = _quiet,
  String publicKey = releasePublicKey,
  String platform = 'windows',
}) async {
  say('Asking GitHub for the newest SX Studio...');
  final release = LatestRelease.parse(await _net(() => get(latestReleaseUrl)));
  const unsigned = "The newest release of SX Studio isn't signed. Nothing was installed.";
  final manifestUrl = release.asset(manifestName, unsigned);
  final sigUrl = release.asset(signatureName, unsigned);
  final manifestBytes = await _net(() => get(manifestUrl));
  final sig = utf8.decode(await _net(() => get(sigUrl)), allowMalformed: true);
  final ReleaseManifest manifest;
  try {
    manifest = await verifyManifest(manifestBytes, sig, publicKey: publicKey);
  } on ReleaseError {
    throw const ReleaseError(unsigned);
  }
  final asset = manifest.platforms[platform];
  if (asset == null) throw const ReleaseError('The newest release of SX Studio has no installer for Windows.');
  final url = release.asset(asset.file, 'The installer the newest release names is not in it.');
  say('Downloading SX Studio ${manifest.version}...');
  final file = File('${temp.path}${Platform.pathSeparator}${asset.file}');
  await _net(() => save(url, file));
  say('Checking the download...');
  try {
    await checkInstaller(file, asset);
  } on ReleaseError {
    throw const ReleaseError('The download was damaged. Run the setup again.');
  }
  return (installer: file, manifest: manifest, asset: asset);
}

Future<T> _net<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on ReleaseError {
    rethrow;
  } on Object catch (e) {
    throw ReleaseError(
      'Could not reach GitHub: ${switch (e) {
        HttpException(:final message) => message,
        SocketException(:final message) => message,
        _ => '$e',
      }}',
    );
  }
}

void _quiet(String _) {}
