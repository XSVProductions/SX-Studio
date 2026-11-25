import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/movers.dart';
import '../../show/show_env.dart';
import '../../show/text_files.dart';
import 'aim_math.dart';
import 'aim_show.dart';
import 'journal.dart';

// AIM MOVERS: fit the movement scenes to tonight's venue. The user aims every
// head at the center of the floor (step 1 of DF AIM (ADJUST)) and optionally
// at its front-left corner (step 2). Apply turns that into per-head
// OffsetPan/OffsetTilt and ZoomPan/ZoomTilt in every dance floor movement,
// sizes the shared shapes, points CENTER SPOT at step 1 and rebuilds the
// GRAND ENTRANCE step scene. Room mode does the same for AROUND ROOM.
//
// Port of `df_aim.ps1` (every action but the console menu).

/// What the Aim Movers screen shows. Writes nothing. Port of `-Action Preview`.
AimPreview aimPreview(ShowEnv env, AimMode mode) {
  final s = AimShow(env, mode);
  final a = s.currentAims();
  final byId = {for (final m in s.movers) m.id: m};
  final copies = s.addPartnerAims(a);
  final fix = s.headFixes(a);
  return AimPreview(
    show: env.root,
    lastW: psRound(s.st.sx * 100),
    lastD: psRound(s.st.sy * 100),
    sceneExists: s.sceneExists,
    heads: [
      for (final m in s.movers)
        AimHeadFix(
          label: m.label,
          is140: m.is140,
          op: fix[m.id]!.op,
          ot: fix[m.id]!.ot,
          sized: fix[m.id]!.sized,
          copyFrom: copies[m.id] == null ? '' : byId[copies[m.id]!.from]!.label,
          kp: psRound(fix[m.id]!.kp * 100),
          kt: psRound(fix[m.id]!.kt * 100),
          zp: fix[m.id]!.zp,
          zt: fix[m.id]!.zt,
          warn: fix[m.id]!.warn,
        ),
    ],
    mode: mode.title,
    aimTitle: s.aimTitle,
    checkTitle: s.checkTitle,
    install: mode == AimMode.room ? s.roomSetup() : null,
    targets: [for (final t in s.targetGpjs()) t.replaceAll(RegExp(r'\.gpj$', caseSensitive: false), '')],
  );
}

/// Everything the live aim screen needs to drive the heads itself: DMX
/// addresses, the aim look, current aims, truss seats. Writes nothing.
/// Port of `-Action LiveInfo`.
LiveAimInfo aimLiveInfo(ShowEnv env, AimMode mode) {
  final s = AimShow(env, mode);
  final a = s.currentAims();
  final addr = <String, int>{};
  Map<String, Object>? cur;
  final address = RegExp(r'^address = (\d+)', caseSensitive: false), idLine = RegExp(r'^id = (\d+)', caseSensitive: false);
  for (final l in readLines('${env.root}/fixtures.ini')) {
    if (l.startsWith('[')) {
      cur = {};
      continue;
    }
    if (cur == null) continue;
    final am = address.firstMatch(l), im = idLine.firstMatch(l);
    if (am != null) cur['a'] = int.parse(am[1]!);
    if (im != null) cur['id'] = im[1]!;
    final id = cur['id'], ad = cur['a'];
    if (id is String && ad is int && ad != 0) addr[id] = ad;
  }
  final seats = trussSeats(env, s.movers);
  final pairs = mode == AimMode.floor ? trussPartners(env, s.movers) : const <String, ({String partner, String tower})>{};
  final hung = _hung(env);
  final deg = psMap<PanTilt>();
  for (final mo in [model140, model251]) {
    var d = (540, 270);
    final fp = env.file('fixtures/$mo.txt');
    if (fp.existsSync()) {
      for (final l in readLines(fp.path)) {
        final pm = RegExp(r'^ViewAnglePan = (\d+)', caseSensitive: false).firstMatch(l);
        if (pm != null) d = (int.parse(pm[1]!), d.$2);
        final tm = RegExp(r'^ViewAngleTilt = (\d+)', caseSensitive: false).firstMatch(l);
        if (tm != null) d = (d.$1, int.parse(tm[1]!));
      }
    }
    deg[mo] = d;
  }
  return LiveAimInfo(
    show: env.root,
    mode: mode.title,
    aimTitle: s.aimTitle,
    heads: [
      for (final m in s.movers)
        if (addr.containsKey(m.id)) // not patched (an old scene entry)
          () {
            final c = a.center[m.id]!, k = a.corner[m.id]!, dk = s.cornerOf(m), hp = s.home(m), cp = s.st.copied[m.id];
            final se = seats[m.id];
            final fl = s.flip.heads[m.id];
            return LiveHead(
              id: m.id,
              label: m.label,
              is140: m.is140,
              addr: addr[m.id]!,
              look: [
                for (final (i, _, v, _) in AimShow.aimChannels(m, 0, 0))
                  if (i > 3) (i, v),
              ],
              dimI: 15,
              shutI: 16,
              c: c,
              k: k,
              home: hp,
              dk: dk,
              kSet: k != dk,
              free: c == hp || (cp != null && cp.c == c),
              partner: pairs[m.id]?.partner ?? '',
              tower: se?.tower ?? '',
              side: se?.side ?? '',
              order: se?.order ?? 99,
              hung: hung == null || hung.any((h) => psEq(h, m.id)),
              deg: deg[m.model]!,
              rp: fl?.pan ?? false,
              rt: fl?.tilt ?? false,
            );
          }(),
    ],
  );
}

