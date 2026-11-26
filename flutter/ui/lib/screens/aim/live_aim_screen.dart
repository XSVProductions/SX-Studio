import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../page_store.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'aim_widgets.dart';
import 'live_aim_model.dart';
import 'pointer_lock.dart';

/// How the live aim screen was left. [aims] is null for Cancel.
typedef LiveAimExit = ({Map<String, LiveAim>? aims, bool reopen});

/// Opens the live aim screen on top of everything, with output already
/// started ([start]). Returns how it was left; the caller stops the output
/// or saves.
Future<LiveAimExit?> openLiveAim(BuildContext context, {required AimMode mode, required LiveStart start, required bool reopen}) async {
  final prefs = await openPageStore();
  if (!context.mounted) return null;
  return Navigator.of(context).push<LiveAimExit>(
    PageRouteBuilder(
      opaque: true,
      transitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => LiveAimScreen(mode: mode, start: start, reopen: reopen, prefs: prefs),
    ),
  );
}

/// Live aim: drag in the box and the real head follows. Port of the old
/// page's `#live` overlay.
///
/// The pad and the minimap are painted only when something changes (a drag,
/// a key, a button). Output goes through [LiveOutputPump], at most one
/// request every 30 ms, whatever the pointer does.
class LiveAimScreen extends StatefulWidget {
  const LiveAimScreen({super.key, required this.mode, required this.start, required this.reopen, required this.prefs});

  final AimMode mode;
  final LiveStart start;
  final bool reopen;
  final PageStore prefs;

  @override
  State<LiveAimScreen> createState() => _LiveAimScreenState();
}

class _LiveAimScreenState extends State<LiveAimScreen> {
  late final LiveAimModel _m;
  final _buffer = LiveOutputBuffer();
  late final LiveOutputPump _pump;
  late LiveStart _start = widget.start;
  late bool _reopen = widget.reopen;
  var _dragging = false;
  String? _gone;

  /// Ticks on a drag step that changed only the picked head's numbers. The
  /// pan and tilt lines and the minimap listen to it, so a drag doesn't
  /// rebuild the whole screen on every pointer move.
  final _moved = ValueNotifier<int>(0);

  /// [_shown] as of the last full build.
  Object? _shape;

  /// Everything outside the pan and tilt lines and the minimap that a drag
  /// can change: which head and step, whether it counts as aimed, Undo and
  /// the tab's dirty mark.
  Object get _shown {
    final h = _m.sel, w = _m.w(h);
    return (h.id, _m.step, w.tc, w.tk, _m.canUndo, _m.edited);
  }

  /// Holds the mouse in place while dragging in the pad (old `requestPointerLock`).
  late final _lock = PointerLock(
    onMove: (dx, dy, {required shift, required ctrl}) {
      if (_dragging) _move(dx, dy, fine: shift, fast: ctrl);
    },
    onLost: () {
      if (mounted) setState(() => _dragging = false);
    },
  );
  final _focus = FocusNode();

  SxClient get _client => AppScope.read(context).client;

  @override
  void initState() {
    super.initState();
    final speed = double.tryParse(widget.prefs.get('sxh_lvspd') ?? '') ?? 1;
    _m = LiveAimModel(widget.start.info!, mode: widget.mode, speed: aimSpeeds.any((s) => s.$1 == speed) ? speed : 1, flipOf: _flipOf);
    _pump = LiveOutputPump(
      _buffer,
      send: (l) => _client.liveOut(l),
      onGone: (e) {
        if (mounted) setState(() => _gone = e.startsWith('The DMX output stopped') ? 'Unplugged, or SX Studio lost it.' : e);
      },
    );
    _output(snap: true);
  }

  @override
  void dispose() {
    _lock.stop();
    _pump.close();
    _focus.dispose();
    _moved.dispose();
    super.dispose();
  }

  ({bool x, bool y}) _flipOf(String id) {
    final raw = widget.prefs.get('sxh_flip_$id');
    if (raw == null) return (x: false, y: false);
    try {
      final j = jsonDecode(raw);
      if (j is Map) return (x: j['x'] == true, y: j['y'] == true);
    } on FormatException {
      // a broken value reads as no flip, like the old page
    }
    return (x: false, y: false);
  }

