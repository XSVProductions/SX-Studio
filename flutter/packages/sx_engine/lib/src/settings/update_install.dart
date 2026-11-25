import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../show/show_env.dart';

/// Saves what [from] serves into [to]. Throws when it can't.
typedef Download = Future<void> Function(Uri from, File to);

/// Starts a program that keeps running after SX Studio has closed.
typedef StartDetached = Future<void> Function(String exe, List<String> args);

/// Installs an update: downloads the release's installer and starts a small
/// script that runs it and opens the new version. SX Studio closes meanwhile.
///
/// Port of the `/api/update/install` branch of `df_aim_gui.ps1`. On Windows
/// the installer runs silently and the script opens [appExe] again. On the
/// Mac the installer opens for the user to follow, then the app in
/// Applications opens.
class UpdateInstaller {
  UpdateInstaller({required this.appExe, bool? mac, Download? download, StartDetached? start, String? tempDir})
    : mac = mac ?? Platform.isMacOS,
      _download = download ?? _fetch,
      _start = start ?? _detached,
      _temp = tempDir ?? Directory.systemTemp.path;

  /// The installed app's program (`sx_studio.exe`).
  final String appExe;
  final bool mac;
  final Download _download;
  final StartDetached _start;
  final String _temp;

  /// Downloads [u]'s installer and starts it. Throws `ToolError` with the old
  /// message when the download fails.
  Future<void> install(UpdateInfo u) async {
    final installer = p.join(_temp, u.name.replaceAll(RegExp(r'[^\w.-]'), '_'));
    try {
      await _download(Uri.parse(u.asset), File(installer));
    } on Object catch (err) {
      throw ToolError('Download failed: $err');
    }
    if (mac) {
      final script = p.join(_temp, 'sxh_update.sh');
      File(script).writeAsStringSync("sleep 2\nopen -W ${_sh(installer)}\nsleep 1\nopen '/Applications/SX Studio.app'\n");
      await _start('/bin/bash', [script]);
    } else {
      final script = p.join(_temp, 'sxh_update.ps1');
      File(script).writeAsStringSync(
        'Start-Sleep 2\r\n'
        "Start-Process -Wait -FilePath ${_ps(installer)} -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART'\r\n"
        'Start-Process -FilePath ${_ps(appExe)}\r\n',
      );
      await _start('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script]);
    }
  }
}

// A path inside single quotes. A user name can hold an apostrophe.
String _ps(String s) => "'${s.replaceAll("'", "''")}'";
String _sh(String s) => "'${s.replaceAll("'", r"'\''")}'";

Future<void> _detached(String exe, List<String> args) => Process.start(exe, args, mode: ProcessStartMode.detached);

/// The real download. GitHub sends the browser on to its file store, which
/// `HttpClient` follows. Sends a generic User-Agent and nothing else.
Future<void> _fetch(Uri from, File to) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await http.getUrl(from);
    req.headers.set('User-Agent', 'SX-Studio');
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
    await res.pipe(to.openWrite()).timeout(const Duration(seconds: 300));
  } finally {
    http.close(force: true);
  }
}
