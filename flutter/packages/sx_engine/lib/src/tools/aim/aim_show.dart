import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../../ps_compat.dart';
import '../../show/fixtures.dart';
import '../../show/live_ini.dart';
import '../../show/movers.dart';
import '../../show/show_env.dart';
import '../../show/text_files.dart';
import 'aim_math.dart';
import 'aim_state.dart';
import 'journal.dart';

/// Step 1 (center) and step 2 (corner) aims per head id, "as if hung normally".
class Aims {
  Aims(this.center, this.corner, {this.steps = 2, this.moved = 0});

  final Map<String, PanTilt> center;
  final Map<String, PanTilt> corner;

  /// Steps in the aim scene. 1 means an old scene without the corner step.
  final int steps;

  /// Room only: heads still on the old normal after AROUND ROOM was reshaped.
  final int moved;
}

/// A head that gets its T-bar partner's aim.
class PartnerCopy {
  const PartnerCopy({required this.from, required this.tower, required this.corner, required this.sized});

  /// The partner's id.
  final String from;
  final String tower;

  /// Step 2 was copied too.
  final bool corner;

  /// The copied corner sets a size.
  final bool sized;
}

/// One run of Aim Movers on a show: the settings for the mode, the movers,
/// the reversed heads and the state, plus the file work the actions share.
///
/// Construction is the top of `df_aim.ps1` (and its Room block), so it
/// refuses in the same order and with the same words.
class AimShow {
  AimShow(this.env, this.mode) {
    final root = env.root;
    if (!File('$root/Live/live.ini').existsSync()) throw ToolError("Show not found at '$root'. NOTHING was changed.");
    gdir = '$root/Editor/Generator/projects';
    if (mode == AimMode.room) {
      aimTitle = 'ROOM AIM (ADJUST)';
      checkTitle = 'ROOM CHECK';
      scene = '$root/scenes/ROOM AIM (ADJUST).scex';
      stateFile = '$root/room_aim_state.json';
      _setUpRoom();
    } else {
      aimTitle = 'DF AIM (ADJUST)';
      checkTitle = 'DF CHECK 140 / DF CHECK 251';
      scene = '$root/scenes/DF AIM (ADJUST).scex';
      stateFile = '$root/df_aim_state.json';
      homePos[model140] = (22600, 49700);
      homePos[model251] = (34200, 10000);
      refHalf[model140] = (3600, 3400);
      refHalf[model251] = (4500, 5000);
      checks['DF CHECK 140.gpj'] = model140;
      checks['DF CHECK 251.gpj'] = model251;
    }
    final all = showMovers(env);
    movers = mode == AimMode.room ? all.where((m) => _roomIds.any((i) => psEq(i, m.id))).toList() : all;
    if (movers.isEmpty) throw ToolError('No 140SR/251SR fixtures found.');
    flip = FlipState.read(env);
    st = AimState.load(stateFile);
  }

  final ShowEnv env;
  final AimMode mode;

  late final String gdir;

  /// The aim scene (DF AIM (ADJUST) or ROOM AIM (ADJUST)).
  late final String scene;
  late final String stateFile;
  late final String aimTitle;
  late final String checkTitle;

  /// Where the shapes are centered when the offsets are 0, by model (16-bit pan, tilt).
  final homePos = psMap<PanTilt>();

  /// Half the normal floor, center to corner, by model. A corner aimed exactly
  /// this far away is zoom 0.
  final refHalf = psMap<PanTilt>();

  /// The check movements (each head traces the floor's corners) and their model.
  final checks = psMap<String>();

  /// Never touched on the floor: not dance floor looks.
  static const skip = ['251 Ceiling', 'Around Room', 'Grand Entrance'];
  List<String> get noScale => mode == AimMode.room ? const ['ROOM CHECK*'] : const ['DF CHECK*'];
  static const noZoom = <String>[];

  /// Not mirror-symmetrical by design, so only moved back to its center.
  static const moveOnly = ['*GALAXY SPIRAL*'];
  bool get autoSym => mode == AimMode.floor;

  /// Step scenes rebuilt from a movement after every Apply and Home.
  static const rendered = {'GRAND ENTRANCE.gpj': 'GRAND ENTRANCE.scex'};

  late final List<Mover> movers;
  late final FlipState flip;
  late final AimState st;

  // Room mode
  var roomFiles = <String>[];
  var _roomIds = <String>[];

  /// Room: the normal before AROUND ROOM was reshaped in Generator, or null.
  (PanTilt, PanTilt)? roomPrev;