  void _setFlip(({bool x, bool y}) f) {
    final h = _m.sel, text = jsonEncode({'x': f.x, 'y': f.y});
    widget.prefs.set('sxh_flip_${h.id}', text);
    // the head on the same T-bar usually hangs the same way
    if (h.partner.isNotEmpty && widget.prefs.get('sxh_flip_${h.partner}') == null) widget.prefs.set('sxh_flip_${h.partner}', text);
    setState(() => _m.flip = f);
  }

  /// After any change: queue the new values, send soon, redraw. A drag step,
  /// [moved], redraws only the numbers, unless it changed more than those.
  void _output({bool snap = false, bool moved = false}) {
    _buffer.push(_m, snap: snap);
    _pump.kick();
    AppScope.read(context).setDirty('aim', _m.edited);
    if (moved && _shown == _shape) {
      _moved.value++;
    } else {
      setState(() {});
    }
  }

  void _endDrag() {
    _lock.stop();
    setState(() => _dragging = false);
  }

  void _move(double dx, double dy, {bool fine = false, bool fast = false}) {
    if (_gone != null) return;
    if (_m.move(dx, dy, fine: fine, fast: fast)) _output(moved: true);
  }

  Future<void> _reconnect() async {
    LiveStart r;
    try {
      r = await _client.liveStart(mode: _m.mode);
    } on ApiException {
      r = const LiveStart(ok: false, error: 'Lost connection.');
    }
    if (!mounted) return;
    if (!r.ok) return setState(() => _gone = r.error);
    _pump.resume();
    _buffer.reset();
    setState(() {
      _gone = null;
      _start = r;
    });
    _output(snap: true);
  }

  Future<void> _cancel() async {
    if (_m.edited &&
        !await askUser(
          context,
          'Stop without saving?',
          const Text('The aims you set here are not saved. The heads go dark and the show keeps the aims it had.'),
          'Stop without saving',
        )) {
      return;
    }
    if (mounted) Navigator.pop<LiveAimExit>(context, (aims: null, reopen: _reopen));
  }

