import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import 'show_env.dart';
import 'text_files.dart';

/// `Live/live.ini`, the file that holds ShowXpress's live pages and buttons.
///
/// Kept as a list of lines and edited in place, so everything SX Studio does
/// not touch (unknown keys, blank lines, order) is written back exactly as
/// found. The byte order mark and the line ending are kept too.
///
/// Port of the live.ini functions in `show_common.ps1`.
class LiveIni {
  LiveIni._(this.path, this.bom, this.nl, this.lines, this._text);

  factory LiveIni.read(ShowEnv env) {
    final path = env.path('Live/live.ini');
    if (!File(path).existsSync()) throw ToolError('Live/live.ini not found in the show. NOTHING was changed.');
    final b = File(path).readAsBytesSync();
    final bom = hasBom(b);
    final text = utf8.decode(bom ? Uint8List.sublistView(b, 3) : b, allowMalformed: true);
    return LiveIni._(path, bom, text.contains('\r\n') ? '\r\n' : '\n', text.split(RegExp(r'\r?\n')), text);
  }

  final String path;
  final bool bom;

  /// The file's line ending, `\r\n` or `\n`.
  final String nl;
  final List<String> lines;

  /// The text as read, to tell whether anything changed.
  final String _text;

  /// Writes the file if any line changed. Returns false when nothing did.
  bool save() {
    final text = lines.join(nl);
    if (text == _text) return false;
    writeTextSafely(path, text, bom: bom);
    return true;
  }

  /// Where `[name]` is: (header line, end line exclusive). Trailing blank
  /// lines are left out of the range. Null when the section is missing.
  (int, int)? findSection(String name) {
    final header = '[$name]';
    var start = -1, i = 0;
    for (; i < lines.length; i++) {
      if (start < 0) {
        if (psEq(lines[i], header)) start = i;
      } else if (lines[i].startsWith('[')) {
        break;
      }
    }
    if (start < 0) return null;
    var end = i;
    while (end > start + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return (start, end);
  }

  /// The `key = value` pairs of `[name]`. Keys ignore case.
  Map<String, String> keys(String name) {
    final r = psMap<String>();
    final se = findSection(name);
    if (se == null) return r;
    for (var i = se.$1 + 1; i < se.$2; i++) {
      final kv = _splitKey(lines[i]);
      if (kv != null) r[kv.$1] = kv.$2;
    }
    return r;
  }

  /// Sets `key = value` in `[name]`. A missing key is inserted after the last
  /// of [after] that exists, or at the end of the section. ShowXpress writes
  /// keys in a fixed order, and [after] keeps new keys in that order.
  void setKey(String name, String key, String value, {List<String> after = const []}) {
    final se = findSection(name);
    if (se == null) throw ToolError('Section [$name] not found in live.ini. NOTHING was changed.');
    bool isKey(String line, String k) => line.startsWith('$k = ') || psEq(line, '$k =');
    var at = -1;
    for (var i = se.$1 + 1; i < se.$2; i++) {
      if (isKey(lines[i], key)) {
        lines[i] = '$key = $value';
        return;
      }
      if (after.any((a) => isKey(lines[i], a))) at = i;
    }
    if (at < 0) at = se.$2 - 1;
    lines.insert(at + 1, '$key = $value');
  }

  /// Removes every key of `[name]` that matches [keyPattern]. Returns how many.
  int removeKeys(String name, String keyPattern) {
    final se = findSection(name);
    if (se == null) return 0;
    final rx = RegExp(keyPattern, caseSensitive: false);
    var n = 0;
    for (var i = se.$2 - 1; i > se.$1; i--) {
      final k = lines[i].indexOf(' =');
      if (k > 0 && rx.hasMatch(lines[i].substring(0, k))) {
        lines.removeAt(i);
        n++;
      }
    }
    return n;
  }
}

/// Splits `key = value`. The value keeps everything after the first space.
(String, String)? _splitKey(String line) {
  final k = line.indexOf(' =');
  if (k <= 0) return null;
  var v = line.substring(k + 2);
  if (v.startsWith(' ')) v = v.substring(1);
  return (line.substring(0, k), v);
}

/// One button on a ShowXpress live page.
class LiveButton {
  LiveButton({required this.sec, required this.page, required this.btn, required this.keys, required this.pageName});

