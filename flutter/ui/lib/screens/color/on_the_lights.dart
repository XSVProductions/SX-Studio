import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// What a frame sends: a key per channel or channel pair, and its output
/// command (`b:<ch>:<v>` or `s:<ch>:<ch+1>:<v>`). A `b<ch>` key that drops
/// out of the frame is set to 0.
typedef LiveFrame = Map<String, String>;

/// A preview on the real lights for Tonight's Color and Looks: ShowXpress
/// closed, the engine's live DMX output open, and only what changed sent, one
/// request at a time, at most every 30 ms. A keep-alive goes out after a
/// second with nothing to send.
///
/// Port of the old page's `cpGo`/`cpPush`/`cpKick`/`cpFlush`/`cpStop` and
/// `lkPvGo`/`lkPush`/`lkKick`/`lkFlush`/`lkPvStop`, with `sxCloseLive` and `lvStart`.
class OnTheLights extends ChangeNotifier {
  OnTheLights(this._app, {required this.frame, required this.raw, this.tick});

  final AppState _app;

  /// The values to send now.
  final LiveFrame Function() frame;

  /// The editors' raw output (Looks), or live aim's output with head info (Tonight's Color).
  final bool raw;

  /// Also works out the frame on this timer (Looks plays its steps).
  final Duration? tick;

  var _on = false;
  final _sent = <String, String>{};
  final _pend = <String, String>{};
  var _zero = true, _keepAlive = false, _flushing = false;
  var _last = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _tick, _alive, _kick;

  bool get on => _on;

  /// What it is doing while it starts or stops, or ''.
  String busy = '';

  /// "Open ShowXpress again when I stop". Ticked when it closed ShowXpress.
  bool reopen = false;

  /// The interface's name, and true when there is no real output.
  String iface = '';
  bool test = false;

  /// The heads from the live start (not in [raw] mode).
  LiveAimInfo? info;

  void _busy(String b) {
    busy = b;
    notifyListeners();
  }

  void setReopen(bool v) {
    reopen = v;
    notifyListeners();
  }

