import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../player/player_links.dart';
import '../ps_compat.dart';
import '../server/api.dart';
import '../server/engine.dart';
import '../server/ps_body.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import '../sx/auto_player.dart';
import '../tools/apc.dart';
import '../tools/auto_show.dart';
import '../tools/speed.dart';
import 'open_on_computer.dart';
import 'settings_store.dart';

// EXPORT / IMPORT SETTINGS: one JSON file, `{ app: 'SX Studio', kind:
// 'settings', format: 1, version, saved, settings, apc40, autoShow, apcMini,
// speedFaders, phone, device }`. Import checks every part the way its own tab
// does and backs up what it replaces first.
//
// Port of the EXPORT / IMPORT SETTINGS block in `df_aim_gui.ps1`
// (`Get-AutoConfig` through `Import-Config`).

/// The APC40 tab's part of the settings file. The APC40 tab owns
/// `apc40.json` and its checks, so the export and import ask it.
class Apc40Part {
  const Apc40Part({required this.readText, required this.save});

  /// The text of `apc40.json`, or null when there is none.
  final String? Function() readText;

  /// Saves an imported layout the way the APC40 tab's Save does (`apc40.ps1
  /// -Action Save`) and has the bridge read it again. False when the layout
  /// was refused.
  final bool Function(Json raw) save;
}

/// Where Export settings tries to save, in order. Tests put their own in with
/// `Engine.provide<ExportFolders>`.
class ExportFolders {
  const ExportFolders(this.dirs);

  final List<String> dirs;
}

/// Downloads, then SX Studio's own `exports` folder. A Mac may not let SX
/// Studio write to Downloads (Privacy & Security). Port of `Get-DownloadsDir`.
List<String> downloadFolders(String settingsFolder) {
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  final c = [if (Platform.isWindows) ?_windowsDownloads(), if (home.isNotEmpty) p.join(home, 'Downloads')];
  return [...c.where((d) => Directory(d).existsSync()), p.join(settingsFolder, 'exports')];
}

/// The Downloads folder Explorer shows, which the user may have moved. The
/// old app asked the shell for `shell:Downloads`; the registry holds the same.
String? _windowsDownloads() {
  try {
    final r = Process.runSync('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
      '/v',
      '{374DE290-123F-4565-9164-39C4925E467B}',
    ]);
    final m = RegExp(r'REG_SZ\s+(.+?)\s*$', multiLine: true).firstMatch('${r.stdout}');
    return m?[1];
  } on ProcessException {
    return null;
  }
}

/// A property of a JSON object, read the PowerShell way: the name ignores
/// case, and anything that is not an object has none.
Object? _prop(Object? obj, String name) {
  if (obj is! Map) return null;
  if (obj.containsKey(name)) return obj[name];
  for (final e in obj.entries) {
    if (psEq('${e.key}', name)) return e.value;
  }
  return null;
}

final _secRx = RegExp(r'^page\d+_button\d+$', caseSensitive: false);
final _digits = RegExp(r'^\d+$');
final _note = RegExp(r'^-?\d+$');

/// `[int]` of text that already passed a digits check. Too big to matter is 1000000.
int _int(String s) => int.tryParse(s) ?? 1000000;

SettingsStore _store(Engine e) => e.find<SettingsStore>() ?? SettingsStore(e.settingsFolder);

/// The show's Auto Show settings, or null when the show can't be read.
/// Port of `Get-AutoConfig`.
Json? _autoConfig(Engine e) {
  try {
    return autoConfigJson(autoGet(e.show()).config);
  } on Exception {
    return null;
  }
}

/// The APC mini pads (note and colours) as the APC mini tab sets them, or
/// null when the show can't be read. Port of `Get-ApcMiniExport`.
Json? _apcMiniExport(Engine e) {
  try {
    final a = apcPreview(e.show());
    return {
      'pads': [
        for (final p in a.pads)
          if (p.type == 0) {'sec': p.sec, 'title': p.title, 'note': p.note, 'on': p.on, 'off': p.off},
      ],
    };
  } on Exception {
    return null;
  }
}

/// Which speed fader each button follows, or null when the show can't be
/// read. Port of `Get-SpeedExport`.
Json? _speedExport(Engine e) {
  try {
    return {
      'buttons': [
        for (final b in speedPreview(e.show()).buttons) {'sec': b.sec, 'title': b.title, 'fader': b.fader},
      ],
    };
  } on Exception {
    return null;
  }
}

