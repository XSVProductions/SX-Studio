import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// Speed Faders: which master speed fader each live button follows.
///
/// The pattern every screen follows: load through the client, keep the edits
/// in this State, show what changed, and save with [runSave].
class SpeedScreen extends StatefulWidget {
  const SpeedScreen(BuildContext _, {super.key});

  @override
  State<SpeedScreen> createState() => _SpeedScreenState();
}

class _SpeedScreenState extends State<SpeedScreen> with ShowWatcher {
  SpeedPreview? _data;
  var _error = '';

  /// The fader picked for each button (by section), saved or not.
  final _picked = <String, int>{};

  /// Show only buttons on this fader, or -1 for all.
  var _only = -1;
  var _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void onQueueRan() => _load();

  @override
  void onSxClosed() {
    if (_changed.isEmpty) _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.speed();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
        _picked
          ..clear()
          ..addAll({for (final b in d.buttons) b.sec: b.fader});
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e.message;
      });
    }
    app.setDirty('speed', false);
  }

  List<SpeedButton> get _changed => [...?_data?.buttons.where((b) => _picked[b.sec] != b.fader)];

  void _pick(Iterable<SpeedButton> buttons, int fader) {
    setState(() {
      for (final b in buttons) {
        _picked[b.sec] = fader;
      }
    });
    AppScope.read(context).setDirty('speed', _changed.isNotEmpty);
  }

  void _undo() {
    setState(() => _picked.addAll({for (final b in _data!.buttons) b.sec: b.fader}));
    AppScope.read(context).setDirty('speed', false);
  }

  String _faderName(MasterFader f) => f.caption.isEmpty ? 'Fader ${f.k + 1}' : f.caption;

  /// What a button's row says about how speed affects it, and whether that is a warning.
  (String, bool) _info(SpeedButton b) {
    final beat = b.beat ? ' · beat sync' : '';
    if (b.missing) return ('scene file missing', true);
    if (b.gen) return ('Generator movement$beat', false);
    if (b.steps > 1) return ('${b.steps} steps$beat', false);
    return ('1 step, speed does nothing', true);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    final changed = _changed;
    final q = _query.trim().toLowerCase();
    final shown = [
      ...?d?.buttons.where((b) => (_only < 0 || _picked[b.sec] == _only) && (q.isEmpty || '${b.title} ${b.scene} ${b.pageName}'.toLowerCase().contains(q))),
    ];
    final pages = <int, List<SpeedButton>>{};
    for (final b in shown) {
      pages.putIfAbsent(b.page, () => []).add(b);
    }
    final names = {for (final f in d?.faders ?? const <MasterFader>[]) f.k: _faderName(f)};

    return ScreenBody(
      bar: SaveBar(
        hint: d == null
            ? ''
            : app.sxOpen
            ? 'ShowXpress is open. A save waits until it closes.'
            : changed.isEmpty
            ? 'Every button matches the show.'
            : '${changed.length} button(s) changed. Only the speed fader setting in live.ini changes.',
        actions: [
          TextButton(onPressed: changed.isEmpty ? null : _undo, child: const Text('Undo')),
          FilledButton(
            onPressed: changed.isEmpty
                ? null
                : () => runSave(
                    context,
                    () => app.client.speedApply([for (final b in changed) SpeedChange(sec: b.sec, title: b.title, fader: _picked[b.sec]!)]),
                    what: 'speed',
                    busy: 'Saving speed faders.',
                    after: () async {
                      await _load();
                      app.showEdited();
                    },
                  ),
            child: const Text('Save'),
          ),
        ],
      ),
      children: [
        SxListCard(
          children: [
            SxHeader(
              'Speed faders',
              sub: "Which master speed fader each button follows. Faders only change step timing, so 1-step scenes don't react.",
              actions: [OutlinedButton(onPressed: _load, child: const Text('Refresh'))],
            ),
            ErrorBox(_error),
            if (d == null && _error.isEmpty)
              Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text('Reading the show.', style: Sx.sub),
              ),
            if (d != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in d.faders)
                          _Chip(
                            '${d.buttons.where((b) => _picked[b.sec] == f.k).length}  ${_faderName(f)}',
                            on: _only == f.k,
                            onTap: () => setState(() => _only = _only == f.k ? -1 : f.k),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      decoration: const InputDecoration(hintText: 'Find a button'),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ],
              ),
              for (final buttons in pages.values) ...[
                GroupLabel(
                  buttons.first.pageName,
                  count: buttons.length,
                  trailing: _FaderMenu(names: names, hint: 'Set all on this page', onPick: (k) => _pick(buttons, k)),
                ),
                for (final b in buttons) _row(names, b),
              ],
            ],
          ],
        ),
      ],
    );
  }

  Widget _row(Map<int, String> names, SpeedButton b) {
    final (info, warn) = _info(b);
    final isChanged = _picked[b.sec] != b.fader;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Sx.line)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              b.title,
              style: TextStyle(fontWeight: FontWeight.w600, color: isChanged ? Sx.accent : Sx.text),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(info, style: TextStyle(fontSize: 13, color: warn ? Sx.amber : Sx.dim)),
          ),
          _FaderMenu(names: names, value: _picked[b.sec], onPick: (k) => _pick([b], k)),
        ],
      ),
    );
  }
}

/// A fader dropdown. With [hint] it is an action ("Set all on this page")
/// and shows no value.
class _FaderMenu extends StatelessWidget {
  const _FaderMenu({required this.names, required this.onPick, this.value, this.hint});

  /// Each fader's number and name.
  final Map<int, String> names;
  final ValueChanged<int> onPick;
  final int? value;
  final String? hint;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    height: 34,
    child: SxMenu<int>(
      items: names,
      value: hint == null ? value : null,
      hint: hint ?? '',
      onPick: onPick,
      fontSize: 13.5,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.on, required this.onTap});

  final String text;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: on ? Sx.accent : Sx.text2)),
    ),
  );
}