  /// Room mode's normal is the middle and half-size of the original AROUND
  /// ROOM shape. Port of the `if ($Mode -eq 'Room')` block.
  void _setUpRoom() {
    final dir = Directory(gdir);
    final names = dir.existsSync()
        ? dir.listSync().whereType<File>().map((f) => p.basename(f.path)).where((n) => n.toLowerCase().endsWith('.gpj'))
        : <String>[];
    roomFiles = psSorted<String>(names.where((n) => psLike(n, 'AROUND ROOM*') || psLike(n, 'GRAND ENTRANCE*')), [(n) => n]);
    if (roomFiles.isEmpty) throw ToolError('No AROUND ROOM movement found in Generator. NOTHING was changed.');
    final main = roomFiles.any((n) => psEq(n, 'AROUND ROOM.gpj')) ? 'AROUND ROOM.gpj' : roomFiles[0];
    final rt = readText('$gdir/$main');
    final cut = rt.split(RegExp(r'\[Pan/Tilt/uPan/uTilt\]', caseSensitive: false));
    final ptSec = (cut.length > 1 ? cut[1] : '').split(RegExp(r'\r?\n\[', caseSensitive: false))[0];
    final curS = RegExp(r'Point_\d+ = (-?\d+),(-?\d+)').allMatches(ptSec).map((m) => '${m[1]},${m[2]}').join(';');
    final rec = File(stateFile).existsSync() ? AimState.load(stateFile).shape(main) : null;
    final (PanTilt, PanTilt) mh;
    if (rec != null && psEq(rec.written, curS)) {
      mh = midHalf(textToPts(rec.base));
    } else {
      var cp = textToPts(curS);
      if (rec != null && (rec.sx != 1 || rec.sy != 1)) {
        final (c0, _) = midHalf(cp);
        cp = [for (final q in cp) (c0.$1 + (q.$1 - c0.$1) / rec.sx, c0.$2 + (q.$2 - c0.$2) / rec.sy)];
      }
      mh = midHalf(cp);
      if (rec != null) roomPrev = midHalf(textToPts(rec.base));
    }
    for (final m in [model140, model251]) {
      homePos[m] = mh.$1;
      refHalf[m] = mh.$2;
    }
    _roomIds = [for (final m in RegExp(r'^ID = (\d+)', multiLine: true).allMatches(rt)) m[1]!];
    checks['ROOM CHECK.gpj'] = model140;
  }

  /// Fails the way `df_aim.ps1` does while ShowXpress is open.
  void requireSxClosed() {
    if (env.sxRunning()) throw ToolError('ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and run this again.');
  }

  PanTilt home(Mover m) => homePos[m.model]!;

  /// Port of `Get-DefaultCorner`.
  PanTilt cornerOf(Mover m) => defaultCorner(homePos[m.model]!, refHalf[m.model]!);

  bool get sceneExists => File(scene).existsSync();

  /// Every head on home, no corner. Port of `Get-HomeAims`.
  Aims homeAims() => Aims({for (final m in movers) m.id: home(m)}, {for (final m in movers) m.id: cornerOf(m)});

  // ---------------------------------------------------------------- aim scene

  /// The aim look (tight white beam): (channel offset, name, value, fades).
  /// Port of `Get-AimChannels`.
  static List<(int, String, int, bool)> aimChannels(Mover m, int pan, int tilt) => [
    (0, 'pan', (pan / 256).floor(), true),
    (1, 'upan', pan.remainder(256), true),
    (2, 'tilt', (tilt / 256).floor(), true),
    (3, 'utilt', tilt.remainder(256), true),
    (4, 'pantilt_speed', 0, false),
    (5, 'color', 0, false),
    if (m.is140) ...[
      (6, 'gobo', 0, false),
      (7, 'gobo#2', 0, false),
      (8, 'gobo_rotate', 0, false),
      (9, '8 facet prism', 0, false),
      (10, 'linear prism', 0, false),
      (13, 'zoom', 243, false),
      (14, 'frost', 0, false),
    ] else ...[
      (6, 'gobo', 0, false),
      (7, 'gobo2', 0, false),
      (8, 'gobo_rotate', 0, false),
      (9, 'prism', 0, false),
      (10, 'prism2', 0, false),
      (11, 'focus', 38, false),
      (13, 'zoom', 255, false),
      (14, 'frost', 0, false),
    ],
    (15, 'dimmer', 255, false),
    (16, 'shutter', 255, false),
  ];

  /// Writes the aim scene: step 1 = [center], step 2 = [corner]. The file
  /// holds what goes out, so reversed heads are written reversed.
  /// Port of `Write-AimScene`.
  void writeAimScene(WriteJournal j, Map<String, PanTilt> center, Map<String, PanTilt> corner) {
    final l = <String>['<?xml version="1.0" encoding="UTF-8"?>', '', '<Scene>', '  <Fixtures>'];
    for (final m in movers) {
      l.add('    <Fixture id="${m.id}" name="${m.name}" model="${m.model}"/>');
    }
    l.addAll(['  </Fixtures>', '  <Steps>']);
    for (final pos in [center, corner]) {
      l.add('    <Step length="300">');
      for (final m in movers) {
        final sp = flip.sentPos(m.id, pos[m.id]!);
        l.add('      <Fixture id="${m.id}">');
        for (final (i, name, v, fade) in aimChannels(m, sp.$1, sp.$2)) {
          l.add('        <Channel index="$i" name="$name" value="$v"${fade ? ' fade="1"' : ''}/>');
        }
        l.add('      </Fixture>');
      }
      l.add('    </Step>');
    }
    l.addAll(['  </Steps>', '</Scene>']);
    j.write(scene, '${l.join('\n')}\n', bom: false);
  }

