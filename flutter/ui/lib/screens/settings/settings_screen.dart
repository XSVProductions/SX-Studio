import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'config_card.dart';
import 'drive_card.dart';
import 'phone_card.dart';
import 'settings_bits.dart';
import 'settings_model.dart';
import 'update_card.dart';

/// Settings (the cogwheel, `#v-settings`): light or dark, the tabs, Google
/// Drive, phones and tablets, ShowXpress and updates. A phone sees the look,
/// the tabs and Google Drive. Every change saves straight away.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = SettingsModel.of(app);
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => ScreenBody(
        children: [
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SetTitle('Settings', icon: Icons.settings),
                const SizedBox(height: 4),
                Text(
                  m.loaded
                      ? 'Light or dark is set for each device. The tab order is the same on this computer, the phone and the iPad.'
                      : m.error.isEmpty
                      ? 'Reading the settings.'
                      : '',
                  style: Sx.sub,
                ),
                ErrorBox(m.error),
              ],
            ),
          ),
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SetTitle('Look'),
                const SizedBox(height: 4),
                Text('Light is easier to read in daylight; dark is kinder in a dark venue.', style: Sx.sub),
                const SizedBox(height: 12),
                Seg<ThemeMode>(
                  value: app.themeMode,
                  options: const {ThemeMode.dark: 'Dark', ThemeMode.light: 'Light', ThemeMode.system: 'Same as this device'},
                  onChanged: app.setThemeMode,
                ),
              ],
            ),
          ),
          if (m.loaded) ...[
            _TabsCard(m),
            const DriveCard(),
            if (!m.phone) ...[const PhoneCard(), _SxCard(m), const UpdateCard(), const ConfigCard()],
          ],
        ],
      ),
    );
  }
}

/// Order, show or hide, and rename the tabs (`#stabs`).
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

  List<String> get _order => [for (final t in m.ordered()) t.id];

  List<String> get _hidden => [
    for (final t in m.ordered())
      if (m.hidden(t)) t.id,
  ];

  void _move(int i, int by) {
    final ids = _order;
    final a = ids[i];
    ids[i] = ids[i + by];
    ids[i + by] = a;
    _save(SettingsChange(tabOrder: ids, tabHidden: _hidden));
  }

  void _show(TabDef t, bool on) => _save(SettingsChange(tabOrder: _order, tabHidden: on ? [..._hidden.where((id) => id != t.id)] : [..._hidden, t.id]));

  /// Every typed name that differs from the tab's own, cleaned like the old
  /// page (`namesNow`).
  void _rename() {
    final names = <String, String>{};
    for (final t in tabs) {
      var v = (_names[t.id]?.text ?? '').replaceAll(RegExp('[<>]'), '').trim();
      if (v.length > 24) v = v.substring(0, 24);
      if (v.isNotEmpty && v != t.name) names[t.id] = v;
    }
    _save(SettingsChange(tabOrder: _order, tabHidden: _hidden, tabNames: names));
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
      if (first) {
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(2, i == 0 ? 0 : 10, 2, 0),
            child: Text(
              t.group.title.toUpperCase(),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: Sx.mute),
            ),
          ),
        );
      }
      rows.add(_row(i, t, first: first, last: last));
    }
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SetTitle('Tabs'),
                    const SizedBox(height: 4),
                    Text(
                      'The tabs are in four menus along the top. Use the arrows to change the order in a menu, and type a new name to rename a tab '
                      '(Enter to keep it, empty gives it its own name back). Untick a tab to hide it (it leaves the Home page too).',
                      style: Sx.sub,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              MiniButton('Reset', onPressed: _reset),
            ],
          ),
          ErrorBox(_error),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 6), child: r)],
            ),
          ),
        ],
      ),
    );
  }

  /// One tab, the old `.tabrow`.
  Widget _row(int i, TabDef t, {required bool first, required bool last}) {
    final c = _names.putIfAbsent(t.id, TextEditingController.new);
    final f = _focus.putIfAbsent(t.id, () {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus && _names[t.id]!.text.trim() != m.nameOf(t)) _rename();
      });
      return node;
    });
    if (!f.hasFocus && c.text != m.nameOf(t)) c.text = m.nameOf(t);
    final hidden = m.hidden(t);
    final renamed = m.nameOf(t) != t.name;
    final field = OutlineInputBorder(
      borderRadius: BorderRadius.circular(7),
      borderSide: const BorderSide(color: Colors.transparent),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(
              value: !hidden,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => _show(t, v ?? true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: c,
              focusNode: f,
              maxLength: 24,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: hidden ? Sx.mute : Sx.text),
              decoration: InputDecoration(
                hintText: t.name,
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: Sx.well,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: field,
                enabledBorder: field,
                focusedBorder: field.copyWith(borderSide: BorderSide(color: Sx.accent)),
              ),
              onSubmitted: (_) => f.unfocus(),
            ),
          ),
          if (renamed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(t.name, style: TextStyle(color: Sx.mute, fontSize: 11.5)),
            ),
          const SizedBox(width: 8),
          _Arrow(Icons.arrow_drop_up, 'Move up', first ? null : () => _move(i, -1)),
          const SizedBox(width: 4),
          _Arrow(Icons.arrow_drop_down, 'Move down', last ? null : () => _move(i, 1)),
        ],
      ),
    );
  }
}

/// The small up and down buttons of a tab row (`.tabrow .mini`).
class _Arrow extends StatelessWidget {
  const _Arrow(this.icon, this.tip, this.onPressed);

  final IconData icon;
  final String tip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(32, 26),
        fixedSize: const Size(32, 26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        backgroundColor: Sx.hover,
        foregroundColor: Sx.text,
        disabledForegroundColor: Sx.mute,
        side: BorderSide(color: Sx.line),
      ),
      child: Icon(icon, size: 18),
    ),
  );
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
          const SetTitle('ShowXpress'),
          const SizedBox(height: 10),
          LinkCheck(
            'After queued changes are done, open ShowXpress again',
            value: widget.m.settings.reopen,
            onChanged: (v) async {
              final err = await widget.m.save(SettingsChange(reopen: v));
              if (mounted) setState(() => _error = err);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              MiniButton(
                'Open the show folder',
                onPressed: () async {
                  final r = await app.client.openOnComputer(OpenTarget.show);
                  if (mounted) setState(() => _error = r.ok ? '' : r.error);
                },
              ),
              if (_show.isNotEmpty) Text(_show, style: TextStyle(fontSize: 13, color: Sx.dim)),
            ],
          ),
          ErrorBox(_error),
        ],
      ),
    );
  }
}
