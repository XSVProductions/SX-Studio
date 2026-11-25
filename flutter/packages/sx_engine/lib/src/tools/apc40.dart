import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';

// APC40 mk2 LAYOUT: up to 8 pages of 40 pads, each pad a ShowXpress button
// by title, and which ShowXpress master fader each APC40 fader moves. Kept
// in SX Studio's own `apc40.json` next to `settings.json`. No show file is
// ever written.
//
//   { "pages":[ { "name":"Dancefloor", "pads":{ "<0..39>":"<button title>" },
//                 "colors":{ "<0..39>":{ "on":<0..127>, "off":<0..127> } } } ],
//     "faders":{ "<1..9>":<master fader index> } }
//
// Port of the layout, colour, Info and Save parts of `apc40.ps1`. The bridge
// that plays the pads is in `lib/src/apc40/`.

/// SX Studio's APC40 layout file in its settings folder [settingsDir].
/// The old server's `Get-Apc40Lay`.
File apc40LayoutFile(String settingsDir) => File(p.join(settingsDir, 'apc40.json'));

/// The layout in [file], cleaned. The defaults when there is no file, or
/// when it can't be read (then [onError] gets the old status message).
///
/// Throws [ToolError] when a fader value is too big for a number, as the
/// old `[int]` cast did. Port of `Read-Layout` without `$from`.
Apc40Layout readApc40Layout(File file, {void Function(String error)? onError}) {
  Object? j;
  if (file.existsSync()) {
    try {
      j = psFromJson(readText(file.path));
    } on Object catch (e) {
      onError?.call("The APC40 layout file can't be read: ${e is FormatException ? e.message : e}");
    }
  }
  return _clean(j);
}

/// `Read-Layout` on an already parsed layout [raw]: up to 8 pages, pads 0 to
/// 39 with a title, colours 0 to 127 for pads that have a button, page names
/// without control characters and at most 30 long, faders 1 to 9. With no
/// pages, one empty page called Dancefloor. With no `faders` at all, faders
/// 1 to 4 move master faders 1 to 4. An empty `faders` means none.
Apc40Layout cleanApc40Layout(Json? raw) => _clean(raw);

/// Checks [raw] and writes it to [file] (the `Save` action), and returns the
/// layout as written. Throws [ToolError] `Nothing to save.` when [raw] has no
/// pages. Nothing is written when [raw] is refused.
Apc40Layout saveApc40Layout(File file, Json raw) {
  if (!psTruthy(raw) || !psTruthy(_member(raw, 'pages'))) throw ToolError('Nothing to save.');
  final lay = _clean(raw);
  try {
    file.parent.createSync(recursive: true);
    writeTextSafely(file.path, apc40LayoutJson(lay), bom: false);
  } on FileSystemException catch (e) {
    throw ToolError('${e.message}: ${e.path ?? file.path}');
  }
  return lay;
}

/// The layout file's text: `ConvertTo-LayoutJson | ConvertTo-Json -Depth 7`
/// as PowerShell 7 lays it out (keys in number order, no `colors` on a page
/// without any).
String apc40LayoutJson(Apc40Layout lay) => psJson(lay.toJson());

/// What the APC40 tab shows: the show's buttons with the pad colours their
/// ShowXpress colours give, its master faders, and [layout] (read from
/// [file] when not given). [windows] and [status] are the old server's
/// additions. Port of `Get-Info` (and `-Action Info`).
Apc40Info apc40Info(ShowEnv env, File file, {Apc40Layout? layout, bool windows = true, Apc40Status? status}) {
  final lay = layout ?? readApc40Layout(file);
  final info = LiveInfo.read(env);
  final seen = <String>{};
  final buttons = <Apc40Button>[];
  for (final b in psSorted<LiveButton>(info.buttons, [(b) => b.page, (b) => b.btn])) {
    final t = netTrim(b.title);
    if (t.isEmpty) continue;
    var hex = '#FFFFFF';
    final c = b.keys['color'] ?? '';
    if (RegExp(r'^-?\d+\n?$').hasMatch(c)) hex = '#${(int.parse(c.trim()) & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';
    final pc = apc40PadColor(hex);
    buttons.add(Apc40Button(title: t, page: b.page, pageName: b.pageName, color: hex, on: pc.on, off: pc.off, dup: !seen.add(t.toLowerCase())));
  }
  return Apc40Info(
    show: p.basename(env.root),
    file: file.path,
    layout: lay,
    buttons: buttons,
    faders: [for (final f in info.faders) Apc40Fader(k: f.k, caption: f.caption, type: f.type == '0' ? 'dimmer' : 'speed')],
    windows: windows,
    status: status,
  );
}

