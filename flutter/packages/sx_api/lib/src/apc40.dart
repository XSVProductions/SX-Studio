import 'client.dart';
import 'json.dart';

/// The two APC40 palette numbers (0..127) a pad lights in.
class Apc40Colors {
  const Apc40Colors({required this.on, required this.off});

  factory Apc40Colors.fromJson(Json j) => Apc40Colors(on: j.integer('on'), off: j.integer('off'));

  /// While the pad's button plays.
  final int on;

  /// When it is idle.
  final int off;

  Json toJson() => {'on': on, 'off': off};
}

/// One page of APC40 pads. Track Select 1 to 8 pick the page.
class Apc40Page {
  Apc40Page({required this.name, Map<int, String>? pads, Map<int, Apc40Colors>? colors}) : pads = pads ?? {}, colors = colors ?? {};

  factory Apc40Page.fromJson(Json j) => Apc40Page(
    name: j.str('name'),
    pads: {for (final e in j.obj('pads').entries) int.parse(e.key): '${e.value}'},
    colors: {
      for (final e in j.obj('colors').entries)
        if (e.value case final Map<Object?, Object?> c) int.parse(e.key): Apc40Colors.fromJson(c.cast<String, Object?>()),
    },
  );

  String name;

  /// Pad number (0 bottom left, 39 top right) to the title of the ShowXpress
  /// button it plays.
  final Map<int, String> pads;

  /// A pad's own colours. A pad that isn't here lights in its button's
  /// ShowXpress colour.
  final Map<int, Apc40Colors> colors;

  Apc40Page copy() => Apc40Page(name: name, pads: {...pads}, colors: {...colors});

  /// As `ConvertTo-LayoutJson` in `apc40.ps1`: keys in number order, and no
  /// `colors` when there are none.
  Json toJson() {
    Map<String, T> sorted<T>(Map<int, T> m) => {for (final k in m.keys.toList()..sort()) '$k': m[k] as T};
    return {'name': name, 'pads': sorted(pads), if (colors.isNotEmpty) 'colors': sorted(colors.map((k, v) => MapEntry(k, v.toJson())))};
  }
}

/// The APC40 layout, kept in SX Studio's own `apc40.json` (never a show file).
class Apc40Layout {
  Apc40Layout({List<Apc40Page>? pages, Map<int, int>? faders}) : pages = pages ?? [], faders = faders ?? {};

  factory Apc40Layout.fromJson(Json j) => Apc40Layout(
    pages: j.list('pages', Apc40Page.fromJson),
    faders: {for (final e in j.obj('faders').entries) int.parse(e.key): j.obj('faders').integer(e.key)},
  );

  /// Up to 8.
  final List<Apc40Page> pages;

  /// APC40 fader (1 to 8, 9 is its master fader) to the 0-based ShowXpress
  /// master fader it moves.
  final Map<int, int> faders;

  Apc40Layout copy() => Apc40Layout(pages: [for (final p in pages) p.copy()], faders: {...faders});

  Json toJson() => {
    'pages': [for (final p in pages) p.toJson()],
    'faders': {for (final k in faders.keys.toList()..sort()) '$k': faders[k]},
  };
}

/// A ShowXpress button a pad can play.
class Apc40Button {
  const Apc40Button({
    required this.title,
    required this.page,
    required this.pageName,
    required this.color,
    required this.on,
    required this.off,
    required this.dup,
  });

  factory Apc40Button.fromJson(Json j) => Apc40Button(
    title: j.str('title'),
    page: j.integer('page'),
    pageName: j.str('pageName'),
    color: j.str('color'),
    on: j.integer('on'),
    off: j.integer('off'),
    dup: j.boolean('dup'),
  );

  final String title;
  final int page;
  final String pageName;

  /// The button's ShowXpress colour, `#RRGGBB`.
  final String color;

  /// The palette numbers that colour gives a pad (`Get-PadColor`).
  final int on;
  final int off;

  /// True when an earlier button has the same title. ShowXpress presses the
  /// first one.
  final bool dup;

  Json toJson() => {'title': title, 'page': page, 'pageName': pageName, 'color': color, 'on': on, 'off': off, 'dup': dup};
}

