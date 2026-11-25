import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../show/show_env.dart';
import '../show/text_files.dart';

// SETTINGS: `settings.json` in the settings folder, next to `phones.json`.
// The tab layout is shared by the laptop, phones and tablets. The file keeps
// the old app's format, so old and new can share it.
//
// Port of the SETTINGS block and the `/api/settings/set` route in
// `df_aim_gui.ps1`.

/// `"$v"` in PowerShell, for a value read from JSON.
String _psStr(Object? v) => switch (v) {
  null => '',
  String s => s,
  bool b => b ? 'True' : 'False',
  int i => '$i',
  double d when d == d.truncateToDouble() && d.abs() < 1e15 => '${d.toInt()}',
  double d => '$d',
  List<Object?> l => l.map(_psStr).join(' '),
  _ => '@{}',
};

/// `[bool]$v` in PowerShell: '' / 0 / null / an empty list are false, and so
/// is a one-item list whose item is false. Any other text is true, even "false".
bool _psBool(Object? v) => switch (v) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  List<Object?> l => l.length > 1 || (l.length == 1 && _psBool(l.single)),
  _ => true,
};

/// `@($v)`: a list stays a list, null is empty, anything else is one item.
List<Object?> _psList(Object? v) => switch (v) {
  null => const [],
  List<Object?> l => l,
  _ => [v],
};

/// `@(...) | Select-Object -Unique -First n`. `-First` cuts before `-Unique`,
/// and `-Unique` is case sensitive.
List<String> _uniqueFirst(Iterable<String> items, [int? first]) {
  final seen = <String>{};
  return [
    for (final s in first == null ? items : items.take(first))
      if (seen.add(s)) s,
  ];
}