  /// Port of `Read-Step`: a head's 16-bit pan and tilt in [step], or [def].
  static PanTilt _readStep(XmlElement? step, Mover m, PanTilt def) {
    final v = psMap<int>()
      ..['pan'] = (def.$1 / 256).floor()
      ..['upan'] = def.$1.remainder(256)
      ..['tilt'] = (def.$2 / 256).floor()
      ..['utilt'] = def.$2.remainder(256);
    if (step != null) {
      final fx = step.findElements('Fixture').where((f) => psEq(f.getAttribute('id') ?? '', m.id));
      if (fx.isNotEmpty) {
        for (final c in fx.first.findElements('Channel')) {
          final cn = c.getAttribute('name') ?? '';
          if (v.containsKey(cn)) v[cn] = psInt(c.getAttribute('value') ?? '');
        }
      }
    }
    return (v['pan']! * 256 + v['upan']!, v['tilt']! * 256 + v['utilt']!);
  }

  /// Reads the aim scene. A head missing from a step keeps home (step 1) or
  /// the default corner (step 2). Port of `Read-AimScene`.
  Aims readAimScene() {
    if (!sceneExists) throw ToolError('Aim scene not found: $scene');
    final root = XmlDocument.parse(readText(scene)).rootElement;
    final steps = root.name.local == 'Scene' ? root.findElements('Steps').expand((s) => s.findElements('Step')).toList() : <XmlElement>[];
    // PowerShell's @($x.Scene.Steps.Step) is one $null when there is no step
    final count = steps.isEmpty ? 1 : steps.length;
    final center = <String, PanTilt>{}, corner = <String, PanTilt>{};
    var moved = 0;
    for (final m in movers) {
      center[m.id] = flip.sentPos(m.id, _readStep(steps.firstOrNull, m, flip.sentPos(m.id, home(m))));
      corner[m.id] = flip.sentPos(m.id, _readStep(count >= 2 ? steps[1] : null, m, flip.sentPos(m.id, cornerOf(m))));
      final prev = roomPrev;
      if (prev != null) {
        final (ph, pr) = prev;
        if (center[m.id] == ph) {
          center[m.id] = home(m);
          moved++;
        }
        if (corner[m.id] == (ph.$1 - pr.$1, ph.$2 + pr.$2)) corner[m.id] = cornerOf(m);
      }
    }
    return Aims(center, corner, steps: count, moved: moved);
  }

  /// The aims Preview and LiveInfo show: the scene's, or home when there is none.
  Aims currentAims() => sceneExists ? readAimScene() : homeAims();

  // ---------------------------------------------------------------- corrections

  /// Port of `Get-HeadFix` for every mover.
  Map<String, HeadFix> headFixes(Aims a, {bool reset = false}) => {
    for (final m in movers) m.id: headFix(home(m), refHalf[m.model]!, a.center[m.id]!, a.corner[m.id]!, reset: reset),
  };

  static bool _same(PanTilt? x, PanTilt? y) => x != null && y != null && x == y;

  /// Floor only: a head left on home (or on last time's copy) gets the aim of
  /// the head next to it on the same T-bar. Changes [a] in place and
  /// remembers the copies in the state. Port of `Add-PartnerAims`.
  Map<String, PartnerCopy> addPartnerAims(Aims a) {
    final res = <String, PartnerCopy>{};
    if (mode != AimMode.floor) return res;
    final pairs = trussPartners(env, movers);
    final byId = {for (final m in movers) m.id: m};
    final free = {for (final m in movers) m.id: _same(a.center[m.id], home(m)) || (st.copied[m.id] != null && _same(a.center[m.id], st.copied[m.id]!.c))};
    for (final m in movers) {
      final id = m.id;
      final pair = pairs[id];
      if (pair == null) continue;
      final src = pair.partner;
      if (!free[id]! || free[src]!) continue;
      final cp = st.copied[id];
      a.center[id] = a.center[src]!;
      final kFree = _same(a.corner[id], cornerOf(m)) || (cp != null && _same(a.corner[id], cp.k));
      if (kFree) a.corner[id] = a.corner[src]!;
      res[id] = PartnerCopy(from: src, tower: pair.tower, corner: kFree, sized: kFree && !_same(a.corner[src], cornerOf(byId[src]!)));
    }
    final keep = <String, CopiedAim>{};
    for (final m in movers) {
      final id = m.id, r = res[id], old = st.copied[id];
      if (r != null) {
        keep[id] = CopiedAim(c: a.center[id], k: r.corner ? a.corner[id] : null, from: r.from);
      } else if (old != null && _same(a.center[id], old.c)) {
        keep[id] = old;
      }
    }
    st.copied = keep;
    return res;
  }

  // ---------------------------------------------------------------- movements

