import 'client.dart';
import 'json.dart';

/// Whether the RIG ID scene and button are in the show.
class RtInstall {
  const RtInstall({required this.scene, required this.old, required this.button, required this.setupPage, required this.where});

  factory RtInstall.fromJson(Json j) =>
      RtInstall(scene: j.boolean('scene'), old: j.boolean('old'), button: j.boolean('button'), setupPage: j.integerOrNull('setupPage'), where: j.str('where'));

  /// True when `scenes/RIG ID.scex` exists.
  final bool scene;

  /// True when that scene is a version from before the looks were fixed.
  final bool old;

  /// True when a live button plays it.
  final bool button;

  /// The live page called SETUP, or null when there is none.
  final int? setupPage;

  /// Where the button is ("SETUP, line 1, column 3"), or ''.
  final String where;

  Json toJson() => {'scene': scene, 'old': old, 'button': button, 'setupPage': setupPage, 'where': where};
}

/// A 140SR and the look RIG ID gives it.
class RtHead {
  const RtHead({required this.id, required this.num, required this.label, required this.look, required this.hex, required this.flash});

  factory RtHead.fromJson(Json j) =>
      RtHead(id: j.str('id'), num: j.integer('num'), label: j.str('label'), look: j.str('look'), hex: j.str('hex'), flash: j.boolean('flash'));

  final String id;
  final int num;
  final String label;

  /// The color's name, for example "Deep red".
  final String look;

  /// The color as RRGGBB, for the swatch.
  final String hex;

  /// True for #9 to #16, which pulse.
  final bool flash;

  Json toJson() => {'id': id, 'num': num, 'label': label, 'look': look, 'hex': hex, 'flash': flash};
}

/// One mover position on a truss, for example the top left tower's right head.
class RtSlot {
  const RtSlot({required this.key, required this.tower, required this.towerName, required this.side, required this.x, required this.y, required this.extra});

  factory RtSlot.fromJson(Json j) => RtSlot(
    key: j.str('key'),
    tower: j.str('tower'),
    towerName: j.str('towerName'),
    side: j.str('side'),
    x: j.integer('x'),
    y: j.integer('y'),
    extra: j.boolean('extra'),
  );

  /// `tl-l`, `tl-r`, ... `bm-r`.
  final String key;

  /// `tl`, `tr`, `tm`, `bl`, `br` or `bm`.
  final String tower;
  final String towerName;

  /// 'left' or 'right'.
  final String side;

  /// Where the head's icon goes in the 2D view.
  final int x;
  final int y;

  /// True for the two middle towers, which only bigger events use.
  final bool extra;

  Json toJson() => {'key': key, 'tower': tower, 'towerName': towerName, 'side': side, 'x': x, 'y': y, 'extra': extra};
}

/// What the Rig Test screen shows.
class RtPreview {
  const RtPreview({
    required this.show,
    required this.saved,
    required this.extra,
    required this.install,
    required this.heads,
    required this.slots,
    required this.assign,
  });

  factory RtPreview.fromJson(Json j) => RtPreview(
    show: j.str('show'),
    saved: j.strOrNull('saved'),
    extra: j.boolean('extra'),
    install: RtInstall.fromJson(j.obj('install')),
    heads: j.list('heads', RtHead.fromJson),
    slots: j.list('slots', RtSlot.fromJson),
    assign: {for (final e in j.obj('assign').entries) e.key: '${e.value ?? ''}'},
  );

  final String show;

  /// When Rig Test was last saved (`2026-11-23T12:17:44`), or null.
  final String? saved;

  /// True when the two middle towers are in use.
  final bool extra;
  final RtInstall install;

  /// Every 140SR, by number.
  final List<RtHead> heads;
  final List<RtSlot> slots;

  /// Slot key to head id, read back from the 2D view.
  final Map<String, String> assign;

  Json toJson() => {
    'ok': true,
    'show': show,
    'saved': saved,
    'extra': extra,
    'install': install.toJson(),
    'heads': [for (final h in heads) h.toJson()],
    'slots': [for (final s in slots) s.toJson()],
    'assign': assign,
  };
}

extension RigTestApi on SxClient {
  Future<RtPreview> rt() => get('/api/rt', RtPreview.fromJson);

  /// Saves the heads' places to the 2D view. With [rig], Tonight's Rig and
  /// SKIP FLASH follow: heads not on a truss count as not hung.
  Future<ToolResult> rtApply(Map<String, String> assign, {required bool extra, required bool rig}) =>
      run('/api/rt/apply', {'assign': assign, 'extra': extra, 'rig': rig});

  /// Adds the RIG ID scene and its button on the SETUP page.
  Future<ToolResult> rtInstall() => run('/api/rt/install');
}
