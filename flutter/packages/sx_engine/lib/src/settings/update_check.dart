import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';

/// Where SX Studio's releases are.
const releaseRepo = 'XSVProductions/SX-Studio';

/// Reads GitHub's newest release as JSON. Throws when GitHub can't be reached.
typedef ReleaseFetch = Future<Json> Function();

/// Asks GitHub for the newest release. Sends a generic User-Agent and nothing
/// about this computer.
Future<Json> fetchLatestRelease() async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await http.getUrl(Uri.parse('https://api.github.com/repos/$releaseRepo/releases/latest'));
    req.headers
      ..set('User-Agent', 'SX-Studio')
      ..set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
    final j = jsonDecode(text);
    if (j is! Map) throw const FormatException('not an object');
    return j.cast<String, Object?>();
  } finally {
    http.close(force: true);
  }
}

/// `[version]$a -gt [version]$b` in .NET: 2 to 4 whole numbers, and a missing
/// part counts as less than 0 (so 1.9 is older than 1.9.0). Throws
/// `FormatException` for anything else.
bool versionNewer(String a, String b) {
  List<int> parse(String v) {
    final parts = v.trim().split('.');
    if (parts.length < 2 || parts.length > 4) throw FormatException('not a version: $v');
    return [
      for (final s in parts)
        if (int.tryParse(s.trim()) case final n? when n >= 0 && !s.trim().startsWith('+')) n else throw FormatException('not a version: $v'),
      for (var i = parts.length; i < 4; i++) -1,
    ];
  }

  final x = parse(a), y = parse(b);
  for (var i = 0; i < 4; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}

/// The update check. The answer is kept for the rest of the run once GitHub
/// has answered; a failure is asked again next time. Port of `Get-Update`.
class UpdateChecker {
  UpdateChecker({required this.current, ReleaseFetch? fetch, bool? mac}) : _fetch = fetch ?? fetchLatestRelease, mac = mac ?? Platform.isMacOS;

  /// The running version.
  final String current;
  final ReleaseFetch _fetch;

  /// Look for the Mac installer (`.pkg`) instead of the Windows one (`.exe`).
  final bool mac;
  UpdateInfo? _cached;

  Future<UpdateInfo> check({bool fresh = false}) async {
    if (fresh) _cached = null;
    if (_cached case final c?) return c;
    final Json rel;
    try {
      rel = await _fetch();
    } on Object {
      return UpdateInfo(ok: false, mac: mac, current: current, error: 'Could not reach GitHub.');
    }
    final latest = rel.str('tag_name').replaceFirst(RegExp('^v+'), '');
    final want = RegExp(mac ? r'\.pkg$' : r'\.exe$', caseSensitive: false);
    final asset = rel.list('assets', (a) => a).where((a) => want.hasMatch(a.str('name'))).firstOrNull;
    var newer = false;
    try {
      newer = versionNewer(latest, current);
    } on FormatException {
      newer = false;
    }
    return _cached = UpdateInfo(
      ok: true,
      mac: mac,
      current: current,
      latest: latest,
      newer: newer && asset != null,
      asset: asset?.str('browser_download_url') ?? '',
      name: asset?.str('name') ?? '',
      page: rel.str('html_url'),
    );
  }
}