/// Everything the settings file holds except this computer's own choices,
/// in the old key order. Port of `Get-ConfigExport`.
Json configExport(Engine e, Apc40Part apc40, {DateTime? now}) {
  Object? ap;
  final text = apc40.readText();
  if (text != null) {
    try {
      ap = jsonDecode(text);
    } on FormatException {
      ap = null;
    }
  }
  return {
    'app': 'SX Studio',
    'kind': 'settings',
    'format': 1,
    'version': e.config.appVersion,
    'saved': sortableTime(now ?? DateTime.now()),
    'settings': _store(e).readRaw(),
    'apc40': ap,
    'autoShow': _autoConfig(e),
    'apcMini': _apcMiniExport(e),
    'speedFaders': _speedExport(e),
    'phone': {'on': e.phones.on},
  };
}

/// This computer's own choices the page sends along: `sxh_*` text only,
/// never the phone key, at most 50 looked at. Port of `Get-DeviceKeys`.
Json deviceKeys(Object? v) {
  final o = <String, Object?>{};
  if (v is! Map) return o;
  for (final MapEntry(:key, :value) in v.entries.take(50)) {
    final k = '$key';
    if (deviceKeyPattern.hasMatch(k) && !psEq(k, phoneKeyName) && value is String && value.length <= 20000) o[k] = value;
  }
  return o;
}

/// The settings file's text: indented JSON, as `ConvertTo-Json` wrote it.
String _fileText(Json d) => const JsonEncoder.withIndent('  ').convert(d);

/// Saves the settings file in the first of [folders] that takes it, named
/// `SX Studio settings <date>.json`, numbered `(2)`, `(3)`... when the name
/// is taken. Answers `{ok, path, name, folder}` or `{ok:false, error}`.
/// Port of `Save-ConfigExport`.
Json saveConfigExport(Engine e, Apc40Part apc40, Object? device, {required List<String> folders, DateTime? now}) {
  final at = now ?? DateTime.now();
  final d = configExport(e, apc40, now: at)..['device'] = deviceKeys(device);
  final js = _fileText(d);
  final base = 'SX Studio settings ${sortableTime(at).substring(0, 10)}';
  var err = '';
  for (final dir in folders) {
    try {
      Directory(dir).createSync(recursive: true);
      var f = p.join(dir, '$base.json');
      for (var k = 2; FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound; k++) {
        f = p.join(dir, '$base ($k).json');
      }
      writeTextSafely(f, js, bom: false);
      e.find<LastExport>()?.path = f;
      return ConfigExportResult(path: f, name: p.basename(f), folder: dir).toJson();
    } on FileSystemException catch (x) {
      err = x.osError?.message ?? x.message;
    }
  }
  return {'ok': false, 'error': "The settings couldn't be saved: $err"};
}

/// Where the backups of what an import replaced go: the backups folder in the
/// settings folder, next to the Google Drive import backups. Port of
/// `Get-BackupDir`.
String configBackupDir(Engine e) => p.join(e.settingsFolder, 'backups');