// ---------------------------------------------------------------- colours

/// The APC40 mk2 pad palette comes in groups of 4 from 4: pastel, bright,
/// dim, very dim (4 to 7 red, 8 to 11 orange...). Hue of each group's bright
/// colour, and where the group starts.
const _groups = [
  (0, 4), (20, 8), (60, 12), (95, 16), (120, 20), (135, 24), (150, 28), //
  (165, 32), (195, 36), (215, 40), (240, 44), (265, 48), (300, 52), (335, 56),
];

/// White on the pad: bright 3, dim 1.
const _white = Apc40Colors(on: 3, off: 1);

/// The palette numbers a ShowXpress colour (`#RRGGBB`) lights a pad in:
/// the nearest hue's bright and dim colour. Black, grey, white and anything
/// that isn't a colour light white. Port of `Get-PadColor`.
Apc40Colors apc40PadColor(String hex) {
  // -notmatch ignores case, and .NET's $ also matches before a final line break
  final m = RegExp(r'^#?([0-9a-fA-F]{6})\n?$').firstMatch(hex);
  if (m == null) return _white;
  final v = int.parse(m[1]!, radix: 16);
  final r = ((v >> 16) & 255) / 255, g = ((v >> 8) & 255) / 255, b = (v & 255) / 255;
  final mx = max(r, max(g, b)), mn = min(r, min(g, b)), d = mx - mn;
  if (mx < 0.08) return _white; // a black button: white on the pad (dark would look unassigned)
  if (d / mx < 0.3) return _white; // white or grey
  // PowerShell's % keeps the sign of the left side, like Dart's remainder
  var h = mx == r
      ? 60 * ((g - b) / d).remainder(6)
      : mx == g
      ? 60 * (((b - r) / d) + 2)
      : 60 * (((r - g) / d) + 4);
  if (h < 0) h += 360;
  var best = 4;
  num bd = 999;
  for (final (hue, start) in _groups) {
    var dd = (h - hue).abs();
    if (dd > 180) dd = 360 - dd;
    if (dd < bd) {
      bd = dd;
      best = start;
    }
  }
  return Apc40Colors(on: best + 1, off: best + 2);
}

// ---------------------------------------------------------------- Read-Layout

final _wholeNumber = RegExp(r'^\d+\n?$');

Apc40Layout _clean(Object? j) {
  final pages = <Apc40Page>[];
  final jp = _member(j, 'pages');
  if (psTruthy(j) && psTruthy(jp)) {
    for (final pg in jp is List ? jp : [jp]) {
      if (pages.length >= 8) break;
      final pads = <int, String>{};
      final jpads = _member(pg, 'pads');
      if (psTruthy(jpads)) {
        for (final (name, value) in _props(jpads)) {
          final n = netTryInt(name), t = netTrim(psText(value));
          if (n != null && n >= 0 && n <= 39 && t.isNotEmpty) pads[n] = t;
        }
      }
      final colors = <int, Apc40Colors>{};
      final jc = _member(pg, 'colors');
      if (psTruthy(jc)) {
        for (final (name, value) in _props(jc)) {
          final n = netTryInt(name);
          if (n == null || !pads.containsKey(n)) continue;
          final on = netTryInt(psText(_member(value, 'on'))), off = netTryInt(psText(_member(value, 'off')));
          if (on == null || off == null) continue;
          if (on >= 0 && on <= 127 && off >= 0 && off <= 127) colors[n] = Apc40Colors(on: on, off: off);
        }
      }
      var nm = netTrim(psText(_member(pg, 'name')).replaceAll(RegExp('[\x00-\x1f]'), ''));
      if (nm.length > 30) nm = nm.substring(0, 30);
      pages.add(Apc40Page(name: nm.isNotEmpty ? nm : 'Page ${pages.length + 1}', pads: pads, colors: colors));
    }
  }
  if (pages.isEmpty) pages.add(Apc40Page(name: 'Dancefloor'));
  final faders = <int, int>{};
  final jf = _member(j, 'faders');
  if (psTruthy(j) && psTruthy(jf)) {
    for (final (name, value) in _props(jf)) {
      final n = netTryInt(name);
      final t = psText(value);
      if (n != null && n >= 1 && n <= 9 && _wholeNumber.hasMatch(t)) faders[n] = _toInt32(t);
    }
  } else if (!psTruthy(j) || jf == null) {
    // default: faders 1 to 4 move master faders 1 to 4
    for (var k = 1; k <= 4; k++) {
      faders[k] = k - 1;
    }
  }
  return Apc40Layout(pages: pages, faders: faders);
}