  /// Section name, for example `page3_button1`.
  final String sec;
  final int page;
  final int btn;

  /// Every key of the section. Keys ignore case.
  final Map<String, String> keys;
  final String pageName;

  /// File the button plays (`name = ...`).
  String get name => keys['name'] ?? '';
  String get title => keys['title'] ?? '';
}

/// Pages, buttons and master faders read from live.ini.
///
/// Port of `Get-LiveInfo` in `show_common.ps1`.
class LiveInfo {
  LiveInfo._(this.ini, this.pages, this.buttons, this.faders, this.live, this.sections);

  factory LiveInfo.read(ShowEnv env, [LiveIni? ini]) {
    ini ??= LiveIni.read(env);
    final sections = <(String, Map<String, String>)>[];
    final header = RegExp(r'^\[(.+)\]\s*$');
    String? sec;
    var keys = psMap<String>();
    for (final l in ini.lines) {
      final m = header.firstMatch(l);
      if (m != null) {
        if (sec != null) sections.add((sec, keys));
        sec = m[1]!;
        keys = psMap<String>();
        continue;
      }
      if (sec != null) {
        final kv = _splitKey(l);
        if (kv != null) keys[kv.$1] = kv.$2;
      }
    }
    if (sec != null) sections.add((sec, keys));

    final pages = <int, String>{};
    final pending = <(String, int, int, Map<String, String>)>[];
    final pageRx = RegExp(r'^page(\d+)$', caseSensitive: false);
    final buttonRx = RegExp(r'^page(\d+)_button(\d+)$', caseSensitive: false);
    for (final (name, ky) in sections) {
      final pm = pageRx.firstMatch(name);
      if (pm != null) {
        pages[int.parse(pm[1]!)] = ky['name'] ?? '';
        continue;
      }
      final bm = buttonRx.firstMatch(name);
      if (bm != null) pending.add((name, int.parse(bm[1]!), int.parse(bm[2]!), ky));
    }
    final buttons = [
      for (final (name, pg, bn, ky) in pending)
        LiveButton(sec: name, page: pg, btn: bn, keys: ky, pageName: (pages[pg] ?? '').isNotEmpty ? pages[pg]! : 'Page $pg'),
    ];

    final live = ini.keys('live'), mf = ini.keys('master_faders');
    final count = RegExp(r'^\d+$').hasMatch(live['master_faders'] ?? '') ? int.parse(live['master_faders']!) : 0;
    final faders = [for (var k = 0; k < count; k++) MasterFader(k: k, caption: mf['caption_fader$k'] ?? '', type: mf['type_fader$k'] ?? '')];
    return LiveInfo._(ini, pages, buttons, faders, live, sections);
  }

  final LiveIni ini;

  /// Page number to page name.
  final Map<int, String> pages;
  final List<LiveButton> buttons;
  final List<MasterFader> faders;

  /// The keys of `[live]`.
  final Map<String, String> live;

  /// Every section in file order, with its keys.
  final List<(String, Map<String, String>)> sections;
}

/// The file a live button plays: a `.scex` in `scenes/`, or a `.gpj` in the
/// Generator projects (or `scenes/`). Null when it is not in the show.
///
/// Port of `Get-ScenePath`.
String? scenePath(ShowEnv env, String name) {
  if (name.isEmpty) return null;
  final candidates = name.toLowerCase().endsWith('.gpj') ? ['Editor/Generator/projects/$name', 'scenes/$name'] : ['scenes/$name'];
  for (final c in candidates) {
    if (File(env.path(c)).existsSync()) return env.path(c);
  }
  return null;
}
