import 'dart:math' as math;

import 'package:sx_api/sx_api.dart';

/// One tile on the board: a show button or a button on one of the player's
/// own pages, with what the screen needs to draw and press it.
class LabTile {
  const LabTile({
    required this.sec,
    required this.title,
    required this.file,
    required this.kind,
    required this.steps,
    required this.color,
    required this.bpm,
    required this.flash,
    required this.fader,
    required this.beats,
    required this.key,
    required this.custom,
  });

  LabTile.show(LabButton b)
    : this(
        sec: b.sec,
        title: b.title,
        file: b.file,
        kind: b.kind,
        steps: b.steps,
        color: b.color,
        bpm: b.bpm,
        flash: b.flash,
        fader: b.fader,
        beats: b.beats,
        key: b.key,
        custom: false,
      );

  /// A player page's button. Its kind comes from the show's file list (lbFileKind).
  LabTile.player(PlayerButton b, List<String> files)
    : this(
        sec: b.id,
        title: b.title,
        file: b.file,
        kind: fileKind(b.file, files),
        steps: 0,
        color: b.color,
        bpm: b.bpm,
        flash: b.flash,
        fader: b.fader,
        beats: b.beats,
        key: '',
        custom: true,
      );

  final String sec;
  final String title;
  final String file;
  final LabKind kind;
  final int steps;
  final int color;
  final bool bpm;
  final bool flash;
  final int fader;
  final double beats;
  final String key;

  /// On one of the player's own pages.
  final bool custom;

  bool get missing => kind == LabKind.missing;

  /// What the tile says while it isn't playing (lbKind0).
  String get kindText => switch (kind) {
    LabKind.gpj => 'movement${bpm ? ' · BPM' : ''}',
    LabKind.missing => 'scene file missing',
    LabKind.scex => '${steps > 1 ? '$steps steps' : 'scene'}${bpm ? ' · BPM${flash ? ' flash' : ''}' : ''}',
  };

  /// [kindText] with the keyboard key in front (lbKind).
  String get label => key.isEmpty ? kindText : '[${key.toUpperCase()}] $kindText';
}

/// Whether [file] is a scene, a movement or not in the show (lbFileKind).
LabKind fileKind(String file, List<String> files) {
  final l = file.toLowerCase();
  if (!files.any((f) => f.toLowerCase() == l)) return LabKind.missing;
  return file.toLowerCase().endsWith('.gpj') ? LabKind.gpj : LabKind.scex;
}

/// A page as the board draws it: a show page or one of the player's own.
class LabBoardPage {
  const LabBoardPage({required this.id, required this.name, required this.swap, required this.custom, required this.tiles, required this.n});

  /// The page number as text, or the player page's `x<n>`. Its id in the layout.
  final String id;
  final String name;
  final bool swap;
  final bool custom;
  final List<LabTile> tiles;

  /// Sort position when the layout doesn't place the page.
  final int n;

  String get title => name.isEmpty ? 'Page $id' : name;
}

/// Every page, the show's then the player's, in their own order (lbAllPages).
List<LabBoardPage> allPages(LabBoard board, PlayerLayout lay) => [
  for (final p in board.pages)
    LabBoardPage(id: '${p.n}', name: p.name, swap: p.swap, custom: false, tiles: [for (final b in p.buttons) LabTile.show(b)], n: 1000000 + p.n),
  for (final (i, c) in lay.custom.indexed)
    LabBoardPage(id: c.id, name: c.name, swap: c.swap, custom: true, tiles: [for (final b in c.buttons) LabTile.player(b, board.files)], n: 2000000 + i),
];

/// A page placed on the board, with its tiles in the layout's order.
typedef PlacedPage = ({LabBoardPage page, List<LabTile> tiles, bool hidden, bool collapsed});

/// The pages the board shows, in the layout's order (lbPages). Hidden pages
/// only show while [arranging]. Show pages without buttons never show.
List<PlacedPage> placedPages(LabBoard board, PlayerLayout lay, {required bool arranging}) {
  int ix(List<String> a, String v, int d) {
    final i = a.indexOf(v);
    return i < 0 ? d : i;
  }

  final hid = lay.hidden.toSet();
  final pages = [
    for (final p in allPages(board, lay))
      if ((p.custom || p.tiles.isNotEmpty) && (arranging || !hid.contains(p.id))) p,
  ];
  // List.sort isn't stable. Sorting on (key, position) is.
  final keyed = [for (final (i, p) in pages.indexed) (ix(lay.pages, p.id, p.n), i, p)]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [
    for (final (_, _, p) in keyed)
      (
        page: p,
        hidden: hid.contains(p.id),
        collapsed: lay.collapsed.contains(p.id),
        tiles: p.custom
            ? p.tiles
            : () {
                final o = lay.order[p.id] ?? const <String>[];
                final t = [for (final (i, b) in p.tiles.indexed) (ix(o, b.sec, 1000000), i, b)]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
                return [for (final (_, _, b) in t) b];
              }(),
      ),
  ];
}