/// `[int]$x` of a value whose text is digits: too big throws, with the
/// message PowerShell gives.
int _toInt32(String digits) {
  final v = int.tryParse(digits.trim());
  if (v == null || v > 0x7FFFFFFF) {
    throw ToolError('Cannot convert value "$digits" to type "System.Int32". Error: "Value was either too large or too small for an Int32."');
  }
  return v;
}

// ---------------------------------------------------------------- PowerShell's view of ConvertFrom-Json

/// `ConvertFrom-Json` of [text]: null for blank text, as PowerShell gives.
Object? psFromJson(String text) => text.trim().isEmpty ? null : jsonDecode(text);

/// `$o.key` on a value read by `ConvertFrom-Json`. Property names ignore
/// case. On a list it is member enumeration: the key of every item that is
/// an object (null for one without it), lists flattened, a single result
/// unwrapped, and null for none. Anything else has no such property.
Object? _member(Object? o, String key) {
  if (o is Map) {
    for (final e in o.entries) {
      if (psEq('${e.key}', key)) return e.value;
    }
    return null;
  }
  if (o is! List) return null;
  final out = <Object?>[];
  for (final e in o) {
    if (e is! Map && e is! List) continue;
    final v = _member(e, key);
    if (v is List) {
      out.addAll(v);
    } else {
      out.add(v);
    }
  }
  return switch (out.length) {
    0 => null,
    1 => out.first,
    _ => out,
  };
}

/// `$o.PSObject.Properties` as (name, value): an object's keys. Anything
/// else read from JSON has no property whose name is a number.
Iterable<(String, Object?)> _props(Object? o) => o is Map ? [for (final e in o.entries) ('${e.key}', e.value)] : const [];

/// `"$x"` of a value read by `ConvertFrom-Json`. An object is `@{a=1; b=x}`,
/// with a list inside it `System.Object[]` and an object inside it blank.
/// A list is its items joined by spaces. A fraction prints as Windows
/// PowerShell 5.1 or PowerShell 7 does, following [psFlavor].
String psText(Object? v) {
  String scalar(Object? x) => switch (x) {
    null => '',
    bool b => b ? 'True' : 'False',
    int i => '$i',
    double d => psFlavor == PsFlavor.winPs51 ? '$d' : psDoubleText(d),
    _ => '$x',
  };
  String obj(Map<Object?, Object?> m) => m.isEmpty
      ? ''
      : '@{${[for (final e in m.entries) '${e.key}=${switch (e.value) {
            List _ => 'System.Object[]',
            Map _ => '',
            final x => scalar(x),
          }}'].join('; ')}}';
  return switch (v) {
    Map m => obj(m),
    List l => [
      for (final x in l)
        switch (x) {
          List _ => 'System.Object[]',
          Map m => obj(m),
          _ => scalar(x),
        },
    ].join(' '),
    _ => scalar(v),
  };
}

/// .NET's `[int]::TryParse`: an optional sign and ASCII digits, with
/// spaces and tabs around them, within 32 bits. Null when it fails.
int? netTryInt(String s) {
  final m = RegExp(r'^[\t\n\v\f\r ]*([+-]?\d+)[\t\n\v\f\r ]*$').firstMatch(s);
  if (m == null) return null;
  final v = int.tryParse(m[1]!);
  return v == null || v < -0x80000000 || v > 0x7FFFFFFF ? null : v;
}

const _netSpace = {
  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, //
  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
  0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
};

/// .NET's `String.Trim()`. Unlike Dart's `trim` it keeps a byte order mark.
String netTrim(String s) {
  var a = 0, b = s.length;
  while (a < b && _netSpace.contains(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && _netSpace.contains(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}