  Future<void> _save() async {
    final aims = _m.aimsToSave();
    if (aims.isEmpty) {
      if (await askUser(context, 'Nothing was aimed', const Text('No head was moved, so there is nothing to save. Stop live aim?'), 'Stop') && mounted) {
        Navigator.pop<LiveAimExit>(context, (aims: null, reopen: _reopen));
      }
      return;
    }
    Navigator.pop<LiveAimExit>(context, (aims: aims, reopen: _reopen));
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance, key = e.logicalKey;
    final arrow = {
      LogicalKeyboardKey.arrowLeft: (-4.0, 0.0),
      LogicalKeyboardKey.arrowRight: (4.0, 0.0),
      LogicalKeyboardKey.arrowUp: (0.0, -4.0),
      LogicalKeyboardKey.arrowDown: (0.0, 4.0),
    }[key];
    if (arrow != null) {
      _move(arrow.$1, arrow.$2, fine: k.isShiftPressed, fast: k.isControlPressed);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      _stepTo(k.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (k.isControlPressed || k.isAltPressed || e is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.keyN) {
      _stepTo(1);
    } else if (key == LogicalKeyboardKey.keyP) {
      _stepTo(-1);
    } else if (key == LogicalKeyboardKey.digit1) {
      _setStep(AimStep.center);
    } else if (key == LogicalKeyboardKey.digit2) {
      _setStep(AimStep.corner);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _stepTo(int dir) {
    _m.stepTo(dir);
    _output();
  }

  void _setStep(AimStep s) {
    _m.step = s;
    _output();
  }

  void _select(LiveHead h) {
    _m.select(h);
    _output();
  }

  @override
  Widget build(BuildContext context) {
    _shape = _shown;
    final phone = MediaQuery.sizeOf(context).width <= 760;
    final body = phone
        ? ListView(
            padding: EdgeInsets.zero,
            children: [
              _headStrip(),
              Padding(padding: const EdgeInsets.all(10), child: _main(phone: true)),
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Sx.line)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: _side(phone: true),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 220,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Sx.line)),
                ),
                child: _headList(),
              ),
              Expanded(
                child: Padding(padding: const EdgeInsets.fromLTRB(18, 14, 18, 14), child: _main(phone: false)),
              ),
              Container(
                width: 280,
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: Sx.line)),
                ),
                child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 14), child: _side(phone: false)),
              ),
            ],
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: Sx.bg,
        body: SafeArea(
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _key,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _top(phone),
                if (_gone != null) _goneBar(),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _top(bool phone) {
    final s = _start;
    return Container(
      padding: phone ? const EdgeInsets.fromLTRB(10, 8, 10, 8) : const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Sx.line)),
      ),
      child: Wrap(
        spacing: phone ? 8 : 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gps_fixed, size: 16, color: Sx.accent),
              const SizedBox(width: 6),
              Text(
                'LIVE AIM',
                style: TextStyle(fontFamily: Sx.display, color: Sx.accent, letterSpacing: 1, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          Text('${_m.mode == AimMode.room ? 'Room' : 'Dance floor'} · ${_m.aimTitle}', style: Sx.sub),
          Tag(s.test ? 'TEST - no real output' : 'Output: ${s.iface}', color: s.test ? Sx.red : Sx.blue),
          CheckRow('Open ShowXpress again after', value: _reopen, onChanged: (v) => setState(() => _reopen = v)),
          OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: const Text('Save & finish'),
          ),
        ],
      ),
    );
  }

  Widget _goneBar() => Container(
    margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: Sx.tint(Sx.red),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: 18, color: Sx.red),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: 'The DMX output stopped. ',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: '$_gone Your aims so far are kept.'),
              ],
            ),
            style: TextStyle(color: Sx.redText, fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        MiniButton('Reconnect', primary: true, onPressed: _reconnect),
      ],
    ),
  );

  /// The status words after a head's name in the list.
  (String, Color, bool) _status(LiveHead h) {
    final w = _m.w(h);
    if (w.tc || w.tk) return ('aimed${w.tk ? ' + corner' : ''}', Sx.blue, false);
    if (_m.copies(h)) return (_m.partner(h)!.label, Sx.text2, true);
    if (!h.free) return ('aimed before', Sx.dim, false);
    return ('normal', Sx.mute, false);
  }

  Widget _headRow(LiveHead h, {required bool chip}) {
    final on = h == _m.sel;
    final (st, stColor, copy) = _status(h);
    final dim = _m.towers && h.order >= 99;
    return InkWell(
      onTap: () => _select(h),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: on
              ? Sx.accent.withValues(alpha: .1)
              : chip
              ? Sx.panel
              : null,
          border: Border.all(
            color: on
                ? Sx.accent
                : chip
                ? Sx.line
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: chip ? MainAxisSize.min : MainAxisSize.max,
          children: [
            SizedBox(
              width: 10,
              child: Text(h.side, style: TextStyle(fontSize: 10, color: Sx.mute)),
            ),
            const SizedBox(width: 6),
            Text(
              h.label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: dim ? Sx.mute : Sx.text),
            ),
            if (chip) const SizedBox(width: 6) else const Spacer(),
            if (copy) Icon(Icons.swap_horiz, size: 12, color: stColor),
            Text(
              st,
              style: TextStyle(fontSize: 11, color: stColor, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headList() {
    final rows = <Widget>[];
    String? cur;
    for (final h in _m.ordered) {
      final t = h.order < 99
          ? h.tower
          : _m.towers
          ? 'Other heads (not on a truss)'
          : 'Heads';
      if (t != cur) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 5),
            child: Text(
              t.toUpperCase(),
              style: TextStyle(fontSize: 11, letterSpacing: .8, color: Sx.dim, fontWeight: FontWeight.w600),
            ),
          ),
        );
        cur = t;
      }
      rows.add(_headRow(h, chip: false));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 20), children: rows);
  }

  Widget _headStrip() => Container(
    height: 46,
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Sx.line)),
    ),
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      children: [for (final h in _m.ordered) Padding(padding: const EdgeInsets.only(right: 6), child: _headRow(h, chip: true))],
    ),
  );

  Widget _main({required bool phone}) {
    final h = _m.sel, w = _m.w(h), corner = _m.step == AimStep.corner, room = _m.mode == AimMode.room;
    final tip = corner
        ? 'Aim it at the front-left ${room ? 'edge of the AROUND ROOM sweep' : 'corner of the floor (from the DJ)'}'
              '${w.tk || (h.kSet && !_m.copies(h)) ? '' : '. Until you do, it follows the center.'}'
        : 'Aim it at the ${room ? 'middle of where AROUND ROOM should sweep' : "center of tonight's dance floor"}';
    final pad = Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
        _focus.requestFocus();
        if (e.kind == PointerDeviceKind.mouse) _lock.start(e);
        setState(() => _dragging = true);
      },
      onPointerMove: (e) {
        if (!_dragging) return;
        final mouse = e.kind == PointerDeviceKind.mouse, k = HardwareKeyboard.instance;
        final d = mouse ? _lock.delta(e) : e.delta;
        if (d != Offset.zero) _move(d.dx, d.dy, fine: mouse && k.isShiftPressed, fast: mouse && k.isControlPressed);
      },
      onPointerUp: (_) => _endDrag(),
      onPointerCancel: (_) => _endDrag(),
      // claims the drag, so the page doesn't scroll on a phone
      child: GestureDetector(
        onPanStart: (_) {},
        child: MouseRegion(
          cursor: _dragging ? SystemMouseCursors.none : SystemMouseCursors.grab,
          child: CustomPaint(
            painter: _PadPainter(dragging: _dragging),
            child: Container(
              constraints: BoxConstraints(minHeight: phone ? MediaQuery.sizeOf(context).height * .38 : 220),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${h.label}  '),
                        TextSpan(
                          text: corner ? 'CORNER' : 'CENTER',
                          style: TextStyle(color: Sx.accent),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: phone ? 24 : 30, fontWeight: FontWeight.w700, color: Sx.text),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tip,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Sx.dim, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    phone ? 'Put your finger in this box and drag' : 'Hold the mouse button down here and drag',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Sx.mute, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Seg<AimStep>(
              value: _m.step,
              options: {AimStep.center: '1 · CENTER', AimStep.corner: phone ? '2 · CORNER' : '2 · CORNER (optional)'},
              onChanged: _setStep,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!phone)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('Speed', style: Sx.sub),
                  ),
                Seg<double>(
                  value: _m.speed,
                  options: {for (final (v, l) in aimSpeeds) v: l},
                  onChanged: (v) {
                    widget.prefs.set('sxh_lvspd', v == v.roundToDouble() ? '${v.toInt()}' : '$v');
                    setState(() => _m.speed = v);
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (phone) pad else Expanded(child: pad),
        if (!phone) ...[
          const SizedBox(height: 12),
          boldText(
            'Hold the mouse button down in the box and drag · *Shift* = finer · *Ctrl* = faster · *arrow keys* nudge · *N* / *P* or *Tab* = next / previous head · *1* / *2* = step',
            style: TextStyle(color: Sx.dim, fontSize: 12.5),
          ),
        ],
      ],
    );
  }

  Widget _side({required bool phone}) {
    final h = _m.sel, w = _m.w(h), cp = _m.copies(h), pt = _m.partner(h);
    final where = h.tower.isEmpty ? '' : ' · ${h.tower}${h.side.isEmpty ? '' : (h.side == 'L' ? ' left' : ' right')}';
    final status = cp
        ? 'Not aimed. It gets the same aim as *${pt!.label}* next to it. Drag to aim it yourself.'
        : (w.tc || w.tk)
        ? 'Aimed now${w.tk ? ' (center + corner)' : ' (center)'}'
        : !h.free
        ? 'Aimed before. Drag to change it.'
        : 'Normal aim. Drag to aim it.';
    String deg(double v, int axis) {
      final x = _m.degrees(h, v, axis);
      return '${x >= 0 ? '+' : '-'}${x.abs().toStringAsFixed(1)}° from normal';
    }

    final nav = _m.nav(), i = nav.indexOf(h);
    final last = i >= nav.length - 1;
    final nextLabel = !last
        ? 'Next head'
        : _m.step == AimStep.center
        ? 'Corners'
        : 'Last head';
    final small = const EdgeInsets.symmetric(horizontal: 10, vertical: 8);
    const smallText = TextStyle(fontFamily: Sx.body, fontSize: 13, fontWeight: FontWeight.w600);
    final buttons = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: i <= 0 ? null : () => _stepTo(-1),
                style: OutlinedButton.styleFrom(padding: small, textStyle: smallText),
                icon: const Icon(Icons.arrow_back, size: 15),
                label: const Text('Previous'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: FilledButton.icon(
                onPressed: last && _m.step == AimStep.corner ? null : () => _stepTo(1),
                style: FilledButton.styleFrom(padding: small, textStyle: smallText),
                iconAlignment: IconAlignment.end,
                icon: last && _m.step == AimStep.corner ? null : const Icon(Icons.arrow_forward, size: 15),
                label: Text(nextLabel),
              ),
            ),
          ],
        ),
        if (pt != null) ...[
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: () {
              _m.sameAsPartner();
              _output();
            },
            style: OutlinedButton.styleFrom(padding: small, textStyle: smallText),
            icon: const Icon(Icons.swap_horiz, size: 15),
            label: Text('Same as ${pt.label} (next to it)'),
          ),
        ],
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _m.canUndo
                    ? () {
                        _m.undo();
                        _output();
                      }
                    : null,
                style: OutlinedButton.styleFrom(padding: small, textStyle: smallText),
                child: const Text('Undo this head'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  _m.backToNormal();
                  _output();
                },
                style: OutlinedButton.styleFrom(padding: small, textStyle: smallText),
                child: const Text('Back to normal'),
              ),
            ),
          ],
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (phone) ...[buttons, const SizedBox(height: 12)],
        // the heading font has no middle dot, so the tower part is in the body font
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: h.label),
              TextSpan(
                text: where,
                style: const TextStyle(fontFamily: Sx.body, letterSpacing: 0),
              ),
            ],
          ),
          style: TextStyle(fontFamily: Sx.display, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: .5, color: Sx.text),
        ),
        const SizedBox(height: 2),
        boldText(status, style: Sx.sub),
        const SizedBox(height: 6),
        ValueListenableBuilder(
          valueListenable: _moved,
          builder: (context, _, _) {
            final p = _m.pos(h, _m.step);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (axis, name) in [(0, 'Pan'), (1, 'Tilt')])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(name, style: TextStyle(color: Sx.dim, fontSize: 12.5)),
                        ),
                        Text(
                          '${jsRound(axis == 0 ? p.$1 : p.$2)}  ',
                          style: TextStyle(color: Sx.text, fontSize: 12.5, fontWeight: FontWeight.w500),
                        ),
                        Text(deg(axis == 0 ? p.$1 : p.$2, axis), style: TextStyle(color: Sx.dim, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: AspectRatio(
              aspectRatio: 240 / 180,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Sx.well,
                  border: Border.all(color: Sx.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ValueListenableBuilder(
                  valueListenable: _moved,
                  builder: (context, _, _) => CustomPaint(painter: _MapPainter(_mapOf(h))),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('dashed = normal floor · amber = tonight · ring = where it points now', style: Sx.sub.copyWith(fontSize: 11.5)),
        const SizedBox(height: 10),
        CheckRow('Flip left / right for this head', value: _m.flip.x, onChanged: (v) => _setFlip((x: v, y: _m.flip.y))),
        const SizedBox(height: 4),
        CheckRow('Flip up / down for this head', value: _m.flip.y, onChanged: (v) => _setFlip((x: _m.flip.x, y: v))),
        const SizedBox(height: 10),
        if (!phone) buttons,
        const SizedBox(height: 12),
        CheckRow(
          'Light all hung heads (not just this one)',
          value: _m.all,
          onChanged: (v) {
            _m.all = v;
            _output();
          },
        ),
      ],
    );
  }

  /// The minimap's numbers, in degrees around the normal center, turned
  /// like the mouse moves. Port of the old `lvSide` map.
  _MapData _mapOf(LiveHead h) {
    final c = _m.pos(h, AimStep.center), k = _m.pos(h, AimStep.corner), p = _m.pos(h, _m.step);
    final fx = _m.flip.x ? -1 : 1, fy = _m.flip.y ? -1 : 1;
    double x(double v) => _m.degrees(h, v, 0) * fx;
    double y(double v) => -_m.degrees(h, v, 1) * fy;
    final bx = _m.degrees(h, h.dk.$1.toDouble(), 0).abs(), by = _m.degrees(h, h.dk.$2.toDouble(), 1).abs();
    final kx = (x(k.$1) - x(c.$1)).abs(), ky = (y(k.$2) - y(c.$2)).abs();
    final r = [bx * 2.2, by * 2.2, 10.0, x(c.$1).abs() + kx + 2, y(c.$2).abs() + ky + 2, x(p.$1).abs() + 2, y(p.$2).abs() + 2].reduce(math.max);
    return _MapData(scale: 82 / r, box: (bx, by), center: (x(c.$1), y(c.$2)), half: (kx, ky), corner: (x(k.$1), y(k.$2)), now: (x(p.$1), y(p.$2)));
  }
}

class _MapData {
  const _MapData({required this.scale, required this.box, required this.center, required this.half, required this.corner, required this.now});

  final double scale;
  final Pos box, center, half, corner, now;

  @override
  bool operator ==(Object o) => o is _MapData && o.scale == scale && o.center == center && o.half == half && o.corner == corner && o.now == now && o.box == box;

  @override
  int get hashCode => Object.hash(scale, box, center, half, corner, now);
}

/// The minimap: normal floor (dashed), tonight's center and corner box
/// (amber), the corner (blue) and where the head points now (ring). Drawn
/// in the old SVG's 240 x 180 units.
class _MapPainter extends CustomPainter {
  _MapPainter(this.d);

  final _MapData d;

  /// So a theme switch repaints.
  final light = Sx.isLight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)))
      ..scale(size.width / 240, size.height / 180);
    Offset at(Pos v) => Offset(120 + v.$1 * d.scale, 90 + v.$2 * d.scale);
    Rect box(Pos c, Pos half) => Rect.fromCenter(center: at(c), width: 2 * half.$1 * d.scale, height: 2 * half.$2 * d.scale);
    final axis = Paint()
      ..color = Sx.hover
      ..strokeWidth = 1;
    canvas
      ..drawLine(const Offset(120, 0), const Offset(120, 180), axis)
      ..drawLine(const Offset(0, 90), const Offset(240, 90), axis);
    _dashed(
      canvas,
      RRect.fromRectAndRadius(box((0, 0), d.box), const Radius.circular(3)),
      Paint()
        ..color = Sx.mute
        ..style = PaintingStyle.stroke,
      4,
      3,
    );
    final tonight = RRect.fromRectAndRadius(box(d.center, d.half), const Radius.circular(3));
    canvas
      ..drawRRect(tonight, Paint()..color = Sx.amber.withValues(alpha: .12))
      ..drawRRect(
        tonight,
        Paint()
          ..color = Sx.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      )
      ..drawCircle(at(d.center), 4, Paint()..color = Sx.amber)
      ..drawCircle(at(d.corner), 4, Paint()..color = Sx.blue)
      ..drawCircle(
        at(d.now),
        8,
        Paint()
          ..color = Sx.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.d != d || old.light != light;
}

/// Strokes [r] as a dashed line, [on] then [off] units.
void _dashed(Canvas canvas, RRect r, Paint paint, double on, double off) {
  for (final m in (Path()..addRRect(r)).computeMetrics()) {
    for (var t = 0.0; t < m.length; t += on + off) {
      canvas.drawPath(m.extractPath(t, math.min(t + on, m.length)), paint);
    }
  }
}

/// The drag box: dashed while waiting, solid lime while dragging.
class _PadPainter extends CustomPainter {
  _PadPainter({required this.dragging});

  final bool dragging;

  /// So a theme switch repaints.
  final light = Sx.isLight;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius((Offset.zero & size).deflate(1), const Radius.circular(16));
    canvas.drawRRect(r, Paint()..color = Sx.well);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = dragging ? Sx.accent : Sx.line2;
    if (dragging) {
      canvas.drawRRect(r, line);
    } else {
      _dashed(canvas, r, line, 7, 5);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => old.dragging != dragging || old.light != light;
}