/// A ShowXpress master fader an APC40 fader can move.
class Apc40Fader {
  const Apc40Fader({required this.k, required this.caption, required this.type});

  factory Apc40Fader.fromJson(Json j) => Apc40Fader(k: j.integer('k'), caption: j.str('caption'), type: j.str('type'));

  /// 0-based master fader number.
  final int k;
  final String caption;

  /// `speed` or `dimmer`.
  final String type;

  Json toJson() => {'k': k, 'caption': caption, 'type': type};
}

/// What the APC40 bridge is doing, the old `sxh_apc40_<pid>.json`.
class Apc40Status {
  const Apc40Status({
    required this.running,
    required this.pid,
    required this.apc,
    required this.sx,
    required this.page,
    required this.pageName,
    required this.pages,
    required this.last,
    required this.error,
    required this.at,
  });

  factory Apc40Status.fromJson(Json j) => Apc40Status(
    running: j.boolean('running'),
    pid: j.integer('pid'),
    apc: j.str('apc'),
    sx: j.str('sx'),
    page: j.integer('page'),
    pageName: j.str('pageName'),
    pages: j.integer('pages'),
    last: j.str('last'),
    error: j.str('error'),
    at: j.str('at'),
  );

  final bool running;
  final int pid;

  /// The APC40: `starting`, `ok`, `missing` (not plugged in), `busy` (another
  /// program has it), `sim` (tests) or `stopped`.
  final String apc;

  /// ShowXpress's remote: `starting`, `ok`, `closed`, `off`, `lost`,
  /// `refused` or `waiting` (no APC40 yet).
  final String sx;

  /// 1-based page the APC40 is on.
  final int page;
  final String pageName;
  final int pages;

  /// The last pad press, in words.
  final String last;
  final String error;

  /// When this was written, ISO 8601.
  final String at;

  Json toJson() => {
    'running': running,
    'pid': pid,
    'apc': apc,
    'sx': sx,
    'page': page,
    'pageName': pageName,
    'pages': pages,
    'last': last,
    'error': error,
    'at': at,
  };
}

/// Everything the APC40 tab shows: `apc40.ps1 -Action Info`, plus the two
/// keys the old server adds (`windows`, `status`).
class Apc40Info {
  const Apc40Info({
    required this.show,
    required this.file,
    required this.layout,
    required this.buttons,
    required this.faders,
    required this.windows,
    required this.status,
  });

  factory Apc40Info.fromJson(Json j) => Apc40Info(
    show: j.str('show'),
    file: j.str('file'),
    layout: Apc40Layout.fromJson(j.obj('layout')),
    buttons: j.list('buttons', Apc40Button.fromJson),
    faders: j.list('faders', Apc40Fader.fromJson),
    windows: j.boolean('windows'),
    status: j.objOrNull('status') == null ? null : Apc40Status.fromJson(j.obj('status')),
  );

  /// The show folder's name.
  final String show;

  /// Where the layout is kept.
  final String file;
  final Apc40Layout layout;
  final List<Apc40Button> buttons;
  final List<Apc40Fader> faders;

  /// False on a Mac, where the APC40 bridge doesn't run.
  final bool windows;

  /// Null when the bridge never ran.
  final Apc40Status? status;

  Json toJson() => {
    'ok': true,
    'show': show,
    'file': file,
    'layout': layout.toJson(),
    'buttons': [for (final b in buttons) b.toJson()],
    'faders': [for (final f in faders) f.toJson()],
    'windows': windows,
    'status': status?.toJson(),
  };
}

/// The APC40 tab's calls.
extension Apc40Api on SxClient {
  Future<Apc40Info> apc40() => get('/api/apc40', Apc40Info.fromJson);

  /// The bridge's status, or null when it never ran.
  Future<Apc40Status?> apc40Status() => get('/api/apc40/status', (j) => j.objOrNull('status') == null ? null : Apc40Status.fromJson(j.obj('status')));

  /// Saves the layout and has the bridge load it. Answers like [apc40], with
  /// the layout as the engine cleaned it. A refusal throws `ApiException`.
  Future<Apc40Info> apc40Save(Apc40Layout layout) => post('/api/apc40/save', {'layout': layout.toJson()}, Apc40Info.fromJson);
}
