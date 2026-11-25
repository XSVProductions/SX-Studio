import 'client.dart';
import 'json.dart';

/// Which looks Aim Movers fits: the dance floor movements, or AROUND ROOM.
enum AimMode {
  floor('Floor', 'DF AIM (ADJUST)'),
  room('Room', 'ROOM AIM (ADJUST)');

  const AimMode(this.title, this.aimTitle);

  /// How the old tool writes the mode (`-Mode Floor|Room`).
  final String title;

  /// The ShowXpress scene the user aims in.
  final String aimTitle;

  /// The body value the old routes take (`"mode":"room"`, anything else is the floor).
  static AimMode fromWire(String s) => s.toLowerCase() == 'room' ? room : floor;
}

/// One head's correction as Aim Movers works it out from the aim scene.
class AimHeadFix {
  const AimHeadFix({
    required this.label,
    required this.is140,
    required this.op,
    required this.ot,
    required this.sized,
    required this.copyFrom,
    required this.kp,
    required this.kt,
    required this.zp,
    required this.zt,
    required this.warn,
  });

  factory AimHeadFix.fromJson(Json j) => AimHeadFix(
    label: j.str('label'),
    is140: j.boolean('is140'),
    op: j.integer('op'),
    ot: j.integer('ot'),
    sized: j.boolean('sized'),
    copyFrom: j.str('copyFrom'),
    kp: j.integer('kp'),
    kt: j.integer('kt'),
    zp: j.integer('zp'),
    zt: j.integer('zt'),
    warn: j.str('warn'),
  );

  /// "140 #3".
  final String label;
  final bool is140;

  /// OffsetPan / OffsetTilt: where step 1 aims, minus home (16-bit steps).
  final int op;
  final int ot;

  /// True when step 2 sets this head's own size.
  final bool sized;

  /// Label of the T-bar partner whose aim this head gets, or ''.
  final String copyFrom;

  /// Size from the corner, in percent of the normal floor (width, depth).
  final int kp;
  final int kt;

  /// ZoomPan / ZoomTilt written to the movements.
  final int zp;
  final int zt;

  /// Why this head's aim looks wrong, or ''.
  final String warn;

  bool get moved => op != 0 || ot != 0;

  Json toJson() => {
    'label': label,
    'is140': is140,
    'op': op,
    'ot': ot,
    'sized': sized,
    'copyFrom': copyFrom,
    'kp': kp,
    'kt': kt,
    'zp': zp,
    'zt': zt,
    'warn': warn,
  };
}

/// Room mode only: whether ROOM AIM (ADJUST) and ROOM CHECK are on the SETUP page.
class RoomSetup {
  const RoomSetup({required this.aim, required this.check});

  factory RoomSetup.fromJson(Json j) => RoomSetup(aim: j.boolean('aim'), check: j.boolean('check'));

  final bool aim;
  final bool check;

  Json toJson() => {'aim': aim, 'check': check};
}

/// What the Aim Movers screen shows. `GET /api/preview[?mode=room]`.
class AimPreview {
  const AimPreview({
    required this.show,
    required this.lastW,
    required this.lastD,
    required this.sceneExists,
    required this.heads,
    required this.mode,
    required this.aimTitle,
    required this.checkTitle,
    required this.install,
    required this.targets,
  });

  factory AimPreview.fromJson(Json j) => AimPreview(
    show: j.str('show'),
    lastW: j.integer('lastW'),
    lastD: j.integer('lastD'),
    sceneExists: j.boolean('sceneExists'),
    heads: j.list('heads', AimHeadFix.fromJson),
    mode: j.str('mode'),
    aimTitle: j.str('aimTitle'),
    checkTitle: j.str('checkTitle'),
    install: j.objOrNull('install') == null ? null : RoomSetup.fromJson(j.obj('install')),
    targets: j.strList('targets'),
  );

  final String show;

  /// Overall size last applied, in percent.
  final int lastW;
  final int lastD;
  final bool sceneExists;
  final List<AimHeadFix> heads;

  /// 'Floor' or 'Room', as the old tool writes it.
  final String mode;
  final String aimTitle;
  final String checkTitle;

  /// Null on the floor.
  final RoomSetup? install;

  /// The movements Apply writes to, without `.gpj`.
  final List<String> targets;

  Json toJson() => {
    'ok': true,
    'show': show,
    'lastW': lastW,
    'lastD': lastD,
    'sceneExists': sceneExists,
    'heads': [for (final h in heads) h.toJson()],
    'mode': mode,
    'aimTitle': aimTitle,
    'checkTitle': checkTitle,
    'install': install?.toJson(),
    'targets': targets,
  };
}

extension AimApi on SxClient {
  Future<AimPreview> aimPreview(AimMode mode) => get('/api/preview', AimPreview.fromJson, query: mode == AimMode.room ? const {'mode': 'room'} : null);

  /// Apply tonight's aims at width [w] and depth [d] percent. [force] applies
  /// even when some aims look wrong.
  Future<ToolResult> aimApply(AimMode mode, {required int w, required int d, bool force = false}) =>
      run('/api/apply', {'w': w, 'd': d, 'force': force, 'mode': mode.name});

  /// Every correction off and size back to 100.
  Future<ToolResult> aimHome(AimMode mode) => run('/api/home', {'mode': mode.name});

  /// Puts ROOM AIM (ADJUST) and ROOM CHECK on the SETUP page.
  Future<ToolResult> aimInstall() => run('/api/aim/install');
}