/// Imports a settings file. Backs up what is there now (newest 5 kept), then
/// applies each part through its own tab's checks and keeps any part that
/// can't be read. Answers `{ok, done, warn, settings, backup}` or
/// `{ok:false, error}`. Port of `Import-Config`.
Future<Json> importConfig(Engine e, Apc40Part apc40, Object? d, {DateTime? now}) async {
  if (!psTruthy(d) || !psEq(bodyText(_prop(d, 'app')), 'SX Studio') || !psEq(bodyText(_prop(d, 'kind')), 'settings')) {
    return {'ok': false, 'error': "That file isn't an SX Studio settings file. Nothing was changed."};
  }
  final format = bodyText(_prop(d, 'format'));
  if (!_digits.hasMatch(format) || _int(format) > 1) {
    return {'ok': false, 'error': 'That file is from a newer SX Studio - update SX Studio first. Nothing was changed.'};
  }

  // back up what is there now (newest 5 kept)
  final at = now ?? DateTime.now();
  final bd = configBackupDir(e);
  final stamp = sortableTime(at).replaceFirst('T', ' ').replaceAll(':', '');
  final bk = p.join(bd, 'settings before import $stamp');
  try {
    Directory(bk).createSync(recursive: true);
    writeTextSafely(p.join(bk, 'SX Studio settings.json'), _fileText(configExport(e, apc40, now: at)), bom: false);
    final old = psSorted<Directory>(Directory(bd).listSync().whereType<Directory>().where((x) => psLike(p.basename(x.path), 'settings before import *')), [
      (x) => p.basename(x.path),
    ]).reversed.skip(5);
    for (final x in old) {
      try {
        x.deleteSync(recursive: true);
      } on FileSystemException {
        // -ErrorAction SilentlyContinue
      }
    }
  } on FileSystemException catch (x) {
    return {'ok': false, 'error': "Couldn't back up the settings you have now, so nothing was changed: ${x.osError?.message ?? x.message}"};
  }

  final done = <String>[], warn = <String>[];
  final store = _store(e);

  final n = _prop(d, 'settings');
  if (psTruthy(n) && n is! Map) {
    warn.add("The tabs and SX Player pages in the file couldn't be read, so they were kept as they were.");
  } else if (psTruthy(n)) {
    final st = store.readRaw();
    if (_prop(n, 'tabOrder') != null) st['tabOrder'] = [for (final t in bodyItems(_prop(n, 'tabOrder'))) bodyText(t)];
    if (_prop(n, 'tabHidden') != null) st['tabHidden'] = [for (final t in bodyItems(_prop(n, 'tabHidden'))) bodyText(t)];
    if (_prop(n, 'tabNames') != null) st['tabNames'] = cleanTabNames(_prop(n, 'tabNames'));
    if (_prop(n, 'playerLayout') != null) st['playerLayout'] = cleanPlayerLayout(_prop(n, 'playerLayout'));
    if (_prop(n, 'reopen') != null) {
      st['reopen'] = psTruthy(_prop(n, 'reopen'));
      e.queue.reopen = psTruthy(_prop(n, 'reopen'));
    }
    if (_prop(n, 'autoUpd') != null) st['autoUpd'] = psTruthy(_prop(n, 'autoUpd'));
    if (_prop(n, 'driveFolder') != null) {
      final g = bodyText(_prop(n, 'driveFolder')).trim();
      if (g.isEmpty || Directory(g).existsSync()) {
        st['driveFolder'] = g;
      } else {
        warn.add("The Google Drive folder in the file isn't on this computer, so that one setting was kept as it was.");
      }
    }
    store.save(st);
    e.find<LabPlayerHooks>()?.syncExtras();
    done.add('the tabs and the SX Player pages');
  }

  final a40 = _prop(d, 'apc40');
  if (psTruthy(a40)) {
    // `@(if ($d.apc40) { $d.apc40.pages })`: no pages is one null page
    final pages = _prop(a40, 'pages') == null ? const [null] : bodyItems(_prop(a40, 'pages'));
    final readable = pages.isNotEmpty && pages.every((x) => x is Map && _prop(x, 'pads') is Map);
    if (readable && a40 is Map && apc40.save(a40.cast<String, Object?>())) {
      done.add('the APC40 pads and faders');
    } else {
      warn.add("The APC40 pages in the file couldn't be read, so they were kept as they were.");
    }
  }

  final au = _prop(d, 'autoShow');
  if (psTruthy(au) && !(au is Map && _prop(au, 'looks') != null)) {
    warn.add("The Auto Show in the file couldn't be read, so it was kept as it was.");
  } else if (au is Map) {
    try {
      autoSave(e.show(), au.cast<String, Object?>());
      e.find<AutoShow>()?.reload();
      done.add('the Auto Show');
    } on ToolError catch (x) {
      warn.add("The Auto Show couldn't be imported (${x.message}), so it was kept as it was.");
    } on FileSystemException catch (x) {
      warn.add("The Auto Show couldn't be imported (${x.message}), so it was kept as it was.");
    }
  }

  final sxOpen = e.sx.running;
  // Saves through the tab's own route: queued while ShowXpress is open.
  Future<void> toShow(String path, List<Json> items, String what) async {
    if (items.isEmpty) {
      done.add('$what (already the same)');
      return;
    }
    final route = e.api.find(path)!;
    final body = <String, Object?>{'changes': items};
    if (sxOpen) {
      e.queue.add(route, body);
      done.add('$what (saved as soon as ShowXpress is closed)');
      return;
    }
    final r = await runRoute(route, ApiRequest(body: body, query: const {}, fromPhone: false));
    if (r['ok'] != false) {
      done.add(what);
    } else {
      warn.add("$what couldn't be imported (${r['error']}), so they were kept as they were.");
    }
  }

  final mini = _prop(d, 'apcMini');
  if (psTruthy(mini) && psTruthy(_prop(mini, 'pads'))) {
    ApcPreview? cur;
    try {
      cur = apcPreview(e.show());
    } on Exception {
      cur = null;
    }
    if (cur == null) {
      warn.add("The show's APC mini pads couldn't be read, so they were kept as they were.");
    } else {
      final now = psMap<ApcPad>();
      for (final x in cur.pads) {
        now[x.sec] = x;
      }
      final ch = <Json>[];
      var miss = 0;
      for (final x in bodyItems(_prop(mini, 'pads')).take(300)) {
        final sec = bodyText(_prop(x, 'sec')), note = bodyText(_prop(x, 'note'));
        if (!psTruthy(x) || !_secRx.hasMatch(sec) || !_note.hasMatch(note)) continue;
        final nt = _int(note), c = now[sec], title = bodyText(_prop(x, 'title'));
        if (c == null || !psEq(c.title, title) || c.type != 0 || nt < -1 || nt > 63) {
          miss++;
          continue;
        }
        final o = <String, Object?>{'sec': sec, 'title': title, 'note': nt};
        final on = bodyText(_prop(x, 'on')), off = bodyText(_prop(x, 'off'));
        final colOk = _digits.hasMatch(on) && _digits.hasMatch(off) && _int(on) <= 127 && _int(off) <= 127;
        final colCh = colOk && nt >= 0 && (_int(on) != c.on || _int(off) != c.off);
        if (colCh) {
          o['on'] = _int(on);
          o['off'] = _int(off);
        }
        if (nt != c.note || colCh) ch.add(o);
      }
      await toShow('/api/apc/apply', ch, 'the APC mini pads');
      if (miss > 0) {
        warn.add(
          miss == 1
              ? "1 APC mini pad in the file isn't the same button in this show, so it was left out."
              : "$miss APC mini pads in the file aren't the same buttons in this show, so they were left out.",
        );
      }
    }
  }

  final sp = _prop(d, 'speedFaders');
  if (psTruthy(sp) && psTruthy(_prop(sp, 'buttons'))) {
    SpeedPreview? cur;
    try {
      cur = speedPreview(e.show());
    } on Exception {
      cur = null;
    }
    if (cur == null) {
      warn.add("The show's speed faders couldn't be read, so they were kept as they were.");
    } else {
      final now = psMap<SpeedButton>();
      for (final b in cur.buttons) {
        now[b.sec] = b;
      }
      final nf = cur.faders.length;
      final ch = <Json>[];
      var miss = 0;
      for (final x in bodyItems(_prop(sp, 'buttons')).take(2000)) {
        final sec = bodyText(_prop(x, 'sec')), fader = bodyText(_prop(x, 'fader'));
        if (!psTruthy(x) || !_secRx.hasMatch(sec) || !_digits.hasMatch(fader)) continue;
        final c = now[sec], title = bodyText(_prop(x, 'title'));
        if (c == null || !psEq(c.title, title) || _int(fader) >= (nf > 1 ? nf : 1)) {
          miss++;
          continue;
        }
        if (_int(fader) != c.fader) ch.add({'sec': sec, 'title': title, 'fader': _int(fader)});
      }
      await toShow('/api/speed/apply', ch, 'the speed faders');
      if (miss > 0) {
        warn.add(
          miss == 1
              ? "1 button in the file isn't in this show (or follows a fader it doesn't have), so its speed fader was left out."
              : "$miss buttons in the file aren't in this show (or follow a fader it doesn't have), so their speed faders were left out.",
        );
      }
    }
  }

  final ph = _prop(d, 'phone');
  if (psTruthy(ph) && _prop(ph, 'on') != null && psTruthy(_prop(ph, 'on')) != e.phones.on) {
    final on = psTruthy(_prop(ph, 'on'));
    e.phones.setOn(on);
    await e.setPhoneListener(on);
    done.add('phone access ${on ? 'on (phones still pair here with a code)' : 'off'}');
  }

  return {'ok': true, 'done': done, 'warn': warn, 'settings': store.read().toJson(), 'backup': bk};
}