/// Speed factor of a fader at [v] (0 to 1): a quarter at the bottom, four times at the top (lbX).
double faderFactor(double v) => math.pow(2, (v - .5) * 4).toDouble();

/// A fader's speed as the screen shows it, "×1.00 (normal)" (lbXs).
String faderText(double v) {
  final x = faderFactor(v);
  return '×${x.toStringAsFixed(x >= 2 ? 1 : 2)}${(v - .5).abs() < .01 ? ' (normal)' : ''}';
}

/// What a playing tile says instead of its kind.
/// The screen puts a play icon in front.
String playText(LabPlay p) => p.mv
    ? 'moving'
    : p.of > 1
    ? 'step ${p.step} of ${p.of}'
    : 'on';

/// Text typed into a page or button name, cleaned as the old page does (lbClean).
String cleanName(String v) {
  final t = v.replaceAll(RegExp(r'[\x00-\x1f<>|]'), '').trim();
  return t.length > 40 ? t.substring(0, 40) : t;
}

/// The id a new player page gets: one past the highest (lbNextPage).
String nextPageId(PlayerLayout lay) => 'x${1 + lay.custom.map((c) => int.tryParse(c.id.substring(1)) ?? 0).fold(0, math.max)}';

/// The id a new button on [page] gets (lbNextBtn).
String nextButtonId(PlayerPage page) {
  final ns = page.buttons.map((b) {
    final parts = b.id.split('_b');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  });
  return '${page.id}_b${1 + ns.fold(0, math.max)}';
}

/// A copy of a show button for a player page (lbAddButtons). A missing
/// `beats` reads as 0 from the old tool, and a copy gets 1 then.
PlayerButton copyOf(String id, LabTile b) =>
    PlayerButton(id: id, title: b.title, file: b.file, fader: b.fader, bpm: b.bpm, flash: b.flash, beats: b.beats == 0 ? 1 : b.beats, color: b.color);

/// Something that can go on a player page: a show button, or a file no
/// button plays.
class AddItem {
  const AddItem({required this.title, required this.sub, this.tile, this.file});

  final String title;
  final String sub;
  final LabTile? tile;
  final String? file;
}

/// The list the "Add buttons" dialog offers: every show button whose file is
/// there, then every scene or movement no show button plays.
List<AddItem> addItems(LabBoard board) {
  final used = {for (final p in board.pages) ...p.buttons.map((b) => b.file.toLowerCase())};
  return [
    for (final p in board.pages)
      for (final b in p.buttons)
        if (b.kind != LabKind.missing)
          AddItem(title: b.title, sub: '${p.name.isEmpty ? 'Page ${p.n}' : p.name} · ${LabTile.show(b).kindText}', tile: LabTile.show(b)),
    for (final f in board.files)
      if (!used.contains(f.toLowerCase()))
        AddItem(
          title: f.replaceAll(RegExp(r'\.(scex|gpj)$', caseSensitive: false), ''),
          sub: 'not on a button · ${f.toLowerCase().endsWith('.gpj') ? 'movement' : 'scene'}',
          file: f,
        ),
  ];
}

/// Adds [items] to player page [id], up to 64 buttons. Returns the new
/// layout and whether some didn't fit.
(PlayerLayout, bool) addToPage(PlayerLayout lay, String id, List<AddItem> items) {
  var full = false;
  final custom = [
    for (final c in lay.custom)
      if (c.id != id)
        c
      else
        () {
          var page = c;
          for (final x in items) {
            if (page.buttons.length >= 64) {
              full = true;
              continue;
            }
            final bid = nextButtonId(page);
            final b = switch (x) {
              AddItem(tile: final t?) => copyOf(bid, t),
              AddItem(:final file?) => PlayerButton(id: bid, title: x.title, file: file),
              _ => null,
            };
            if (b != null) page = page.copyWith(buttons: [...page.buttons, b]);
          }
          return page;
        }(),
  ];
  return (lay.copyWith(custom: custom), full);
}

/// The layout after the user moved pages or buttons on screen (lbSaveLayout
/// with no layout): [shown] is every page on screen, in screen order, with
/// its tiles in screen order. Pages the layout knows that aren't on screen
/// keep their place after them.
PlayerLayout layoutFromScreen(PlayerLayout lay, List<(String, List<String>)> shown) {
  final pages = [for (final (id, _) in shown) id];
  final order = {...lay.order};
  final custom = [...lay.custom];
  for (final (id, secs) in shown) {
    final ci = custom.indexWhere((c) => c.id == id);
    if (ci >= 0) {
      final c = custom[ci];
      custom[ci] = c.copyWith(buttons: [for (final s in secs) ...c.buttons.where((b) => b.id == s).take(1)]);
    } else {
      order[id] = secs;
    }
  }
  for (final n in lay.pages) {
    if (!pages.contains(n)) pages.add(n);
  }
  return lay.copyWith(pages: pages, order: order, custom: custom);
}

/// Toggles [id] in [list], the way the old page does: taken out, and put at
/// the end when it wasn't there.
List<String> toggled(List<String> list, String id) => [...list.where((x) => x != id), if (!list.contains(id)) id];
