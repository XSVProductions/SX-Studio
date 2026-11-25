import 'client.dart';
import 'json.dart';

/// The newest release on GitHub against the running version.
class UpdateInfo {
  const UpdateInfo({
    required this.ok,
    required this.current,
    this.mac = false,
    this.latest = '',
    this.newer = false,
    this.asset = '',
    this.name = '',
    this.page = '',
    this.error = '',
  });

  factory UpdateInfo.fromJson(Json j) => UpdateInfo(
    ok: j.boolean('ok'),
    mac: j.boolean('mac'),
    current: j.str('current'),
    latest: j.str('latest'),
    newer: j.boolean('newer'),
    asset: j.str('asset'),
    name: j.str('name'),
    page: j.str('page'),
    error: j.str('error'),
  );

  /// False when GitHub couldn't be reached. [error] says so.
  final bool ok;
  final bool mac;

  /// The running version.
  final String current;

  /// The newest release's version, without the `v`.
  final String latest;

  /// [latest] is newer than [current] and has an installer for this computer.
  final bool newer;

  /// The installer's download address.
  final String asset;
  final String name;

  /// The release's page on GitHub.
  final String page;
  final String error;

  Json toJson() => ok
      ? {'ok': true, 'mac': mac, 'current': current, 'latest': latest, 'newer': newer, 'asset': asset, 'name': name, 'page': page}
      : {'ok': false, 'mac': mac, 'current': current, 'error': error};
}

extension UpdateApi on SxClient {
  /// Asks GitHub once per run. [fresh] asks again.
  Future<UpdateInfo> update({bool fresh = false}) => get('/api/update', UpdateInfo.fromJson, query: fresh ? const {'fresh': '1'} : null);

  /// Downloads the newest installer and checks it against the release's
  /// signed manifest. On success the answer has `restarting: true` and the
  /// app quits and runs the installer, which opens the new version. Without
  /// an installer (the engine on its own) it opens the release page instead.
  /// Laptop only. The old `/api/update/install`.
  Future<ToolResult> updateInstall() => run('/api/update/install');
}
