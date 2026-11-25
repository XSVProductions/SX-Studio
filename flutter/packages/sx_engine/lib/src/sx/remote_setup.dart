import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';

// SHOWXPRESS REMOTE SETUP: ShowXpress's "External App" remote (TCP 7348) only
// answers when it is switched on in two places. param.ini (ShowXpress's own
// settings, next to LightShows/) needs `[Network] LIVEMOBILEENABLE = yes`, and
// live.ini needs `[live] allow_live_mobile = yes`, a `live_mobile_password`, and
// `live_mobile = yes` on every page (a page without it can't be reached).
//
// Port of `Get-Setup` and `-Action Enable` in `sx_remote.ps1`.

/// ShowXpress's settings file for a show: `<TheLightingController>/param.ini`,
/// two folders up from `<TheLightingController>/LightShows/<show>`.
String paramIniPath(ShowEnv env) => p.join(p.dirname(p.dirname(env.root)), 'param.ini');

/// A text file as `Read-Text` in `sx_remote.ps1` reads it.
class _Text {
  _Text(String path) {
    final b = File(path).readAsBytesSync();
    bom = hasBom(b);
    text = readText(path);
    nl = text.contains('\r\n') ? '\r\n' : '\n';
  }

  late final bool bom;
  late final String text;
  late final String nl;
}

final _enabledRx = RegExp(r'^LIVEMOBILEENABLE = yes\s*$', multiLine: true, caseSensitive: false);
final _portRx = RegExp(r'^LIVEMOBILEPORT = (\d+)', multiLine: true, caseSensitive: false);
final _pageRx = RegExp(r'^page\d+$', caseSensitive: false);

/// Whether the remote is switched on, and how to reach it.
/// Port of `Get-Setup` in `sx_remote.ps1`.
class RemoteConfig {
  RemoteConfig._(this.appOn, this.paramFound, this.allowed, this.password, this.pagesOff, this.port, this.info);

  /// Reads live.ini and param.ini. [paramPath] defaults to [paramIniPath].
  factory RemoteConfig.read(ShowEnv env, {String? paramPath}) {
    final info = LiveInfo.read(env);
    final off = [
      for (final (name, keys) in info.sections)
        if (_pageRx.hasMatch(name) && !psEq(keys['live_mobile'] ?? '', 'yes')) keys['name'] ?? '',
    ];
    final pp = paramPath ?? paramIniPath(env);
    final found = File(pp).existsSync();
    var on = false, port = 7348;
    if (found) {
      final t = _Text(pp).text;
      on = _enabledRx.hasMatch(t);
      final m = _portRx.firstMatch(t);
      if (m != null) port = int.parse(m[1]!);
    }
    return RemoteConfig._(on, found, psEq(info.live['allow_live_mobile'] ?? '', 'yes'), info.live['live_mobile_password'] ?? '', off, port, info);
  }

  /// param.ini says External App is on.
  final bool appOn;
  final bool paramFound;

  /// live.ini allows external control.
  final bool allowed;
  final String password;

  /// Names of pages the remote can't reach.
  final List<String> pagesOff;
  final int port;

  /// live.ini as read, for the buttons and pages.
  final LiveInfo info;

  bool get ready => appOn && allowed && password.isNotEmpty && pagesOff.isEmpty;

  RemoteSetup toWire() => RemoteSetup(appOn: appOn, allowed: allowed, password: password.isNotEmpty, pagesOff: pagesOff);
}

/// Switches the remote on in the show. ShowXpress must be closed, and picks
/// it up the next time it opens. Returns the report.
///
/// live.ini is written first and param.ini last. If param.ini can't be
/// written, live.ini is put back as it was (the old tool left it changed).
///
/// Port of `sx_remote.ps1 -Action Enable`.
String remoteEnable(ShowEnv env, {String? paramPath, Random? random}) {
  if (env.sxRunning()) throw ToolError('ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again.');
  final setup = RemoteConfig.read(env, paramPath: paramPath);
  final pp = paramPath ?? paramIniPath(env);
  if (!File(pp).existsSync()) {
    throw ToolError(
      'ShowXpress settings file not found ($pp). Turn it on in ShowXpress: Preferences > Network > External App, then Live > Live settings > External control. NOTHING was changed.',
    );
  }
  final out = <String>[];
  final pr = _Text(pp);
  var pt = pr.text;
  if (!_enabledRx.hasMatch(pt)) {
    if (RegExp(r'^LIVEMOBILEENABLE = .*$', multiLine: true, caseSensitive: false).hasMatch(pt)) {
      // [regex]::Replace is case sensitive, unlike -match
      pt = pt.replaceAll(RegExp(r'^LIVEMOBILEENABLE = [^\r\n]*', multiLine: true), 'LIVEMOBILEENABLE = yes');
    } else if (RegExp(r'^\[Network\]', multiLine: true, caseSensitive: false).hasMatch(pt)) {
      pt = pt.replaceFirst(RegExp(r'^\[Network\][ \t]*(?=\r?$)', multiLine: true), '[Network]${pr.nl}LIVEMOBILEENABLE = yes');
    } else {
      pt = '${pt.replaceFirst(RegExp(r'[\r\n]+$'), '')}${pr.nl}[Network]${pr.nl}LIVEMOBILEENABLE = yes${pr.nl}';
    }
    out.add('  ShowXpress settings: External App turned on');
  }
  final ini = setup.info.ini;
  if (!setup.allowed) {
    ini.setKey('live', 'allow_live_mobile', 'yes');
    out.add('  Live: external control turned on');
  }
  if (setup.password.isEmpty) {
    const letters = 'abcdefghjkmnpqrstuvwxyz23456789';
    final rnd = random ?? Random.secure();
    final pw = String.fromCharCodes([for (var i = 0; i < 10; i++) letters.codeUnitAt(rnd.nextInt(letters.length))]);
    ini.setKey('live', 'live_mobile_password', pw, after: const ['allow_live_mobile']);
    out.add('  Live: password set (SX Studio reads it from the show)');
  }
  for (final (name, keys) in setup.info.sections) {
    if (_pageRx.hasMatch(name) && !psEq(keys['live_mobile'] ?? '', 'yes')) {
      ini.setKey(name, 'live_mobile', 'yes', after: const ['name', 'swap', 'nb_buttons']);
      out.add('  Page ${keys['name'] ?? ''}: can be reached');
    }
  }
  if (out.isEmpty) return '  The remote was already on - nothing to change.';
  final liveBefore = File(ini.path).readAsBytesSync();
  ini.save();
  // PowerShell's -ne ignores case, so a change of case alone is not written
  if (pt.toLowerCase() != pr.text.toLowerCase()) {
    try {
      writeTextSafely(pp, pt, bom: pr.bom);
    } catch (_) {
      writeBytesSafely(ini.path, liveBefore);
      rethrow;
    }
  }
  return ['  ShowXpress remote control turned on (works from the next time ShowXpress opens):', ...out].join('\n');
}