  /// Closes ShowXpress when it is open (after asking), opens the output and
  /// starts sending. Shows what went wrong in a dialog. [title] is the
  /// question, [again] the button to press again.
  Future<void> go(BuildContext context, {required String title, required String again, required void Function(String error) onLost}) async {
    if (_on || busy.isNotEmpty) return;
    final c = await _closeSx(context, title, again);
    if (!c.go || !context.mounted) {
      _busy('');
      return;
    }
    _busy('Connecting to the DMX interface.');
    var r = await _start(false);
    if (!r.ok && r.nova && context.mounted) {
      _busy('');
      final yes = await _ask(context, 'NovaStar is using the DMX interface', const [
        TextSpan(
          text:
              'The NovaStar LED-screen software (NovaLCT) has a USB scanner that grabs the DMX interface. Pause it while you preview? '
              'NovaLCT starts it again by itself. Your LED screens are not touched.',
        ),
      ], 'Pause it and continue');
      if (yes) {
        _busy('Pausing NovaStar and connecting.');
        r = await _start(true);
      }
    }
    _busy('');
    if (!r.ok) {
      await _liveStop();
      if (context.mounted) await showReport(context, 'Not on the lights', '', error: '${r.error}${c.reo ? reopenNote : ''}');
      return;
    }
    iface = r.iface;
    test = r.test;
    info = r.info;
    reopen = c.reo;
    _on = true;
    _zero = true;
    _sent.clear();
    _pend.clear();
    _alive = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_on && DateTime.now().difference(_last).inMilliseconds > 1000) {
        _keepAlive = true;
        _schedule();
      }
    });
    if (tick case final t?) _tick = Timer.periodic(t, (_) => push());
    _lost = onLost;
    notifyListeners();
    push();
  }

  void Function(String error) _lost = (_) {};

  /// Said after an error when ShowXpress was closed for the preview.
  static const reopenNote = ' ShowXpress is closed now. Press Launch ShowXpress at the top to open it again.';

  Future<LiveStart> _start(bool stopNova) async {
    try {
      return await _app.client.liveStart(raw: raw, stopNova: stopNova);
    } on ApiException catch (e) {
      return LiveStart(ok: false, error: e.message);
    }
  }

  Future<void> _liveStop() async {
    try {
      await _app.client.liveStop();
    } on ApiException {
      // nothing is running
    }
  }

  /// Port of `sxCloseLive`.
  Future<({bool go, bool reo})> _closeSx(BuildContext context, String title, String again) async {
    await _app.refresh();
    if (!_app.sxOpen) return (go: true, reo: false);
    if (!context.mounted) return (go: false, reo: false);
    final yes = await _ask(context, title, [
      const TextSpan(text: 'Only one program can use the DMX interface, so ShowXpress closes while you preview. '),
      TextSpan(
        text: 'Save your show first',
        style: TextStyle(fontWeight: FontWeight.w700, color: Sx.text),
      ),
      const TextSpan(text: ' if you changed anything. If ShowXpress asks, answer it there.\n\nIt can open again when you stop.'),
    ], 'Close and preview');
    if (!yes) return (go: false, reo: false);
    ToolResult r;
    try {
      r = await _app.client.sxClose(live: true);
    } on ApiException catch (e) {
      r = ToolResult.failed(e.message);
    }
    if (!r.ok) {
      if (context.mounted) await showReport(context, 'ShowXpress', r.out, error: r.error);
      return (go: false, reo: false);
    }
    _busy('Waiting for ShowXpress to close. Save it if it asks.');
    final t0 = DateTime.now();
    var open = true;
    while (DateTime.now().difference(t0).inSeconds < 120) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        open = (await _app.client.status()).open;
      } on ApiException {
        // keep waiting
      }
      if (!open || !context.mounted) break;
    }
    if (open) {
      _busy('');
      await _liveStop();
      if (context.mounted) {
        await showReport(context, 'ShowXpress', '', error: 'ShowXpress is still open. Close it (save if it asks), then press $again again.');
      }
      return (go: false, reo: false);
    }
    _busy('ShowXpress closed. Waiting for it to let go of the interface.');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    return (go: true, reo: true);
  }

  /// Works out the frame now and sends what changed.
  void push() {
    if (!_on) return;
    final fr = frame();
    for (final k in _sent.keys.toList()) {
      if (!fr.containsKey(k) && k.startsWith('b') && _sent[k] != 'b:${k.substring(1)}:0') {
        _sent[k] = _pend[k] = 'b:${k.substring(1)}:0';
      }
    }
    fr.forEach((k, cmd) {
      if (_sent[k] != cmd) _sent[k] = _pend[k] = cmd;
    });
    _schedule();
  }

  void _schedule() {
    if (!_on || _kick != null || _flushing) return;
    final wait = 30 - DateTime.now().difference(_last).inMilliseconds;
    if (wait > 0) {
      _kick = Timer(Duration(milliseconds: wait), () {
        _kick = null;
        _flush();
      });
    } else {
      _flush();
    }
  }

  Future<void> _flush() async {
    if (!_on || _flushing) return;
    var l = '${_zero ? 'z ' : ''}${_pend.values.join(' ')}'.trim();
    if (l.isEmpty) {
      if (!_keepAlive) return;
      l = 'k';
    }
    _zero = false;
    _keepAlive = false;
    _pend.clear();
    _flushing = true;
    _last = DateTime.now();
    ToolResult r;
    try {
      r = await _app.client.liveOut(l);
    } on ApiException {
      r = const ToolResult.failed('Lost connection to SX Studio.');
    }
    _flushing = false;
    if (!_on) return;
    if (!r.ok) {
      _halt();
      await _liveStop();
      _lost(r.error.isEmpty ? 'The DMX output stopped.' : r.error);
      return;
    }
    if (_pend.isNotEmpty) _schedule();
  }

  void _halt() {
    _on = false;
    _tick?.cancel();
    _alive?.cancel();
    _kick?.cancel();
    _kick = null;
    notifyListeners();
  }

  /// Stops sending and frees the interface, then opens ShowXpress again when [reopen].
  Future<void> stop({required bool reopen}) async {
    if (!_on) return;
    _halt();
    _busy('Stopping the DMX output.');
    await _liveStop();
    _busy('');
    if (!reopen) return;
    _busy('Starting ShowXpress.');
    try {
      await _app.client.sxLaunch();
    } on ApiException {
      // the top bar shows ShowXpress closed, with its own Launch button
    }
    await _app.refresh();
    _busy('');
  }

  @override
  void dispose() {
    if (_on) {
      _halt();
      unawaited(_liveStop());
    }
    super.dispose();
  }
}

Future<bool> _ask(BuildContext context, String title, List<InlineSpan> text, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title.copyWith(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text.rich(
            TextSpan(children: text),
            style: TextStyle(color: Sx.text2, fontSize: 14, height: 1.45),
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// The old `.tag`: where the preview's DMX goes, red when nowhere.
class OutputTag extends StatelessWidget {
  const OutputTag(this.lights, {super.key});

  final OnTheLights lights;

  @override
  Widget build(BuildContext context) {
    final c = lights.test ? Sx.red : Sx.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: Sx.tint(c, radius: 99),
      child: Text(
        lights.test ? 'TEST - no real output' : 'Output: ${lights.iface}',
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c),
      ),
    );
  }
}

/// "Open ShowXpress again when I stop".
class ReopenBox extends StatelessWidget {
  const ReopenBox(this.lights, {super.key});

  final OnTheLights lights;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => lights.setReopen(!lights.reopen),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(value: lights.reopen, onChanged: (v) => lights.setReopen(v ?? false)),
        ),
        const SizedBox(width: 6),
        Text('Open ShowXpress again when I stop', style: TextStyle(fontSize: 12.5, color: Sx.dim)),
      ],
    ),
  );
}
