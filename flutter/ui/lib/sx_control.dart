import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'theme.dart';
import 'widgets/sx_widgets.dart';

/// The old page's `ask()`: a yes / no dialog. True when [yes] was pressed.
/// [body] marks bold words with `*`, as in [boldText].
Future<bool> sxAsk(BuildContext context, String title, String body, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title.copyWith(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: boldText(body, style: TextStyle(color: Sx.text2, fontSize: 14, height: 1.4)),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

Future<ToolResult> _call(Future<ToolResult> Function() f) async {
  try {
    return await f();
  } on ApiException {
    return const ToolResult(ok: false, error: 'Lost connection.');
  }
}

/// Opens ShowXpress. When SX Studio sees it still running (stuck while
/// closing, no window), offers to force close it and open it again.
/// Port of the old page's `sxLaunch`.
Future<void> launchSx(BuildContext context) async {
  final app = AppScope.read(context);
  app.setBusy('Starting ShowXpress.');
  var r = await _call(app.client.sxLaunch);
  if (r.ok && r.extra['already'] == true) {
    app.setBusy('');
    if (!context.mounted) return;
    final force = await sxAsk(
      context,
      'ShowXpress is still running',
      'SX Studio sees ShowXpress running on the laptop. If you can see its window there, just use it.\n\n'
          "If you *can't* see it, it got stuck while closing: *Force close* stops it and opens it again (anything not saved is lost).",
      'Force close and open',
    );
    if (!force || !context.mounted || !await _forceClose(app)) return;
    app.setBusy('Starting ShowXpress.');
    r = await _call(app.client.sxLaunch);
  }
  // the old page kept "Starting ShowXpress" up a while after a good start
  if (r.ok) await Future<void>.delayed(sxLaunchHold);
  app.setBusy('');
  if (!r.ok) app.showResult(failedResult('sx', r.error, out: r.out));
  await app.refresh();
}

/// How long "Starting ShowXpress" stays up after ShowXpress started.
const sxLaunchHold = Duration(seconds: 3);

/// How long after asking ShowXpress to close a second press offers Force close.
const sxCloseGrace = Duration(seconds: 8);

/// Kills ShowXpress, then waits for it to let go. False when it didn't work.
/// Port of `sxForce`.
Future<bool> _forceClose(AppState app) async {
  app.setBusy('Force closing ShowXpress.');
  final r = await _call(() => app.client.sxClose(force: true));
  app.setBusy('');
  if (!r.ok) {
    app.showResult(failedResult('sx', r.error, out: r.out));
    return false;
  }
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  await app.refresh();
  return true;
}

/// Asks ShowXpress to close the normal way, after asking the user. Pressed
/// again more than 8 seconds later while it still runs, it offers Force
/// close instead. Port of `sxClose`.
Future<void> closeSx(BuildContext context) async {
  final app = AppScope.read(context);
  final asked = app.sxCloseAsked;
  if (asked != null && DateTime.now().difference(asked) > sxCloseGrace) {
    final force = await sxAsk(
      context,
      "ShowXpress didn't close",
      'If ShowXpress is asking whether to save, answer it on the laptop.\n\n'
          'If it has no window or is stuck, *Force close* stops it. Anything not saved is lost.',
      'Force close',
    );
    if (!force) return;
    app.sxCloseAsked = null;
    await _forceClose(app);
    return;
  }
  final ok = await sxAsk(
    context,
    'Close ShowXpress?',
    'ShowXpress is asked to close the normal way. Its "Do you really want to quit?" is answered Yes for you. '
        'If it asks whether to save, that one is yours to answer in ShowXpress.',
    'Close ShowXpress',
  );
  if (!ok) return;
  final r = await _call(app.client.sxClose);
  if (!r.ok) {
    app.showResult(failedResult('sx', r.error, out: r.out));
    return;
  }
  app.sxCloseAsked = r.extra['none'] == true ? null : DateTime.now();
  await app.refresh();
}

/// The old `.busy` veil: a line of text over the page while something runs.
class BusyVeil extends StatelessWidget {
  const BusyVeil(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ColoredBox(
      color: Sx.bg.withValues(alpha: Sx.isLight ? .75 : .7),
      child: Center(
        child: Text(
          text,
          style: TextStyle(color: Sx.text, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}
