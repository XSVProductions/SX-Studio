import 'dart:convert';

/// The signed file of each release, and its signature next to it.
const manifestName = 'release.json';
const signatureName = 'release.json.sig';

/// Checksums of the release's files, for people. Nothing trusts it.
const sumsName = 'SHA256SUMS.txt';

/// One computer's installer in a release.
class ReleaseAsset {
  const ReleaseAsset({required this.file, required this.size, required this.sha256, this.args = const [], this.setupArgs = const []});

  /// The asset's file name in the release.
  final String file;

  /// Its length in bytes.
  final int size;

  /// Its SHA-256, lower-case hex.
  final String sha256;

  /// What the app's Update starts it with (silent).
  final List<String> args;

  /// What the setup program starts it with (a first install, shown).
  final List<String> setupArgs;

  Map<String, Object?> toJson() => {'file': file, 'size': size, 'sha256': sha256, 'args': args, 'setupArgs': setupArgs};

  /// Null when [j] isn't a complete entry.
  static ReleaseAsset? fromJson(Object? j) {
    if (j is! Map) return null;
    final (file, size, sha, args, setup) = (j['file'], j['size'], j['sha256'], j['args'] ?? const <Object?>[], j['setupArgs'] ?? const <Object?>[]);
    if (file is! String || file.isEmpty || file.contains('/') || file.contains(r'\')) return null;
    if (size is! int || size <= 0) return null;
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    if (args is! List || args.any((a) => a is! String) || setup is! List || setup.any((a) => a is! String)) return null;
    return ReleaseAsset(file: file, size: size, sha256: sha, args: args.cast<String>(), setupArgs: setup.cast<String>());
  }
}

/// `release.json`: the version, and per computer (`windows`, `mac`) the
/// installer. Signed as written, byte for byte.
///
/// The setup program reads `format`, `version` and `platforms.windows`
/// (`file`, `size`, `sha256`, `setupArgs`) and outlives app versions: add
/// fields freely, but change those only with a new [currentFormat].
class ReleaseManifest {
  const ReleaseManifest({required this.version, required this.platforms});

  /// The only format there is so far.
  static const currentFormat = 1;

  final String version;
  final Map<String, ReleaseAsset> platforms;

  Map<String, Object?> toJson() => {
    'format': currentFormat,
    'app': 'SX Studio',
    'version': version,
    'platforms': {for (final e in platforms.entries) e.key: e.value.toJson()},
  };

  /// The bytes to publish and sign.
  List<int> encode() => utf8.encode('${const JsonEncoder.withIndent('  ').convert(toJson())}\n');

  /// Reads `release.json`. Throws [FormatException] when it isn't one this
  /// program understands.
  static ReleaseManifest parse(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) throw const FormatException('not an object');
    if (j['format'] != currentFormat) throw FormatException('format ${j['format']}');
    final (version, platforms) = (j['version'], j['platforms']);
    if (version is! String || version.isEmpty || platforms is! Map) throw const FormatException('no version or platforms');
    final out = <String, ReleaseAsset>{};
    for (final e in platforms.entries) {
      final a = ReleaseAsset.fromJson(e.value);
      if (e.key is! String || a == null) throw FormatException('bad entry ${e.key}');
      out[e.key as String] = a;
    }
    return ReleaseManifest(version: version, platforms: out);
  }
}
