import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../sx_control.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// A yes/no question in a dialog. True when the user pressed [ok].
/// The old page's `ask()`. Shared by the Auto Show screen and [RemoteRow].
Future<bool> askSx(BuildContext context, String title, String body, String ok) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title, style: Sx.title),
        content: Text(body, style: TextStyle(color: Sx.text2, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    ) ??
    false;

/// Asks, then switches ShowXpress's remote on in the show (queued while
/// ShowXpress is open). Port of the page's `remEnable`.
Future<void> enableRemote(BuildContext context, {Future<void> Function()? after}) async {
  final app = AppScope.read(context);
  final ok = await askSx(
    context,
    'Turn on ShowXpress remote control?',
    'Lets SX Studio press buttons in ShowXpress (RIG ID, DF CHECK, ROOM CHECK, Auto Show). It switches on External App in ShowXpress '
        'and remote access for every Live page, with a password only SX Studio uses. Only this computer connects to it.'
        '${app.sxOpen ? "\n\nShowXpress is open, so it's done when you next close it." : ''}',
    'Turn it on',
  );
  if (!ok || !context.mounted) return;
  await runSave(context, app.client.remoteEnable, what: 'remote', busy: 'Turning on the remote.', after: after);
}

/// Buttons that go on together, under one name ("DF CHECK 140 + 251").
class RemoteSet {
  const RemoteSet(this.label, this.titles);

  final String label;
  final List<String> titles;
}

bool _isSetup(String page) => RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(page);

/// A strip that shows what ShowXpress plays and turns [sets] on with one tap.
///
/// Embed it in a screen (Rig Test, Aim). When the tab opens, or ShowXpress
/// opens while the tab is on show, it turns on the first set by itself,
/// unless the show is playing (idle press), the Auto Show runs or a press is
/// already waiting. Change [sets] (a new key) to start over, as Aim does when
/// its mode changes.
///
/// Port of `remRefresh`, `remDraw`, `remAct` and `remPoll` in the old page.
class RemoteRow extends StatefulWidget {
  const RemoteRow({super.key, required this.tab, required this.sets, this.margin = const EdgeInsets.only(bottom: 14)});

  /// The tab this row sits in. It only acts while that tab is on show.
  final String tab;

  /// The first set is the one turned on by itself.
  final List<RemoteSet> sets;

  /// Space around the row. The old `.remrow` has 14 px under it; Rig Test's
  /// row (`style="margin:12px 0 0"`) has 12 px above instead.
  final EdgeInsets margin;

  @override
  State<RemoteRow> createState() => _RemoteRowState();
}

class _RemoteRowState extends State<RemoteRow> {
  RemoteState? _r;
  var _auto = false;
  var _note = '';
  var _busy = false;

  // from the status poll
  bool? _wasOpen;
  String? _remSeen;
  bool _wasOnTab = false;
  DateTime? _wait;

  late final AppState _app = AppScope.read(context);

  /// A press happened lately or one waits, so don't press again by ourselves.
  bool get _recent {
    final s = _app.status;
    if (s == null) return false;
    if (s.pend) return true;
    final at = DateTime.tryParse(s.rem?.at ?? '');
    return at != null && DateTime.now().difference(at) < const Duration(seconds: 60);
  }

  @override
  void initState() {
    super.initState();
    _app.addListener(_follow);
    _app.polled.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    _app.removeListener(_follow);
    _app.polled.removeListener(_follow);
    super.dispose();
  }

  /// Runs on every change of the app's state and on every status poll, which
  /// is its clock for how long ShowXpress has been open. It listens to the
  /// state itself because the row follows ShowXpress while its tab is hidden
  /// too, and a hidden tab's widgets get no rebuilds ([AppScope]).
  void _follow() {
    final app = _app;
    final s = app.status;
    final onTab = app.tab == widget.tab;
    if (onTab && !_wasOnTab) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(auto: app.sxOpen && !_recent));
    _wasOnTab = onTab;
    if (s != null) _poll(s, onTab);
  }

  @override
  void didUpdateWidget(RemoteRow old) {
    super.didUpdateWidget(old);
    if (old.sets.first.label != widget.sets.first.label && _app.tab == widget.tab) _refresh(auto: _app.sxOpen && !_recent);
  }

  /// Port of `remPoll`: follow ShowXpress opening and closing, and the
  /// engine's own presses.
  void _poll(SxStatus s, bool onTab) {
    final rem = s.rem;
    if (rem != null) {
      if (_remSeen != null && rem.at != _remSeen && onTab) {
        final msg = rem.ok
            ? 'SX Studio turned on ${rem.label}. Check the beams.'
            : rem.skipped
            ? "Your show was playing, so ${rem.label} wasn't turned on."
            : '';
        WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(auto: false, note: msg));
      }
      _remSeen = rem.at;
    } else {
      _remSeen ??= '';
    }
    final was = _wasOpen;
    _wasOpen = s.open;
    if (was == false && s.open) _wait = DateTime.now();
    if (was == true && !s.open && _r != null) {
      _r = null;
      if (onTab) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(auto: false));
    }
    final w = _wait;
    if (w != null && onTab && s.open && !_busy) {
      if (DateTime.now().difference(w) > const Duration(seconds: 90)) {
        _wait = null;
      } else if (_r == null || !_r!.connected || (!_auto && !_recent)) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final x = await _refresh(auto: !_recent);
          if (x != null && (x.connected || (x.setup != null && !x.ready))) _wait = null;
        });
      }
    }
  }

  /// Port of `remRefresh`.
  Future<RemoteState?> _refresh({required bool auto, String note = ''}) async {
    if (!mounted || _busy) return null;
    _busy = true;
    final app = _app, s = app.status;
    final doAuto = auto && app.sxOpen && !(s?.auto?.running ?? false) && !(s?.pend ?? false);
    try {
      final r = doAuto ? await app.client.remotePress(widget.sets.first.titles, solo: true, idle: true) : await app.client.remote();
      if (!mounted) return r;
      setState(() {
        _r = r;
        _auto = doAuto;
        _note = note.isNotEmpty ? note : (doAuto && r.connected && !r.skipped && r.pressedNow.isNotEmpty ? 'Turned on by SX Studio.' : '');
      });
      return r;
    } finally {
      _busy = false;
    }
  }

  Future<void> _set(RemoteSet s) async {
    final playing = [
      for (final p in _r?.pressed ?? const <PressedOnAir>[])
        if (!_isSetup(p.page) && !s.titles.contains(p.title)) p.title,
    ];
    if (playing.isNotEmpty) {
      final many = playing.length > 1;
      final ok = await askSx(
        context,
        'Turn off what is playing?',
        '${playing.take(6).join(', ')}${playing.length > 6 ? '...' : ''} ${many ? 'are' : 'is'} playing. Turning on ${s.label} turns ${many ? 'them' : 'it'} off.',
        'Turn on ${s.label}',
      );
      if (!ok) return;
    }
    final r = await _app.client.remotePress(s.titles, solo: true);
    if (mounted) {
      setState(() {
        _r = r;
        _note = '';
        _auto = false;
      });
    }
  }

  Future<void> _off() async {
    final autoOn = _app.status?.auto?.running ?? false;
    final ok = await askSx(
      context,
      'Turn everything off?',
      'Releases every button that is playing in ShowXpress.${autoOn ? ' The Auto Show keeps playing. Stop it in its tab.' : ''}',
      'All off',
    );
    if (!ok) return;
    final r = await _app.client.remoteOff();
    if (mounted) {
      setState(() {
        _r = r;
        _note = '';
        _auto = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final r = _r, sets = widget.sets;

    var text = '';
    final actions = <Widget>[];
    var lead = '';
    IconData? leadIcon;
    var leadAmber = false;
    var isOn = false;
    if (r == null) {
      text = 'Checking ShowXpress.';
    } else if (!r.ok && r.setup == null) {
      text = r.error;
      actions.add(MiniButton('Try again', onPressed: () => _refresh(auto: false)));
    } else if (!r.ready) {
      lead = 'Let SX Studio press ${sets.map((s) => s.label).join(' / ')} for you. ';
      text = "Turn on ShowXpress remote control once. It's saved in the show${app.sxOpen ? ' (done when ShowXpress next closes).' : '.'}";
      actions.add(MiniButton('Turn on remote control', primary: true, onPressed: () => enableRemote(context, after: () async => _refresh(auto: false))));
    } else if (!r.open) {
      text = 'ShowXpress is closed. Open it and SX Studio turns on ${sets.first.label} by itself.';
      actions.add(MiniButton('Launch ShowXpress', onPressed: () => launchSx(context)));
    } else if (!r.connected) {
      text = r.error;
      actions.add(MiniButton('Try again', onPressed: () => _refresh(auto: false)));
    } else {
      final on = {for (final p in r.pressed) p.title}, have = r.titles.toSet();
      final cur = sets.where((s) => s.titles.every(on.contains)).firstOrNull;
      if (_note.isNotEmpty) {
        lead = '$_note ';
        if (_note.startsWith('SX Studio turned on') || _note.startsWith('Turned on')) leadIcon = Icons.check;
      }
      if (r.skipped) {
        lead +=
            'Your show is playing (${r.playing.take(4).join(', ')}${r.playing.length > 4 ? '...' : ''}). SX Studio didn\'t press anything, so it isn\'t cut. ';
        leadAmber = true;
      }
      isOn = cur != null;
      text = cur != null
          ? '${cur.label} is on in ShowXpress.'
          : on.isNotEmpty
          ? 'Playing: ${on.take(5).join(', ')}${on.length > 5 ? '...' : ''}'
          : 'Nothing is playing in ShowXpress.';
      for (final s in sets) {
        final miss = s.titles.any((x) => !have.contains(x));
        final b = MiniButton(s.label, on: identical(cur, s), onPressed: miss ? null : () => _set(s));
        actions.add(miss ? Tooltip(message: 'Not in the show yet', child: b) : b);
      }
      if (on.isNotEmpty) actions.add(MiniButton('All off', onPressed: _off));
    }

    // the old `.remrow`
    return Container(
      width: double.infinity,
      margin: widget.margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Sx.green.withValues(alpha: .05),
        border: Border.all(color: Sx.green.withValues(alpha: .3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text.rich(
            TextSpan(
              children: [
                if (leadIcon != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(leadIcon, size: 15, color: Sx.green),
                    ),
                  ),
                if (lead.isNotEmpty)
                  TextSpan(
                    text: lead,
                    style: TextStyle(color: leadAmber ? Sx.amber : Sx.text, fontWeight: FontWeight.w600),
                  ),
                if (isOn)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Icon(Icons.circle, size: 9, color: Sx.green),
                    ),
                  ),
                TextSpan(
                  text: text,
                  style: TextStyle(color: isOn ? Sx.green : Sx.text2),
                ),
              ],
            ),
            style: TextStyle(fontSize: 13, color: Sx.text2, height: 1.4),
          ),
          ...actions,
        ],
      ),
    );
  }
}
