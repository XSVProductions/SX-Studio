import 'dart:convert';

import 'package:sx_api/sx_api.dart';

/// "row 2, column 5" for APC40 pad [n] (0 bottom left, 39 top right; row 1
/// is the top row). The old `a4rc`.
String a4Place(int n) => 'row ${5 - n ~/ 8}, column ${n % 8 + 1}';

/// The pad after [n] in reading order (left to right, top row first), or -1
/// after the last one. The old `a4Next`.
int a4Next(int n) {
  final i = (4 - n ~/ 8) * 8 + n % 8 + 1;
  return i >= 40 ? -1 : (4 - i ~/ 8) * 8 + i % 8;
}

/// The layout as the tab edits it, the old `a4Fix`: a copy, with at least
/// one page, and no colours for a pad that plays nothing.
Apc40Layout a4Fix(Apc40Layout l) {
  final c = l.copy();
  if (c.pages.isEmpty) c.pages.add(Apc40Page(name: 'Dancefloor'));
  for (final p in c.pages) {
    p.colors.removeWhere((k, _) => !p.pads.containsKey(k));
  }
  return c;
}

/// What decides whether two layouts are the same, the old `a4Norm`.
String _norm(Apc40Layout l) => jsonEncode({
  'p': [
    for (final p in l.pages)
      [
        p.name,
        for (final k in p.pads.keys.toList()..sort())
          [
            k,
            p.pads[k],
            if (p.colors[k] case final c?) [c.on, c.off] else 0,
          ],
      ],
  ],
  'f': [
    for (final k in l.faders.keys.toList()..sort()) [k, l.faders[k]],
  ],
});

/// The unsaved edits on the APC40 tab: the pages, the page on show, the pad
/// picked, and the faders. Port of the old page's APC40 script (`a4...`).
class Apc40Edits {
  Apc40Edits(this.info) : layout = a4Fix(info.layout);

  /// What the engine last answered.
  final Apc40Info info;

  /// The layout with the edits, saved or not.
  Apc40Layout layout;

  /// The page on show, 0-based.
  var page = 0;

  /// The pad picked, or -1.
  var selected = -1;

  /// The pad colour section stays open once the user opened it.
  var colourOpen = false;

  Apc40Page get pg => layout.pages[page];

  bool get dirty => _norm(layout) != _norm(a4Fix(info.layout));

  /// The button each title plays: the first one that isn't a duplicate. The old `a4B`.
  late final Map<String, Apc40Button> buttons = () {
    final m = <String, Apc40Button>{};
    for (final b in info.buttons) {
      if (!b.dup) m.putIfAbsent(b.title, () => b);
    }
    return m;
  }();

  /// The button on pad [n] of the page on show, or null when the pad is
  /// empty or its button isn't in ShowXpress.
  Apc40Button? buttonOn(int n) => buttons[pg.pads[n]];

  /// The palette number pad [n] lights in while playing ([playing]) or idle:
  /// its own colour, else its button's. Null when neither. The old `a4On` and `a4Off`.
  int? colour(int n, bool playing) {
    final c = pg.colors[n];
    if (c != null) return playing ? c.on : c.off;
    final b = buttonOn(n);
    return b == null ? null : (playing ? b.on : b.off);
  }

  /// A tap on pad [n]: picks it, or lets go when it was picked.
  void tap(int n) => selected = selected == n ? -1 : n;

  /// Shows page [i].
  void showPage(int i) {
    page = i;
    selected = -1;
  }

  /// Puts the button [title] on the picked pad and moves on to the next pad.
  /// The pad's own colours go when it gets another button.
  void assign(String title) {
    if (selected < 0) return;
    if (pg.pads[selected] != title) pg.colors.remove(selected);
    pg.pads[selected] = title;
    selected = a4Next(selected);
  }

  /// Empties pad [n], and lets go of it when [deselect].
  void clear(int n, {bool deselect = false}) {
    pg.pads.remove(n);
    pg.colors.remove(n);
    if (deselect && selected == n) selected = -1;
  }

  /// Sets pad [n]'s colour while playing ([playing]) or when idle.
  void setColour(int n, bool playing, int v) {
    final c = pg.colors[n] ?? Apc40Colors(on: colour(n, true) ?? 0, off: colour(n, false) ?? 0);
    pg.colors[n] = playing ? Apc40Colors(on: v, off: c.off) : Apc40Colors(on: c.on, off: v);
    colourOpen = true;
  }

  /// Pad [n] goes back to its button's ShowXpress colour.
  void useButtonColour(int n) => pg.colors.remove(n);

  /// Moves pad [f] of page [fp] to pad [to] of page [tp], with its colours.
  /// What was there goes back in its place. The old `a4Move`.
  void move(int fp, int f, int tp, int to) {
    if (fp == tp && f == to) return;
    final a = layout.pages[fp], b = layout.pages[tp];
    final x = a.pads[f], y = b.pads[to];
    if (x == null) return;
    final cx = a.colors[f], cy = b.colors[to];
    if (y != null) {
      a.pads[f] = y;
    } else {
      a.pads.remove(f);
    }
    b.pads[to] = x;
    if (cy != null) {
      a.colors[f] = cy;
    } else {
      a.colors.remove(f);
    }
    if (cx != null) {
      b.colors[to] = cx;
    } else {
      b.colors.remove(to);
    }
    if (fp == page && selected == f) {
      selected = tp == page ? to : -1;
    } else if (tp == page && selected == to) {
      selected = f;
    }
  }

