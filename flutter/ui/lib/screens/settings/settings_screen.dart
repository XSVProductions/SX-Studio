import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'drive_card.dart';
import 'phone_card.dart';
import 'settings_bits.dart';
import 'settings_model.dart';
import 'update_card.dart';

/// Settings (the cogwheel): the tabs, Google Drive, phones and tablets,
/// ShowXpress and updates. A phone sees the tabs and Google Drive only.
/// Every change saves straight away.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => ScreenBody(
        children: [
          SxCard(
            child: SxHeader(
              'Settings',
              sub: m.error.isNotEmpty
                  ? null
                  : m.loaded
                  ? 'The tab order is the same on this computer, the phone and the iPad.'
                  : 'Reading the settings.',
            ),
          ),
          if (m.error.isNotEmpty) ErrorBox(m.error),
          if (m.loaded) ...[
            _TabsCard(m),
            const DriveCard(),
            if (!m.phone) ...[const PhoneCard(), _SxCard(m), const UpdateCard()],
          ],
        ],
      ),
    );
  }
}

/// Order, show or hide, and rename the tabs.
class _TabsCard extends StatefulWidget {
  const _TabsCard(this.m);

  final SettingsModel m;

  @override
  State<_TabsCard> createState() => _TabsCardState();
}

class _TabsCardState extends State<_TabsCard> {
  final _names = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  var _error = '';

  SettingsModel get m => widget.m;

  @override
  void dispose() {
    for (final c in _names.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save(SettingsChange change) async {
    final err = await m.save(change);
    if (mounted) setState(() => _error = err);
  }

  List<String> get _hidden => [
    for (final t in m.ordered())
      if (m.hidden(t)) t.id,
  ];

  void _move(List<TabDef> order, int i, int by) {
    final ids = [for (final t in order) t.id];
    final j = i + by;
    final a = ids[i];
    ids[i] = ids[j];
    ids[j] = a;
    _save(SettingsChange(tabOrder: ids, tabHidden: _hidden));
  }

  void _show(TabDef t, bool on) =>
      _save(SettingsChange(tabOrder: [for (final x in m.ordered()) x.id], tabHidden: on ? [..._hidden.where((id) => id != t.id)] : [..._hidden, t.id]));

  /// Every typed name that differs from the tab's own, cleaned like the old page.
  void _rename() {
    final names = <String, String>{};
    for (final t in tabs) {
      var v = (_names[t.id]?.text ?? '').replaceAll(RegExp('[<>]'), '').trim();
      if (v.length > 24) v = v.substring(0, 24);
      if (v.isNotEmpty && v != t.name) names[t.id] = v;
    }
    _save(SettingsChange(tabOrder: [for (final x in m.ordered()) x.id], tabHidden: _hidden, tabNames: names));
  }

  Future<void> _reset() async {
    if (m.settings.tabNames.isNotEmpty &&
        !await confirm(context, 'Reset the tabs?', 'Every tab gets its first place and name back, and hidden tabs show again.', 'Reset')) {
      return;
    }
    await _save(SettingsChange(tabOrder: [for (final t in tabs) t.id], tabHidden: const [], tabNames: const {}));
  }

  @override
  Widget build(BuildContext context) {
    final order = m.ordered();
    final rows = <Widget>[];
    for (final (i, t) in order.indexed) {
      final first = i == 0 || order[i - 1].group != t.group;
      final last = i == order.length - 1 || order[i + 1].group != t.group;
      if (first) rows.add(GroupLabel(t.group.title));
      rows.add(_row(order, i, t, first: first, last: last));
    }
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SxHeader(
            'Tabs',
            sub:
                'The tabs are in four menus along the top. Use the arrows to change the order in a menu, and type in a name to rename the tab (empty gives it its own name back). '
                'Untick a tab to hide it. It leaves the Home page too.',
            actions: [OutlinedButton(onPressed: _reset, child: const Text('Reset'))],
          ),
          ErrorBox(_error),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(List<TabDef> order, int i, TabDef t, {required bool first, required bool last}) {
    final c = _names.putIfAbsent(t.id, TextEditingController.new);
    final f = _focus.putIfAbsent(t.id, () {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus && (_names[t.id]!.text.trim()) != m.nameOf(t)) _rename();
      });
      return node;
    });
    if (!f.hasFocus && c.text != m.nameOf(t)) c.text = m.nameOf(t);
    final hidden = m.hidden(t);
    final renamed = m.nameOf(t) != t.name;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Sx.line)),
      ),
      child: Row(
        children: [
          Checkbox(value: !hidden, onChanged: (v) => _show(t, v ?? true)),
          Expanded(
            child: TextField(
              controller: c,
              focusNode: f,
              maxLength: 24,
              style: TextStyle(color: hidden ? Sx.mute : Sx.text),
              decoration: InputDecoration(
                hintText: t.name,
                counterText: '',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                filled: false,
                suffixText: renamed ? t.name : null,
                suffixStyle: const TextStyle(color: Sx.mute, fontSize: 12),
              ),
              onSubmitted: (_) => f.unfocus(),
            ),
          ),
          IconButton(
            tooltip: 'Move up',
            visualDensity: VisualDensity.compact,
            onPressed: first ? null : () => _move(order, i, -1),
            icon: const Icon(Icons.arrow_drop_up),
          ),
          IconButton(
            tooltip: 'Move down',
            visualDensity: VisualDensity.compact,
            onPressed: last ? null : () => _move(order, i, 1),
            icon: const Icon(Icons.arrow_drop_down),
          ),
        ],
      ),
    );
  }
}

/// After queued changes, open ShowXpress again; open the show folder.
class _SxCard extends StatefulWidget {
  const _SxCard(this.m);

  final SettingsModel m;

  @override
  State<_SxCard> createState() => _SxCardState();
}

class _SxCardState extends State<_SxCard> {
  var _show = '';
  var _error = '';

  @override
  void initState() {
    super.initState();
    AppScope.read(context).client.gdrive().then((g) {
      if (mounted) setState(() => _show = g.show);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SxHeader('ShowXpress'),
          const SizedBox(height: 6),
          CheckRow(
            'After queued changes are done, open ShowXpress again',
            value: widget.m.settings.reopen,
            onChanged: (v) async {
              final err = await widget.m.save(SettingsChange(reopen: v));
              if (mounted) setState(() => _error = err);
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () async {
                  final r = await app.client.openOnComputer(OpenTarget.show);
                  if (mounted) setState(() => _error = r.ok ? '' : r.error);
                },
                child: const Text('Open the show folder'),
              ),
              if (_show.isNotEmpty) Text(_show, style: Sx.sub),
            ],
          ),
          ErrorBox(_error),
        ],
      ),
    );
  }
}
