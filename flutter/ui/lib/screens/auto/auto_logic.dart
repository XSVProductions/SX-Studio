import 'dart:math';

import 'package:sx_api/sx_api.dart';

/// The bar counts the look menu offers.
const autoBars = [1, 2, 4, 8, 12, 16, 24, 32, 48, 64];

/// A new look id, 8 hex digits.
String newLookId([Random? r]) {
  final rnd = r ?? Random();
  return List.generate(8, (_) => '0123456789abcdef'[rnd.nextInt(16)]).join();
}

/// m:ss for a number of seconds.
String fmtSeconds(num s) {
  final t = max(0, s.round());
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

/// How long a look plays, in seconds.
double lookSeconds(AutoLook l, double bpm) => l.bars * 4 * 60 / bpm;

/// The button a title presses: the first with that title. Null when it is
/// not in the show.
AutoButton? buttonFor(List<AutoButton> buttons, String title) => buttons.where((b) => b.title == title && !b.dup).firstOrNull;

/// Groups of titles in [l] that sit on the same "swap" page (one button at a
/// time), as (page, titles). Several of them can't play together.
List<(String, List<String>)> lookClashes(AutoLook l, List<AutoButton> buttons) {
  final g = <String, List<String>>{};
  for (final x in l.titles) {
    final b = buttonFor(buttons, x);
    if (b != null && b.swap) g.putIfAbsent(b.page, () => []).add(x);
  }
  return [
    for (final e in g.entries)
      if (e.value.length > 1) (e.key, e.value),
  ];
}

/// The biggest clash in [l], or null.
(String, List<String>)? biggestClash(AutoLook l, List<AutoButton> buttons) {
  final c = lookClashes(l, buttons)..sort((a, b) => b.$2.length.compareTo(a.$2.length));
  return c.firstOrNull;
}

/// Splits look [i] into one look per button of its biggest clash, each
/// keeping the look's other buttons. Returns how many looks it became, or 0.
int splitLook(AutoConfig c, int i, List<AutoButton> buttons, {Random? random}) {
  final l = c.looks[i], clash = biggestClash(l, buttons);
  if (clash == null) return 0;
  final (page, many) = clash;
  final rest = l.titles.where((x) => !many.contains(x)).toList();
  bool onPage(String x) {
    final b = buttonFor(buttons, x);
    return b != null && b.swap && b.page == page;
  }

  final looks = [
    for (final (k, m) in many.indexed)
      AutoLook(
        id: k == 0 ? l.id : newLookId(random),
        name: (many.length > 1 ? m : l.name).substring(0, min(40, (many.length > 1 ? m : l.name).length)),
        bars: l.bars,
        on: l.on,
        titles: [...rest.where((x) => !onPage(x)), m],
      ),
  ];
  c.looks.replaceRange(i, i + 1, looks);
  return looks.length;
}

/// A BPM from taps (milliseconds since some start). Needs three taps; a gap
/// of more than two seconds starts over. Returns the taps to keep and the
/// BPM, or null BPM while there are too few.
(List<int>, double?) tapTempo(List<int> taps, int now) {
  final t = [if (taps.isEmpty || now - taps.last <= 2000) ...taps, now];
  while (t.length > 9) {
    t.removeAt(0);
  }
  if (t.length < 3) return (t, null);
  final d = (t.last - t.first) / (t.length - 1);
  return (t, (60000 / d).roundToDouble());
}

/// A BPM as the screen keeps it: 40 to 220, one decimal.
double clampBpm(double v) => (v.clamp(40, 220) * 10).round() / 10;

/// The BPM as the engine's command wants it: `124` or `124.5`.
String bpmText(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

/// Where a playing look is [ms] after its status was taken.
({int bar, int beat, double? leftMs, double fraction}) lookProgress(AutoStatus s, double ms) {
  final beatMs = 60000 / s.bpm, tot = s.bars * 4 * beatMs;
  if (s.held || s.bars == 0) return (bar: s.bar, beat: s.beat, leftMs: null, fraction: s.bars == 0 ? 0 : (s.bar - 1) / s.bars);
  final left = max(0.0, s.msLeft - ms), el = tot - left;
  return (bar: min(s.bars, (el / (beatMs * 4)).floor() + 1), beat: (el / beatMs).floor() % 4 + 1, leftMs: left, fraction: min(1.0, el / tot));
}