  /// The movements Apply writes to. Floor: every `.gpj` on a live page named
  /// "...movement..." plus the checks, minus [skip]. Room: AROUND ROOM,
  /// GRAND ENTRANCE and ROOM CHECK. Port of `Get-TargetGpjs`.
  List<String> targetGpjs() {
    final checkNames = psSorted<String>(checks.keys, [(k) => k]);
    if (mode == AimMode.room) return _unique([...roomFiles, ...checkNames]);
    final lt = readLines('${env.root}/Live/live.ini');
    final pages = <String>[];
    String? pg;
    final pageHead = RegExp(r'^\[(page\d+)\]$', caseSensitive: false), name = RegExp(r'^name = (.*)$', caseSensitive: false);
    final movement = RegExp('movement', caseSensitive: false);
    for (final l in lt) {
      final h = pageHead.firstMatch(l);
      if (h != null) {
        pg = h[1];
        continue;
      }
      if (l.startsWith('[')) {
        pg = null;
        continue;
      }
      final n = name.firstMatch(l);
      if (pg != null && n != null && movement.hasMatch(n[1]!)) {
        pages.add(pg);
        pg = null;
      }
    }
    if (pages.isEmpty) throw ToolError('No MOVEMENTS page found in live.ini. NOTHING was changed.');
    final files = <String>[];
    final rx = RegExp('^\\[(${pages.join('|')})_button\\d+\\]\$', caseSensitive: false), gpj = RegExp(r'^name = (.+\.gpj)$', caseSensitive: false);
    var on = false;
    for (final l in lt) {
      if (l.startsWith('[')) {
        on = rx.hasMatch(l);
        continue;
      }
      final g = gpj.firstMatch(l);
      if (on && g != null) files.add(g[1]!);
    }
    files.addAll(checkNames);
    return _unique(files).where((f) => !likeAny(f, skip.map((s) => '$s*'))).toList();
  }

  /// `Select-Object -Unique`: the first of each, comparing with case.
  static List<String> _unique(Iterable<String> v) => v.toSet().toList();

  /// Writes offsets and zooms into every target movement and sizes its shape
  /// to [sx] x [sy] of the original. Returns the report lines.
  ///
  /// A shape changed in Generator since the last run becomes the new
  /// original (made symmetrical on the floor). Port of `Update-Gpjs`.
  List<String> updateGpjs(WriteJournal j, Map<String, HeadFix> fix, double sx, double sy) {
    final files = targetGpjs();
    final out = <String>[], warn = <String>[];
    var total = 0;
    final section = RegExp(r'^\[(.*)\]$'), point = RegExp(r'^(Point_\d+) = (-?\d+),(-?\d+)$', caseSensitive: false);
    final idLine = RegExp(r'^ID = (\d+)$', caseSensitive: false), reverse = RegExp(r'^Reverse(Pan|Tilt) = (\d+)$', caseSensitive: false);
    RegExp key(String k) => RegExp('^$k = ', caseSensitive: false);
    final offPan = key('OffsetPan'), offTilt = key('OffsetTilt'), zoomPan = key('ZoomPan'), zoomTilt = key('ZoomTilt');
    for (final f in files) {
      final path = '$gdir/$f';
      if (!File(path).existsSync()) {
        warn.add('missing: $f');
        continue;
      }
      final useZoom = !likeAny(f, noZoom), scaleThis = !likeAny(f, noScale);
      final bom = hasBom(File(path).readAsBytesSync());
      final text = readText(path);
      final nl = text.contains('\r\n') ? '\r\n' : '\n';
      final lines = text.split(RegExp(r'\r?\n'));
      String? id, firstId;
      var sec = '';
      var n = 0;
      final ptIdx = <int>[], ptNames = <String>[];
      final cur = <Pt>[];
      for (var i = 0; i < lines.length; i++) {
        final ln = lines[i];
        final s = section.firstMatch(ln);
        if (s != null) {
          sec = s[1]!;
          id = null;
          continue;
        }
        final pm = psEq(sec, 'Pan/Tilt/uPan/uTilt') ? point.firstMatch(ln) : null;
        if (pm != null) {
          ptIdx.add(i);
          ptNames.add(pm[1]!);
          cur.add((double.parse(pm[2]!), double.parse(pm[3]!)));
          continue;
        }
        final im = idLine.firstMatch(ln);
        if (im != null) {
          id = im[1];
          firstId ??= id;
          continue;
        }
        final hf = id == null ? null : fix[id];
        if (hf == null) continue;
        String? nw;
        final rv = reverse.firstMatch(ln);
        if (rv != null) {
          // should match the heads SX Studio reverses, else it was changed in Generator
          final fl = flip.heads[id];
          final on = fl != null && (rv[1]!.toLowerCase() == 'pan' ? fl.pan : fl.tilt);
          final state = on ? 'OFF but SX Studio reverses that head' : 'on';
          if ((rv[2] != '0') != on) warn.add('$f : fixture $id has Reverse${rv[1]} $state - check that head by eye');
        }
        if (offPan.hasMatch(ln)) nw = 'OffsetPan = ${hf.op}';
        if (offTilt.hasMatch(ln)) nw = 'OffsetTilt = ${hf.ot}';
        if (zoomPan.hasMatch(ln)) nw = 'ZoomPan = ${useZoom ? hf.zp : 0}';
        if (zoomTilt.hasMatch(ln)) nw = 'ZoomTilt = ${useZoom ? hf.zt : 0}';
        if (nw != null && !psEq(ln, nw)) {
          lines[i] = nw;
          n++;
        }
      }
      // ---- overall size of the shared shape
      var note = '';
      if (cur.length >= 2) {
        final curS = ptsToText(cur);
        final rec = st.shape(f);
        List<Pt> base;
        if (rec != null && psEq(rec.written, curS)) {
          base = textToPts(rec.base);
        } else {
          // shape changed in Generator since the last run (or a scene the tool hasn't seen yet)
          base = rec != null && (rec.sx != 1 || rec.sy != 1) ? scalePts(cur, 1 / rec.sx, 1 / rec.sy) : cur;
          final model = movers.where((m) => firstId != null && psEq(m.id, firstId)).firstOrNull?.model;
          final checkModel = checks[f];
          if (checkModel != null) {
            if (cur.length == 4) {
              // a check movement is always the exact reference floor
              final h = homePos[checkModel]!, r = refHalf[checkModel]!;
              base = _corners(h, r);
              if (rec != null) note = ' (changed in Generator -> reset)';
            }
          } else if (autoSym && model != null) {
            final sym = symShape(base, homePos[model]!, rec != null ? textToPts(rec.base) : null, likeAny(f, moveOnly));
            base = sym.pts;
            note = sym.note;
          } else if (rec != null) {
            note = ' (your shape edit kept)';
          }
          if (rec == null && note.isEmpty) note = ' (new scene)';
        }
        final fx = scaleThis ? sx : 1.0, fy = scaleThis ? sy : 1.0;
        var newPts = fx == 1 && fy == 1 ? base : scalePts(base, fx, fy);
        var clip = false;
        newPts = [
          for (final q in newPts)
            () {
              final x = psRound(q.$1), y = psRound(q.$2);
              if (x < 0 || x > 65535 || y < 0 || y > 65535) clip = true;
              return (x.clamp(0, 65535).toDouble(), y.clamp(0, 65535).toDouble());
            }(),
        ];
        if (clip) warn.add('$f : pattern hit the pan/tilt limit at this size - edges flattened');
        for (var k = 0; k < ptIdx.length; k++) {
          final nw = '${ptNames[k]} = ${newPts[k].$1.toInt()},${newPts[k].$2.toInt()}';
          if (!psEq(lines[ptIdx[k]], nw)) {
            lines[ptIdx[k]] = nw;
            n++;
          }
        }
        st.setShape(f, ShapeRecord(base: ptsToText(base), written: ptsToText(newPts), sx: fx, sy: fy));
      }
      if (!useZoom) {
        note += ' (aim only)';
      } else if (!scaleThis) {
        note += ' (aim + per-head size)';
      }
      if (n > 0) j.write(path, lines.join(nl), bom: bom);
      total += n;
      out.add('  ${f.padRight(46)} ${'$n'.padLeft(3)} values changed$note');
    }
    out.add('  -> ${files.length} movement scenes checked, $total values written');
    for (final w in _unique(warn)) {
      out.add('  WARNING: $w');
    }
    return out;
  }