  /// Pad [f] dropped on pad [to] of the same page: they swap.
  void drop(int f, int to) => move(page, f, page, to);

  /// Pad [f] dropped on page [i]'s tab: it goes to the same spot there.
  /// Returns what the bar says.
  String dropOnPage(int f, int i) {
    final t = pg.pads[f], had = layout.pages[i].pads[f];
    if (t == null) return '';
    move(page, f, i, f);
    return '$t moved to ${layout.pages[i].name} (same spot)${had == null ? '' : '. $had came back here in its place'}.';
  }

  /// Adds a page and shows it. At most 8.
  void addPage() {
    if (layout.pages.length >= 8) return;
    layout.pages.add(Apc40Page(name: 'Page ${layout.pages.length + 1}'));
    showPage(layout.pages.length - 1);
  }

  void rename(String name) => pg.name = name;

  /// The name box lost focus: an empty name becomes "Page N".
  void renameDone() {
    if (pg.name.trim().isEmpty) pg.name = 'Page ${page + 1}';
  }

  /// Swaps the page on show with page [to] and follows it there.
  void movePage(int to) {
    final x = layout.pages[page];
    layout.pages[page] = layout.pages[to];
    layout.pages[to] = x;
    page = to;
  }

  /// Deletes the page on show, unless it is the only one.
  void deletePage() {
    if (layout.pages.length < 2) return;
    layout.pages.removeAt(page);
    page = page > 0 ? page - 1 : 0;
  }

  /// Empties every pad of the page on show.
  void clearAll() {
    pg.pads.clear();
    pg.colors.clear();
  }

  /// The ShowXpress pages, in order, for "Fill the empty pads".
  List<String> get sxPages => {for (final b in info.buttons) b.pageName}.toList();

  /// Puts the buttons of ShowXpress page [name] that aren't on this page yet
  /// on the empty pads, in reading order. Returns what the bar says.
  String fill(String name) {
    final have = pg.pads.values.toSet();
    var n = 32, add = 0, left = 0;
    for (final b in info.buttons.where((b) => b.pageName == name && !b.dup && !have.contains(b.title))) {
      while (n >= 0 && pg.pads.containsKey(n)) {
        n = a4Next(n);
      }
      if (n < 0) {
        left++;
        continue;
      }
      pg.pads[n] = b.title;
      add++;
      n = a4Next(n);
    }
    return '$add button(s) from $name put on the pads${left > 0 ? '. $left didn\'t fit' : ''}.';
  }

  /// APC40 fader [f] (1 to 9) moves ShowXpress master fader [k], or nothing when null.
  void setFader(int f, int? k) => k == null ? layout.faders.remove(f) : layout.faders[f] = k;

  void undo() {
    layout = a4Fix(info.layout);
    page = page.clamp(0, layout.pages.length - 1);
    selected = -1;
  }

  /// The buttons for the picked pad's list, filtered by [query] on title or
  /// page name, grouped by ShowXpress page.
  List<(String, List<Apc40Button>)> listed(String query) {
    final q = query.trim().toLowerCase();
    final out = <(String, List<Apc40Button>)>[];
    for (final b in info.buttons) {
      if (b.dup || (q.isNotEmpty && !b.title.toLowerCase().contains(q) && !b.pageName.toLowerCase().contains(q))) continue;
      if (out.isEmpty || out.last.$1 != b.pageName) out.add((b.pageName, []));
      out.last.$2.add(b);
    }
    return out;
  }
}

/// The colour of the dot on the status line.
enum Apc40Dot { amber, green, red }

/// The status line under the header, the old `a4Conn`: the dot, the bold
/// part, the rest, and the last pad pressed.
({Apc40Dot dot, String bold, String text, String last}) apc40StatusLine(bool windows, Apc40Status? s) {
  if (!windows) {
    return (dot: Apc40Dot.amber, bold: '', text: 'The APC40 works with SX Studio on Windows. You can still set up its pages here.', last: '');
  }
  if (s == null || !s.running) return (dot: Apc40Dot.amber, bold: '', text: 'Starting the APC40 part of SX Studio…', last: '');
  switch (s.apc) {
    case 'ok':
      final sx = switch (s.sx) {
        'ok' => 'ShowXpress connected',
        'closed' => "ShowXpress is closed. The pads light up once it's open",
        'off' || 'refused' => s.error,
        _ => 'connecting to ShowXpress…',
      };
      return (
        dot: s.sx == 'ok' ? Apc40Dot.green : Apc40Dot.amber,
        bold: 'APC40 connected',
        text: ' · on page ${s.page}${s.pageName.isEmpty ? '' : ' (${s.pageName})'}${sx.isEmpty ? '' : ' · $sx'}',
        last: s.last,
      );
    case 'missing':
      return (dot: Apc40Dot.amber, bold: '', text: "APC40 not plugged in. Plug it in and it's ready in a couple of seconds", last: '');
    case 'busy':
      return (dot: Apc40Dot.red, bold: '', text: s.error.isEmpty ? 'Another program has the APC40.' : s.error, last: '');
  }
  return (dot: Apc40Dot.amber, bold: '', text: 'Starting…', last: '');
}