/// A property of a JSON object read the PowerShell way: the name ignores case.
Object? _prop(Object? obj, String name) {
  if (obj is! Map) return null;
  if (obj.containsKey(name)) return obj[name];
  for (final e in obj.entries) {
    if ('${e.key}'.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

bool _isTab(String id) => settingsTabIds.any((t) => t.toLowerCase() == id.toLowerCase());

/// .NET's `\w`: letters, marks, digits and connector punctuation.
final _secRx = RegExp(r'^[\p{L}\p{Mn}\p{Nd}\p{Pc} .\-]{1,60}$', unicode: true);
final _pgRx = RegExp(r'^(\d{1,3}|x\d{1,3})$', caseSensitive: false);
final _xbRx = RegExp(r'^x\d{1,3}_b\d{1,3}$', caseSensitive: false);
final _fileRx = RegExp(r'^[^\\/:*?"<>|\x00-\x1f]{1,120}\.(scex|gpj)$', caseSensitive: false);
final _extRx = RegExp(r'\.(scex|gpj)$', caseSensitive: false);
final _colorRx = RegExp(r'^\d{1,8}$');
final _strobeRx = RegExp(r'^\s*strobes?\s*$', caseSensitive: false);

/// Tab names the user typed, cleaned. Port of `Get-TabNames`.
Map<String, String> cleanTabNames(Object? v) {
  final out = <String, String>{};
  if (v is! Map) return out;
  for (final e in v.entries) {
    final id = '${e.key}';
    final n = _psStr(e.value).replaceAll(RegExp(r'[\x00-\x1f<>]'), '').trim();
    if (!_isTab(id) || n.isEmpty || n.length > 24) continue;
    // [ordered]@{} keys ignore case: a later spelling replaces an earlier one in its place
    final had = out.keys.firstWhere((k) => k.toLowerCase() == id.toLowerCase(), orElse: () => '');
    if (had.isEmpty) {
      out[id] = n;
    } else {
      out[had] = n;
    }
  }
  return out;
}

/// Port of `Get-CleanText`.
String _cleanText(Object? v, int max) {
  var t = _psStr(v).replaceAll(RegExp(r'[\x00-\x1f<>|]'), '').trim();
  if (t.length > max) t = t.substring(0, max).trim();
  return t;
}

/// `Group-Object { $_.id } | % { $_.Group[0] }`: the first of each id, ids
/// compared ignoring case.
List<Json> _firstPerId(Iterable<Json> items) {
  final seen = <String>{};
  return [
    for (final i in items)
      if (seen.add('${i['id']}'.toLowerCase())) i,
  ];
}

/// The SX Player's layout, cleaned. Port of `Get-PlayerLayout`.
Json cleanPlayerLayout(Object? v) {
  List<String> pageList(Object? x) => _uniqueFirst(_psList(x).map(_psStr).where(_pgRx.hasMatch), 140);
  final order = <String, Object?>{};
  final o = _prop(v, 'order');
  if (v != null && _psBool(o) && o is Map) {
    for (final e in o.entries) {
      final k = '${e.key}';
      if (_pgRx.hasMatch(k)) order[k] = _uniqueFirst(_psList(e.value).map(_psStr).where(_secRx.hasMatch), 300);
    }
  }
  final custom = <Json>[];
  for (final c in _psList(_prop(v, 'custom')).take(40)) {
    final id = _psStr(_prop(c, 'id'));
    if (!_psBool(c) || !RegExp(r'^x\d{1,3}$', caseSensitive: false).hasMatch(id)) continue;
    var name = _cleanText(_prop(c, 'name'), 40);
    if (name.isEmpty) name = 'NEW PAGE';
    final buttons = <Json>[];
    for (final b in _psList(_prop(c, 'buttons')).take(64)) {
      final bid = _psStr(_prop(b, 'id')), file = _psStr(_prop(b, 'file'));
      if (!_psBool(b) || !_xbRx.hasMatch(bid) || !bid.startsWith('${id}_') || !_fileRx.hasMatch(file)) continue;
      final fader = int.tryParse(_psStr(_prop(b, 'fader')).trim()) ?? 0;
      var beats = double.tryParse(_psStr(_prop(b, 'beats')).trim()) ?? 0;
      if (beats.isNaN || beats <= 0.01 || beats > 64) beats = 1.0;
      final cs = _psStr(_prop(b, 'color'));
      final color = _colorRx.hasMatch(cs) && int.parse(cs) <= 0xFFFFFF ? int.parse(cs) : -1;
      var title = _cleanText(_prop(b, 'title'), 40);
      if (title.isEmpty) title = file.replaceAll(_extRx, '');
      buttons.add({
        'id': bid,
        'title': title,
        'file': file,
        'fader': fader.clamp(0, 15),
        'bpm': _psBool(_prop(b, 'bpm')),
        'flash': _psBool(_prop(b, 'flash')),
        'beats': beats,
        'color': color,
      });
    }
    custom.add({'id': id, 'name': name, 'swap': _psBool(_prop(c, 'swap')), 'buttons': _firstPerId(buttons)});
  }
  return {
    'pages': pageList(_prop(v, 'pages')),
    'order': order,
    'hidden': pageList(_prop(v, 'hidden')),
    'collapsed': pageList(_prop(v, 'collapsed')),
    'custom': _firstPerId(custom),
  };
}

/// The tab order before v1.9.7. A saved order that still follows it was never
/// changed by the user, so it gives way to the new default.
const _oldDefault = ['rt', 'rig', 'aim', 'skip', 'color', 'apc', 'speed', 'health', 'pre', 'auto', 'lab', 'scene', 'move', 'look'];

/// Reads and writes `settings.json`. One per engine, shared with the other
/// areas through `Engine.find<SettingsStore>()`.
class SettingsStore {
  SettingsStore(this.dir);

  /// The settings folder.
  final String dir;

  String get file => p.join(dir, 'settings.json');

  /// The settings, cleaned, as an ordered JSON object in the file's key
  /// order. Port of `Get-Settings`.
  Json readRaw() {
    final s = <String, Object?>{
      'tabOrder': settingsTabIds,
      'tabHidden': const <String>[],
      'tabNames': null,
      'playerLayout': null,
      'reopen': true,
      'autoUpd': true,
      'driveFolder': '',
    };
    if (File(file).existsSync()) {
      try {
        final j = jsonDecode(readText(file));
        for (final k in [...s.keys]) {
          final v = _prop(j, k);
          if (v != null) s[k] = v;
        }
      } on FormatException {
        // a broken file reads as the defaults, like the old app
      }
    }
    var order = _uniqueFirst(_psList(s['tabOrder']).map(_psStr).where(_isTab));
    var k = 0, sub = true;
    for (final t in order) {
      while (k < _oldDefault.length && _oldDefault[k] != t.toLowerCase()) {
        k++;
      }
      if (k >= _oldDefault.length) {
        sub = false;
        break;
      }
      k++;
    }
    if (sub) order = [];
    s['tabOrder'] = [...order, ...settingsTabIds.where((t) => !order.any((o) => o.toLowerCase() == t))];
    s['tabHidden'] = _uniqueFirst(_psList(s['tabHidden']).map(_psStr).where(_isTab));
    s['reopen'] = _psBool(s['reopen']);
    s['autoUpd'] = _psBool(s['autoUpd']);
    s['driveFolder'] = _psStr(s['driveFolder']);
    s['tabNames'] = cleanTabNames(s['tabNames'])
      // The Skip Flash tab is called Strobe now, so a name of Strobe or Strobes the user gave it isn't needed any more.
      ..removeWhere((id, name) => id.toLowerCase() == 'skip' && _strobeRx.hasMatch(name));
    s['playerLayout'] = cleanPlayerLayout(s['playerLayout']);
    return s;
  }

  /// The settings, typed.
  SxSettings read() => SxSettings.fromJson(readRaw());

  /// Port of `Save-Settings`. Compact JSON, UTF-8 without a byte order mark.
  void save(Json raw) {
    Directory(dir).createSync(recursive: true);
    writeTextSafely(file, jsonEncode(raw), bom: false);
  }

  /// Applies a `/api/settings/set` body and saves. A phone may change the
  /// tabs and the player layout only. Answers the settings as saved.
  SxSettings apply(Json body, {required bool fromPhone}) {
    final st = readRaw();
    if (_prop(body, 'tabOrder') != null) st['tabOrder'] = _psList(_prop(body, 'tabOrder')).map(_psStr).toList();
    if (_prop(body, 'tabHidden') != null) st['tabHidden'] = _psList(_prop(body, 'tabHidden')).map(_psStr).toList();
    if (_prop(body, 'tabNames') != null) st['tabNames'] = cleanTabNames(_prop(body, 'tabNames'));
    if (_prop(body, 'playerLayout') != null) st['playerLayout'] = cleanPlayerLayout(_prop(body, 'playerLayout'));
    if (!fromPhone) {
      if (_prop(body, 'reopen') != null) st['reopen'] = _psBool(_prop(body, 'reopen'));
      if (_prop(body, 'autoUpd') != null) st['autoUpd'] = _psBool(_prop(body, 'autoUpd'));
      if (_prop(body, 'driveFolder') != null) {
        var d = _psStr(_prop(body, 'driveFolder')).trim();
        d = _trimChars(d, '"', start: true);
        d = _trimChars(d, r'\/', start: false);
        if (d.isNotEmpty && !Directory(d).existsSync()) throw ToolError("That folder doesn't exist: $d");
        st['driveFolder'] = d;
      }
    }
    save(st);
    return read();
  }

  /// Sets whether ShowXpress opens again after the save queue, as
  /// `/api/queue/reopen` does.
  void setReopen(bool on) => save(readRaw()..['reopen'] = on);
}

/// `.Trim('"')` (both ends) when [start], `.TrimEnd(chars)` otherwise.
String _trimChars(String s, String chars, {required bool start}) {
  var a = 0, b = s.length;
  if (start) {
    while (a < b && chars.contains(s[a])) {
      a++;
    }
  }
  while (b > a && chars.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}