  /// The normal floor's four corners, front-left first.
  static List<Pt> _corners(PanTilt h, PanTilt r) => [
    ((h.$1 - r.$1).toDouble(), (h.$2 + r.$2).toDouble()),
    ((h.$1 + r.$1).toDouble(), (h.$2 + r.$2).toDouble()),
    ((h.$1 + r.$1).toDouble(), (h.$2 - r.$2).toDouble()),
    ((h.$1 - r.$1).toDouble(), (h.$2 - r.$2).toDouble()),
  ];

  /// The `[Fixture_N]` sections of a movement, each as its non-empty lines.
  /// Port of `Get-FixtureSections`.
  static List<List<String>> _fixtureSections(String file) {
    final res = <List<String>>[];
    List<String>? buf;
    final fixture = RegExp(r'^\[Fixture_\d+\]$', caseSensitive: false);
    for (final l in readText(file).split(RegExp(r'\r?\n'))) {
      if (l.startsWith('[')) {
        if (buf != null) res.add(buf);
        buf = fixture.hasMatch(l) ? [l] : null;
        continue;
      }
      if (buf != null && l.isNotEmpty) buf.add(l);
    }
    if (buf != null) res.add(buf);
    return res;
  }

  /// Creates a check movement when it is missing: every head of [model]
  /// traces the four corners of the normal floor, one second each. The head
  /// sections are copied from another movement. Port of `New-CheckGpj`.
  String? newCheckGpj(WriteJournal j, String name, String model) {
    final path = '$gdir/$name';
    if (File(path).existsSync()) return null;
    final secs = <String, List<String>>{};
    final gpjs = psSorted<File>(Directory(gdir).listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.gpj')), [(f) => p.basename(f.path)]);
    final idLine = RegExp(r'^ID = ', caseSensitive: false);
    for (final f in gpjs) {
      for (final s in _fixtureSections(f.path)) {
        final ids = s.where(idLine.hasMatch).toList();
        if (ids.length != 1) continue;
        final id = ids[0].replaceFirst(idLine, '');
        if (id.isNotEmpty && !secs.containsKey(id)) secs[id] = s;
      }
    }
    final out = ['[Params]', 'PanTiltShift = 0.0', 'ExplodePanTilt = 0', 'GroupRGB = 0', 'FanPanOffset = 0', 'FanTiltOffset = 0'];
    var k = 0;
    List<String>? chList;
    final fixture = RegExp(r'^\[Fixture_', caseSensitive: false), offZoom = RegExp(r'^(Offset|Zoom)(Pan|Tilt) = ', caseSensitive: false);
    final reverse = RegExp(r'^Reverse(Pan|Tilt) = ', caseSensitive: false), channels = RegExp(r'^Channels = (.*)$', caseSensitive: false);
    for (final m in movers.where((m) => psEq(m.model, model))) {
      final s = secs[m.id];
      if (s == null) throw ToolError('No generator template found for ${m.name}');
      for (var l in s) {
        final rv = reverse.firstMatch(l), ch = channels.firstMatch(l);
        if (fixture.hasMatch(l)) {
          l = '[Fixture_$k]';
        } else if (offZoom.hasMatch(l)) {
          l = l.replaceAll(RegExp(r'= .*$'), '= 0');
        } else if (rv != null) {
          final fl = flip.heads[m.id];
          final on = fl != null && (rv[1]!.toLowerCase() == 'pan' ? fl.pan : fl.tilt);
          l = 'Reverse${rv[1]} = ${on ? 1 : 0}';
        } else if (ch != null && chList == null) {
          chList = ch[1]!.split(',');
        }
        out.add(l);
      }
      k++;
    }
    final pts = _corners(homePos[model]!, refHalf[model]!);
    out.addAll(['[Pan/Tilt/uPan/uTilt]', 'Selected = 1', 'CurveName = Default Curve', 'Transition = 0', 'Duration = 40', 'Shift = 0.0']);
    for (var i = 0; i < 4; i++) {
      out.add('Point_$i = ${pts[i].$1.toInt()},${pts[i].$2.toInt()}');
    }
    final fixed = psMap<int>()
      ..addAll({
        'pantilt_speed': 0,
        'color': 0,
        'gobo': 0,
        'gobo#2': 0,
        'gobo2': 0,
        'gobo_rotate': 0,
        '8 facet prism': 0,
        'linear prism': 0,
        'prism': 0,
        'prism2': 0,
        'frost': 0,
        'dimmer': 65535,
        'shutter': 65535,
      });
    if (psEq(model, model140)) {
      fixed['zoom'] = 62451;
    } else {
      fixed['zoom'] = 65535;
      fixed['focus'] = 9766;
    }
    for (final c in (chList ?? const <String>[]).where((c) => !['pan', 'upan', 'tilt', 'utilt'].any((x) => psEq(x, c)))) {
      out.add('[$c]');
      final v = fixed[c];
      out.addAll(
        v != null
            ? ['Selected = 1', 'CurveName = Default Curve', 'Transition = 0', 'Duration = 50', 'Shift = 0.0', 'Point_0 = 0,$v', 'Point_1 = 65535,$v']
            : ['Selected = 0', 'CurveName = Default Curve', 'Transition = 0', 'Duration = 50', 'Shift = 0.0', 'Point_0 = 0,65535', 'Point_1 = 65535,65535'],
      );
    }
    j.write(path, '${out.join('\n')}\n', bom: true);
    return '  created $name ($k heads)';
  }

  // ---------------------------------------------------------------- other scenes

  /// CENTER SPOT follows step 1: every head aimed in step 1 gets that aim as
  /// its pan and tilt. Only those four channels change, a missing one is
  /// added, and heads still on home are left alone. Port of `Update-CenterSpot`.
  String updateCenterSpot(WriteJournal j, Map<String, PanTilt> center) {
    var cs = '${env.root}/scenes/CENTER SPOT.scex';
    if (!File(cs).existsSync()) cs = '${env.root}/scenes/CENTER SPOT (adjust).scex';
    if (!File(cs).existsSync()) return '  WARNING: scene CENTER SPOT not found - not updated';
    final want = <String, Map<int, (String, int)>>{};
    for (final m in movers) {
      final c = center[m.id]!;
      if (c == home(m)) continue; // not aimed in step 1
      final (pan, tilt) = flip.sentPos(m.id, c);
      want[m.id] = {0: ('pan', (pan / 256).floor()), 1: ('upan', pan.remainder(256)), 2: ('tilt', (tilt / 256).floor()), 3: ('utilt', tilt.remainder(256))};
    }
    final bom = hasBom(File(cs).readAsBytesSync());
    final text = readText(cs);
    final nl = text.contains('\r\n') ? '\r\n' : '\n';
    final out = <String>[];
    final stepsOpen = RegExp(r'^\s*<Steps>', caseSensitive: false), stepsClose = RegExp(r'^\s*</Steps>', caseSensitive: false);
    final fxOpen = RegExp(r'^\s*<Fixture id="(\d+)">\s*$', caseSensitive: false), fxClose = RegExp(r'^\s*</Fixture>', caseSensitive: false);
    final chLine = RegExp(r'^(\s*)<Channel index="(\d+)"', caseSensitive: false), chAny = RegExp(r'<Channel index="(\d+)"', caseSensitive: false);
    final value = RegExp(r'value="\d+"', caseSensitive: false);
    var inSteps = false;
    List<String>? blk;
    String? bid;
    var n = 0;
    final heads = <String>{};
    for (final ln in text.split(RegExp(r'\r?\n'))) {
      if (stepsOpen.hasMatch(ln)) inSteps = true;
      final fo = inSteps && blk == null ? fxOpen.firstMatch(ln) : null;
      if (fo != null) {
        bid = fo[1];
        blk = [ln];
        continue;
      }
      if (blk != null) {
        if (!fxClose.hasMatch(ln)) {
          blk.add(ln);
          continue;
        }
        final w = want[bid];
        if (w != null) {
          final seen = <int>{};
          var ind = '        ';
          for (var i = 1; i < blk.length; i++) {
            final cm = chLine.firstMatch(blk[i]);
            if (cm == null) continue;
            ind = cm[1]!;
            final ix = int.parse(cm[2]!);
            final wv = w[ix];
            if (wv == null) continue;
            seen.add(ix);
            final nw = blk[i].replaceAll(value, 'value="${wv.$2}"');
            if (!psEq(nw, blk[i])) {
              blk[i] = nw;
              n++;
              heads.add(bid!);
            }
          }
          for (final ix in [0, 1, 2, 3]) {
            if (seen.contains(ix)) continue;
            // insert in index order
            var at = blk.length;
            for (var i = 1; i < blk.length; i++) {
              final cm = chAny.firstMatch(blk[i]);
              if (cm != null && int.parse(cm[1]!) > ix) {
                at = i;
                break;
              }
            }
            blk.insert(at, '$ind<Channel index="$ix" name="${w[ix]!.$1}" value="${w[ix]!.$2}" fade="1"/>');
            n++;
            heads.add(bid!);
          }
        }
        out
          ..addAll(blk)
          ..add(ln);
        blk = null;
        continue;
      }
      if (stepsClose.hasMatch(ln)) inSteps = false;
      out.add(ln);
    }
    if (n > 0) j.write(cs, out.join(nl), bom: bom);
    final note = want.isEmpty
        ? ' (no head aimed in step 1 - left as it was)'
        : n == 0
        ? " (already on tonight's step-1 center)"
        : " (${heads.length} of ${want.length} aimed heads moved to tonight's step-1 center)";
    return '  ${'CENTER SPOT (spot scene)'.padRight(46)} ${'$n'.padLeft(3)} values changed$note';
  }

  /// GRAND ENTRANCE is a step scene that moves like GRAND ENTRANCE.gpj (so it
  /// can have a color per head). Its pan and tilt steps are rebuilt from the
  /// movement: shape plus each head's offset and zoom. Step 1 is the template
  /// for every other channel. A mover not in the movement keeps its step 1
  /// aim. Port of `Update-RenderedScenes`.
  List<String> updateRenderedScenes(WriteJournal j) {
    final out = <String>[];
    for (final g in psSorted<String>(rendered.keys, [(k) => k])) {
      final gp = '$gdir/$g', sp = '${env.root}/scenes/${rendered[g]}';
      final label = '${rendered[g]!.replaceAll(RegExp(r'\.scex$', caseSensitive: false), '')} (step scene)';
      if (!File(gp).existsSync() || !File(sp).existsSync()) continue;
      final gt = readText(gp).replaceAll('\r\n', '\n');
      final cut = gt.split(RegExp(r'\[Pan/Tilt/uPan/uTilt\]\n', caseSensitive: false));
      final ptSec = (cut.length > 1 ? cut[1] : '').split(RegExp(r'\n\[', caseSensitive: false))[0];
      final pts = [for (final m in RegExp(r'^Point_\d+ = (-?\d+),(-?\d+)$', multiLine: true).allMatches(ptSec)) (double.parse(m[1]!), double.parse(m[2]!))];
      if (pts.length < 2) {
        out.add('  WARNING: $g has no movement shape - $label not rebuilt');
        continue;
      }
      final trm = RegExp(r'^Transition = (\d+)', multiLine: true, caseSensitive: false).firstMatch(ptSec);
      final tr = trm == null ? 2 : int.parse(trm[1]!);
      final dum = RegExp(r'^Duration = (\d+)', multiLine: true, caseSensitive: false).firstMatch(ptSec);
      final dur = dum == null ? 200 : int.parse(dum[1]!); // 1/10 s
      final xs = pts.map((q) => q.$1), ys = pts.map((q) => q.$2);
      final cx = (xs.reduce((a, b) => a < b ? a : b) + xs.reduce((a, b) => a > b ? a : b)) / 2;
      final cy = (ys.reduce((a, b) => a < b ? a : b) + ys.reduce((a, b) => a > b ? a : b)) / 2;
      final hf = <String, Map<String, double>>{};
      for (final blk in gt.split(RegExp(r'\n(?=\[Fixture_\d+\])', caseSensitive: false))) {
        final im = RegExp(r'^ID = (\d+)$', multiLine: true, caseSensitive: false).firstMatch(blk);
        if (im == null) continue;
        hf[im[1]!] = {
          for (final k in ['OffsetPan', 'OffsetTilt', 'ZoomPan', 'ZoomTilt', 'ReversePan', 'ReverseTilt'])
            k: double.parse(RegExp('^$k = (-?\\d+)', multiLine: true, caseSensitive: false).firstMatch(blk)?[1] ?? '0'),
        };
      }
      final path = curvePath(pts, tr);
      final len = math.max(1, psRound(dur * 10 / path.length));
      final bom = hasBom(File(sp).readAsBytesSync());
      final text = readText(sp);
      final nl = text.contains('\r\n') ? '\r\n' : '\n';
      final m1 = RegExp(r'^(.*?<Steps>[^\n]*\n)(.*?)(\r?\n[ \t]*</Steps>.*)$', dotAll: true).firstMatch(text);
      final s1 = RegExp(r'^([ \t]*)<Step length="\d+">\r?\n(.*?)\r?\n[ \t]*</Step>', dotAll: true).firstMatch(m1?[2] ?? '');
      if (m1 == null || s1 == null) {
        out.add('  WARNING: $label - could not read step 1, not rebuilt');
        continue;
      }
      final ind = s1[1]!;
      final channel = RegExp('<Channel ', caseSensitive: false), panTilt = RegExp(r'<Channel index="[0-3]" name="u?(pan|tilt)"', caseSensitive: false);
      final tmpl = [
        for (final f in RegExp(r'([ \t]*)<Fixture id="(\d+)">\r?\n(.*?)\r?\n[ \t]*</Fixture>', dotAll: true).allMatches(s1[2]!))
          () {
            final lines = f[3]!.split(RegExp(r'\r?\n'));
            return (
              ind: f[1]!,
              id: f[2]!,
              all: lines.where(channel.hasMatch).toList(),
              ch: lines.where((l) => channel.hasMatch(l) && !panTilt.hasMatch(l)).toList(),
            );
          }(),
      ];
      final fade = tr == 0 ? '' : ' fade="1"', chInd = '$ind    ';
      final o = <String>[];
      for (final pos in path) {
        o.add('$ind<Step length="$len">');
        for (final f in tmpl) {
          o.add('${f.ind}<Fixture id="${f.id}">');
          final h = hf[f.id];
          if (h != null) {
            final zp = _pow2(1 + h['ZoomPan']! / 100), zt = _pow2(1 + h['ZoomTilt']! / 100); // measured 2026-11-18
            var pv = cx + (pos.$1 - cx) * zp + h['OffsetPan']!, tv = cy + (pos.$2 - cy) * zt + h['OffsetTilt']!;
            if (h['ReversePan'] != 0) pv = 65535 - pv;
            if (h['ReverseTilt'] != 0) tv = 65535 - tv;
            final p16 = psRound(pv).clamp(0, 65535), t16 = psRound(tv).clamp(0, 65535);
            o
              ..add('$chInd<Channel index="0" name="pan" value="${p16 ~/ 256}"$fade/>')
              ..add('$chInd<Channel index="1" name="upan" value="${p16 % 256}"$fade/>')
              ..add('$chInd<Channel index="2" name="tilt" value="${t16 ~/ 256}"$fade/>')
              ..add('$chInd<Channel index="3" name="utilt" value="${t16 % 256}"$fade/>');
          } else {
            // a still mover: its own step-1 pan/tilt
            for (final c in f.all) {
              if (!f.ch.any((x) => psEq(x, c))) o.add(c);
            }
          }
          o
            ..addAll(f.ch)
            ..add('${f.ind}</Fixture>');
        }
        o.add('$ind</Step>');
      }
      final moved = tmpl.where((t) => hf.containsKey(t.id)).length;
      final still = tmpl.where((t) => !hf.containsKey(t.id) && t.ch.length < t.all.length).length;
      final eol = RegExp(r'\r?\n');
      final nw = '${m1[1]}${o.join(nl).replaceAll(eol, nl)}${m1[3]}'.replaceAll(eol, nl);
      final same = psEq(nw, text);
      if (!same) j.write(sp, nw, bom: bom);
      out.add(
        '  ${label.padRight(46)} ${same ? 'already up to date' : 'REBUILT'} (${path.length} steps x $len/100 s, $moved heads moving'
        '${still > 0 ? ', $still still on their step-1 aim' : ''}, step 1 copied to every step)',
      );
    }
    return out;
  }

  /// `[Math]::Pow(x, 2)`, through the C library like .NET.
  static double _pow2(double x) => math.pow(x, 2).toDouble();

  // ---------------------------------------------------------------- room buttons

  /// Room: are ROOM AIM (ADJUST) and ROOM CHECK on a live page. Port of `Get-RoomSetup`.
  RoomSetup roomSetup() {
    final info = LiveInfo.read(env);
    return RoomSetup(aim: info.buttons.any((b) => psEq(b.name, 'ROOM AIM (ADJUST).scex')), check: info.buttons.any((b) => psEq(b.name, 'ROOM CHECK.gpj')));
  }

  /// Puts ROOM AIM (ADJUST) (column 1) and ROOM CHECK (column 2) on the SETUP
  /// page when they are missing. Port of `Install-RoomButtons`.
  List<String> installRoomButtons(WriteJournal j) {
    final ini = LiveIni.read(env);
    final before = readText(ini.path);
    var info = LiveInfo.read(env, ini);
    int? pg;
    info.pages.forEach((k, name) {
      if (psEq(name.trim(), 'SETUP')) pg = k;
    });
    final page = pg;
    if (page == null) throw ToolError('No live page called SETUP found. NOTHING was changed.');
    final out = <String>[];
    for (final (scene, title, col) in [('ROOM AIM (ADJUST).scex', 'ROOM AIM (ADJUST)', 1), ('ROOM CHECK.gpj', 'ROOM CHECK', 2)]) {
      if (info.buttons.any((b) => psEq(b.name, scene))) continue;
      final cell = addLiveButton(ini, info, page, scene, title, cols: [col, for (var c = 4; c <= 10; c++) c], down: true);
      info = LiveInfo.read(env, ini);
      out.add('  CHANGED  added $title to the SETUP page (line ${cell.$1}, column ${cell.$2})');
    }
    final text = ini.lines.join(ini.nl);
    if (!psEq(text, before)) j.write(ini.path, text, bom: ini.bom);
    return out;
  }
}
