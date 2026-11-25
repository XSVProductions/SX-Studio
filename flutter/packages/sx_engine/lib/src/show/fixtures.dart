import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import 'live_ini.dart';
import 'show_env.dart';
import 'text_files.dart';

// Port of the fixture-profile, scene-step and live-button functions in
// `show_common.ps1`.

/// A named DMX value range of one channel ("closed" = 0..7).
typedef ChannelRange = ({String name, int lo, int hi});

/// Fixture profiles (`fixtures/<model>.txt`), read once per model.
class FixtureDefs {
  FixtureDefs(this.env);

  final ShowEnv env;
  final _cache = <String, Map<String, List<ChannelRange>>>{};

  /// Channel name (lowercase) to its ranges. Only the first definition of
  /// each channel name counts. Empty when the model has no profile file.
  Map<String, List<ChannelRange>> of(String model) => _cache.putIfAbsent(model, () {
    final d = <String, List<ChannelRange>>{};
    final f = env.file('fixtures/$model.txt');
    if (!f.existsSync()) return d;
    final channel = RegExp(r'^Channel = (.+?)\s*$', caseSensitive: false), range = RegExp(r'([^,]+?),(\d+),(\d+)');
    String? ch;
    for (final l in readLines(f.path)) {
      final m = channel.firstMatch(l);
      if (m != null) {
        ch = m[1]!.toLowerCase();
        if (d.containsKey(ch)) {
          ch = null;
        } else {
          d[ch] = [];
        }
        continue;
      }
      if (ch != null && l.trim().isNotEmpty && d[ch]!.isEmpty) {
        d[ch] = [for (final r in range.allMatches(l)) (name: r[1]!.trim().toLowerCase(), lo: int.parse(r[2]!), hi: int.parse(r[3]!))];
      }
    }
    return d;
  });

  /// True when shutter value [v] is in the model's "closed" range. A model
  /// without one counts 0 as closed.
  bool shutterClosed(String model, int v) {
    final closed = (of(model)['shutter'] ?? const []).where((r) => r.name == 'closed').toList();
    if (closed.isEmpty) return v == 0;
    return closed.any((r) => v >= r.lo && v <= r.hi);
  }

  /// Which fixed color-wheel slot [v] selects (0 = first), or -1 when it is
  /// in the index/rotate part of the wheel or unknown.
  int colorSlot(String model, int v) {
    var i = 0;
    for (final r in of(model)['color'] ?? const <ChannelRange>[]) {
      if (RegExp('index|rotate|stop').hasMatch(r.name)) break;
      if (v >= r.lo && v <= r.hi) return i;
      i++;
    }
    return -1;
  }
}

/// One step of a scene, as far as the movers go.
class SceneStep {
  SceneStep({required this.cs, required this.lit, required this.other, required this.colors});

  /// Step length in hundredths of a second.
  final int cs;

  /// Ids of the movers that are lit in this step.
  final List<String> lit;

  /// True when some fixture that is not a mover has a channel above 0.
  final bool other;

  /// Color channel value per mover id.
  final Map<String, int> colors;
}

/// Reads a `.scex` and says which movers each step lights.
///
/// [modelOf] maps mover id to model. A mover is lit when its dimmer is above
/// 0 (or it has none) and its shutter is not closed.
List<SceneStep> sceneSteps(FixtureDefs defs, String path, Map<String, String> modelOf) {
  final scene = XmlDocument.parse(readText(path)).rootElement;
  final out = <SceneStep>[];
  for (final s in scene.findElements('Steps').expand((x) => x.findElements('Step'))) {
    final lit = <String>[];
    final colors = <String, int>{};
    var other = false;
    for (final fx in s.findElements('Fixture')) {
      final id = fx.getAttribute('id') ?? '';
      final channels = fx.findElements('Channel');
      final model = modelOf[id];
      if (model != null) {
        var on = true;
        for (final c in channels) {
          final name = (c.getAttribute('name') ?? '').toLowerCase(), v = psInt(c.getAttribute('value'));
          if (name == 'dimmer' && v <= 0) on = false;
          if (name == 'shutter' && defs.shutterClosed(model, v)) on = false;
          if (name == 'color') colors[id] = v;
        }
        if (on) lit.add(id);
      } else if (channels.any((c) => psInt(c.getAttribute('value')) > 0)) {
        other = true;
      }
    }
    final len = s.getAttribute('length') ?? '';
    out.add(SceneStep(cs: RegExp(r'^\d+$').hasMatch(len) ? int.parse(len) : 0, lit: lit, other: other, colors: colors));
  }
  return out;
}

/// SHA-256 of [s] as UTF-8, lowercase hex. The editors use it to notice that
/// a file changed since the screen loaded it.
String textSha(String s) => sha256.convert(utf8.encode(s)).toString();

/// Adds a button to live page [page] in the first free cell and returns the
/// cell as (line, column). Lines run 1..8. Columns are tried in [cols] order,
/// row by row, or column by column when [down] is set.
///
/// [info] is not updated. Read it again before using its buttons.
(int, int) addLiveButton(LiveIni ini, LiveInfo info, int page, String scene, String title, {List<int>? cols, bool down = false}) {
  cols ??= [for (var c = 1; c <= 10; c++) c];
  final mine = info.buttons.where((b) => b.page == page).toList();
  final used = {for (final b in mine) '${b.keys['line'] ?? ''}/${b.keys['column'] ?? ''}'};
  final cells = down
      ? [
          for (final co in cols)
            for (var ln = 1; ln <= 8; ln++) (ln, co),
        ]
      : [
          for (var ln = 1; ln <= 8; ln++)
            for (final co in cols) (ln, co),
        ];
  final free = cells.where((c) => !used.contains('${c.$1}/${c.$2}'));
  if (free.isEmpty) throw ToolError('The page ${info.pages[page] ?? ''} is full. NOTHING was changed.');
  final cell = free.first;
  var n = 1;
  while (ini.findSection('page${page}_button$n') != null) {
    n++;
  }
  final lastSec = mine.isEmpty ? 'page$page' : psSorted<LiveButton>(mine, [(b) => b.btn]).last.sec;
  final last = ini.findSection(lastSec);
  if (last == null) throw StateError('live.ini has no [$lastSec] section');
  ini.lines.insertAll(last.$2, [
    '[page${page}_button$n]',
    'line = ${cell.$1}',
    'column = ${cell.$2}',
    'name = $scene',
    'title = $title',
    'masterspeedfader = 0',
  ]);
  ini.setKey('page$page', 'nb_buttons', '${mine.length + 1}', after: const ['name']);
  return cell;
}