/// Tonight's hung heads from `rig_test.json`, as PowerShell strings, or null
/// when there is no file or it can't be read (then every head counts as hung).
List<String>? _hung(ShowEnv env) {
  final f = env.file('rig_test.json');
  if (!f.existsSync()) return null;
  final Object? j;
  try {
    j = jsonDecode(readText(f.path));
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
  final v = j is Map ? j['hung'] : null;
  String text(Object? x) => x == null ? '' : (x is num ? psNum(x) : (x is bool ? (x ? 'True' : 'False') : '$x'));
  // `$null | ForEach-Object` runs once, so a missing list is one ''
  return v is List ? [for (final x in v) text(x)] : [text(v)];
}

/// Writes the aim scene when it is missing, or adds step 2 to an old one, or
/// (Room) moves heads still on the old normal to the new one.
List<String> _prepareAimScene(AimShow s, WriteJournal j) {
  if (!s.sceneExists) {
    final h = s.homeAims();
    s.writeAimScene(j, h.center, h.corner);
    return ['  CHANGED  created aim scene ${s.aimTitle}: step 1 = CENTER, step 2 = CORNER'];
  }
  final a = s.readAimScene();
  if (a.steps < 2) {
    s.writeAimScene(j, a.center, a.corner);
    return ['  ${s.aimTitle} upgraded: step 2 = CORNER added (your center aims kept)'];
  }
  if (a.moved > 0) {
    s.writeAimScene(j, a.center, a.corner);
    return ['  CHANGED  AROUND ROOM was reshaped in Generator: ${a.moved} head(s) still on the old normal moved to the new one in ${s.aimTitle}'];
  }
  return [];
}

/// The steps every action that applies shares: the aim scene, the check
/// movements, and (Room) the buttons on the SETUP page.
List<String> _prepare(AimShow s, WriteJournal j) {
  final out = _prepareAimScene(s, j);
  for (final name in psSorted<String>(s.checks.keys, [(k) => k])) {
    final line = s.newCheckGpj(j, name, s.checks[name]!);
    if (line != null) out.add(line);
  }
  if (s.mode == AimMode.room) out.addAll(s.installRoomButtons(j));
  return out;
}

/// The old tool's report: lines joined, one per line.
String _report(List<String> lines) => lines.join('\n');

/// Applies tonight's aims from the aim scene at overall [size] ("120" or
/// "120 90", default 100). Refuses when some aims look wrong, unless [force].
/// Port of `-Action Apply -NoPrompt`.
String aimApply(ShowEnv env, AimMode mode, {String size = '', bool force = false}) => WriteJournal.run((j) {
  final s = AimShow(env, mode)..requireSxClosed();
  final out = _prepare(s, j);
  final a = s.readAimScene();
  final copies = s.addPartnerAims(a);
  if (copies.isNotEmpty) {
    final byId = {for (final m in s.movers) m.id: m};
    out.addAll(['', '  T-BAR PARTNERS - same aim as the head next to it (written into ${s.aimTitle} too, nudge it there if needed):']);
    for (final m in s.movers) {
      final c = copies[m.id];
      if (c == null) continue;
      final extra = c.sized ? ', center + corner' : (!c.corner ? ', center only - its own corner kept' : '');
      out.add('    ${m.label.padRight(8)} <- ${byId[c.from]!.label.padRight(8)} (${c.tower} truss$extra)');
    }
  }
  final fix = s.headFixes(a);
  out.addAll(_table(s.movers, fix));
  final nWarn = s.movers.where((m) => fix[m.id]!.warn.isNotEmpty).length;
  if (nWarn > 0 && !force) throw ToolError('Aims look wrong for $nWarn head(s). NOTHING was changed.');
  final (sx, sy) = parseSize(size.isEmpty ? '100' : size);
  // after the checks above: a stop still changes nothing
  if (copies.isNotEmpty) s.writeAimScene(j, a.center, a.corner);
  out.addAll(['  OVERALL SIZE: width ${psNum(sx * 100)}%  depth ${psNum(sy * 100)}%', '']);
  out.addAll(s.updateGpjs(j, fix, sx, sy));
  out.add(s.updateCenterSpot(j, a.center));
  out.addAll(s.updateRenderedScenes(j));
  _saveState(s, j, sx, sy);
  out.add('  DONE - open ShowXpress. Check: ${s.checkTitle} (beams trace the corners).');
  return _report(out);
});

/// Every correction off, size 100, aim scene back to home. The shapes are
/// kept. Port of `-Action Home`.
String aimHome(ShowEnv env, AimMode mode) => WriteJournal.run((j) {
  final s = AimShow(env, mode)..requireSxClosed();
  final out = _prepare(s, j);
  final h = s.homeAims();
  s.writeAimScene(j, h.center, h.corner);
  s.st.copied = {};
  out.add('  aim scene reset to home');
  out.addAll(s.updateGpjs(j, s.headFixes(h, reset: true), 1.0, 1.0));
  out.addAll(s.updateRenderedScenes(j));
  _saveState(s, j, 1.0, 1.0);
  out.add('  DONE - all movement scenes back to normal.');
  return _report(out);
});

/// Room: makes ROOM AIM (ADJUST) and ROOM CHECK and puts them on the SETUP
/// page. Port of `-Action Install`.
String aimInstall(ShowEnv env, AimMode mode) => WriteJournal.run((j) {
  final s = AimShow(env, mode)..requireSxClosed();
  return _report([..._prepare(s, j), '  DONE - ROOM AIM (ADJUST) and ROOM CHECK are on the SETUP page.']);
});

/// Rebuilds only the step scenes made from a movement (GRAND ENTRANCE), after
/// the movement was edited. Port of `-Action Rebuild`.
String aimRebuild(ShowEnv env) => WriteJournal.run((j) {
  final s = AimShow(env, AimMode.floor)..requireSxClosed();
  return _report(s.updateRenderedScenes(j));
});

/// Writes the aims set on the live aim screen into the aim scene, by head id.
/// Port of `-Action LiveSave`.
String aimLiveSave(ShowEnv env, AimMode mode, Map<String, LiveAim> aims) => WriteJournal.run((j) {
  final s = AimShow(env, mode)..requireSxClosed();
  final out = _prepareAimScene(s, j);
  final a = s.readAimScene();
  final byId = psMap<Mover>()..addAll({for (final m in s.movers) m.id: m});
  final done = <String>[];
  aims.forEach((id, aim) {
    final m = byId[id];
    if (m == null) return;
    final what = <String>[];
    if (aim.c != null) {
      a.center[m.id] = aim.c!;
      what.add('center');
    }
    if (aim.k != null) {
      a.corner[m.id] = aim.k!;
      what.add('corner');
    }
    if (what.isNotEmpty) done.add('${m.label} (${what.join(' + ')})');
  });
  if (done.isEmpty) return _report([...out, '  nothing to change - no head was aimed']);
  s.writeAimScene(j, a.center, a.corner);
  return _report([...out, '  CHANGED  live aims saved into ${s.aimTitle}: ${done.join(', ')}']);
});

/// Saves the state file, last of all. Port of `Save-State`.
void _saveState(AimShow s, WriteJournal j, double sx, double sy) {
  s.st
    ..sx = sx
    ..sy = sy;
  j.write(s.stateFile, s.st.toText(), bom: false);
}

/// Port of `Show-Table`.
List<String> _table(List<Mover> movers, Map<String, HeadFix> fix) => [
  '',
  '  HEAD      CENTER correction      SIZE from corner (width x depth)',
  for (final m in movers)
    () {
      final o = fix[m.id]!;
      final cen = o.op == 0 && o.ot == 0 ? '(home)' : '${'${o.op}'.padLeft(6)} / ${'${o.ot}'.padLeft(6)}';
      final sz = o.sized ? '${psFormat0(o.kp * 100).padLeft(4)}% x ${psFormat0(o.kt * 100).padLeft(4)}%   zoom ${o.zp}/${o.zt}' : 'normal (no corner set)';
      return '  ${m.label.padRight(8)}  ${cen.padRight(20)}   $sz  ${o.warn}';
    }(),
  '',
];
