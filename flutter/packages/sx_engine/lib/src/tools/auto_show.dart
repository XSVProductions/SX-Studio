import 'dart:convert';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import '../sx/remote_setup.dart';

// AUTO SHOW settings: the looks the Auto Show plays, each a few button titles
// and a number of bars, plus the BPM and how to play them. Kept in
// `<show>/auto_show.json`, which only SX Studio reads.
//
// Port of `ConvertTo-AutoCfg`, `Read-AutoCfg`, `-Action AutoGet` and
// `-Action AutoSave` in `sx_remote.ps1`.

/// `"$x"` in PowerShell for a value from ConvertFrom-Json.
String _psStr(Object? v) => switch (v) {
  null => '',
  true => 'True',
  false => 'False',
  final double d when d == d.truncateToDouble() && d.abs() < 1e15 => '${d.toInt()}',
  final List<Object?> l => l.map(_psStr).join(' '),
  _ => '$v',
};

/// `[bool]$x` in PowerShell for a value from ConvertFrom-Json.
bool _psBool(Object? v) => switch (v) {
  null => false,
  final bool b => b,
  final num n => n != 0,
  final String s => s.isNotEmpty,
  final List<Object?> l => l.length > 1 || (l.length == 1 && _psBool(l.first)),
  _ => true,
};

/// `[double]$x`, which throws on text that isn't a number.
double _psDouble(Object? v) => switch (v) {
  final num n => n.toDouble(),
  final bool b => b ? 1 : 0,
  final String s when double.tryParse(s.trim()) != null => double.parse(s.trim()),
  _ => throw const FormatException(),
};

/// `@($x)`: a JSON value as a list.
List<Object?> _items(Object? v) => v is List ? v : [v];

/// Takes out control characters, `|` and `"`, trims, and cuts to [max]. Port of `Get-Clean`.
String _clean(String s, int max) {
  s = s.replaceAll(RegExp(r'[\x00-\x1f|"]'), '').trim();
  return s.length > max ? s.substring(0, max) : s;
}

final _idRx = RegExp(r'^[0-9a-f]{8}\n?$', caseSensitive: false);

/// A new look id, 8 hex digits. Port of `New-Id`.
String newLookId(Random rnd) => List.generate(8, (_) => '0123456789abcdef'[rnd.nextInt(16)]).join();

/// Checks and tidies Auto Show settings from the screen or the file.
/// Port of `ConvertTo-AutoCfg`.
///
/// The BPM ends up a whole number: the old tool clamps it with
/// `[math]::Max(40, [math]::Min(220, $bpm))`, and PowerShell picks the
/// integer overload because 40 and 220 are integers. Kept as found.
AutoConfig cleanAutoConfig(Json j, Random rnd) {
  var bpm = 124.0;
  try {
    if (j['bpm'] != null) bpm = psRound(_psDouble(j['bpm']) * 10) / 10;
  } on FormatException {
    // keeps 124, like the old try/catch
  }
  final whole = max(40, min(220, psRound(bpm)));
  final looks = <AutoLook>[];
  final ids = <String>{};
  for (final raw in _items(j['looks'])) {
    if (!_psBool(raw) || looks.length >= 60) continue;
    final l = raw is Map ? raw.cast<String, Object?>() : const <String, Object?>{};
    final ts = <String>[];
    for (final t in _items(l['titles'])) {
      final c = _clean(_psStr(t), 80);
      if (c.isNotEmpty && !ts.contains(c) && ts.length < 24) ts.add(c);
    }
    var bars = 16;
    try {
      if (l['bars'] != null) bars = psInt(l['bars']);
    } on FormatException {
      // keeps 16
    }
    bars = max(1, min(256, bars));
    var id = _psStr(l['id']);
    if (!_idRx.hasMatch(id) || ids.contains(id.toLowerCase())) id = newLookId(rnd);
    ids.add(id.toLowerCase());
    var name = _clean(_psStr(l['name']), 40);
    if (name.isEmpty) name = 'Look ${looks.length + 1}';
    looks.add(AutoLook(id: id, name: name, bars: bars, on: l['on'] == null || _psBool(l['on']), titles: ts));
  }
  return AutoConfig(
    bpm: whole.toDouble(),
    order: psEq(_psStr(j['order']), 'shuffle') ? 'shuffle' : 'order',
    stop: psEq(_psStr(j['stop']), 'off') ? 'off' : 'keep',
    clean: _psBool(j['clean']),
    looks: looks,
  );
}

/// The settings as written to auto_show.json. The BPM is a whole number
/// in the file (see [cleanAutoConfig]) but can be a fraction while playing.
Json autoConfigJson(AutoConfig c) => {...c.toJson(), 'bpm': c.bpm == c.bpm.roundToDouble() ? c.bpm.round() : c.bpm};

/// The show's Auto Show settings. A missing or unreadable file reads as no
/// looks. Port of `Read-AutoCfg`.
AutoConfig readAutoConfig(ShowEnv env, {Random? random}) {
  Object? j;
  final f = env.file('auto_show.json');
  if (f.existsSync()) {
    try {
      j = jsonDecode(readText(f.path));
    } on FormatException {
      j = null;
    }
  }
  return cleanAutoConfig(j is Map ? j.cast<String, Object?>() : const {'looks': <Object?>[]}, random ?? Random());
}

/// What the Auto Show screen loads, without `player` and `status`, which
/// the engine adds. Writes nothing. Port of `sx_remote.ps1 -Action AutoGet`.
AutoInfo autoGet(ShowEnv env, {String? paramPath, Random? random}) {
  final setup = RemoteConfig.read(env, paramPath: paramPath);
  final vis = <int, bool>{}, swp = <int, bool>{};
  final pageRx = RegExp(r'^page(\d+)$', caseSensitive: false);
  for (final (name, keys) in setup.info.sections) {
    final m = pageRx.firstMatch(name);
    if (m == null) continue;
    final n = int.parse(m[1]!);
    vis[n] = psEq(keys['live_mobile'] ?? '', 'yes');
    swp[n] = psEq(keys['swap'] ?? '', 'yes');
  }
  final seen = <String>{};
  final buttons = [
    for (final b in psSorted<LiveButton>(setup.info.buttons, [(b) => b.page, (b) => b.btn]))
      if (b.title.isNotEmpty)
        AutoButton(title: b.title, page: b.pageName, dup: !seen.add(b.title.toLowerCase()), reach: vis[b.page] ?? false, swap: swp[b.page] ?? false),
  ];
  return AutoInfo(
    show: p.basename(env.root),
    config: readAutoConfig(env, random: random),
    buttons: buttons,
    ready: setup.ready,
    open: env.sxRunning(),
    setup: setup.toWire(),
  );
}

/// Checks and saves the Auto Show settings. Returns the report (with the
/// saved settings as one line of JSON at the end, like the old tool) and the
/// settings as saved. Port of `sx_remote.ps1 -Action AutoSave`.
({String report, AutoConfig config}) autoSave(ShowEnv env, Json? config, {Random? random}) {
  if (config == null) throw ToolError('No settings were sent. NOTHING was changed.');
  final cfg = cleanAutoConfig(config, random ?? Random());
  final json = autoConfigJson(cfg);
  writeTextSafely(env.path('auto_show.json'), const JsonEncoder.withIndent('  ').convert(json), bom: false);
  return (report: '  Auto Show saved: ${cfg.looks.length} look(s), ${json['bpm']} BPM\n${jsonEncode(json)}', config: cfg);
}
