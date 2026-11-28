import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'config_card.dart';
import 'dmx_output_card.dart';
import 'drive_card.dart';
import 'phone_card.dart';
import 'settings_bits.dart';
import 'settings_model.dart';
import 'update_card.dart';

/// Settings (the cogwheel, `#v-settings`): light or dark, the tabs, Google
/// Drive, phones and tablets, ShowXpress and updates. A phone sees the look,
/// the tabs and Google Drive. Every change saves straight away.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Holds the tab rows' name fields, so a name being typed survives its row
/// scrolling away. The Tabs card is a lazy list, one row per tab.
class _SettingsScreenState extends State<SettingsScreen> {
  final _names = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  var _tabsError = '';

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
            _tabsCard(m),
            const DriveCard(),
            if (!m.phone) ...[const PhoneCard(), _SxCard(m), const DmxOutputCard(), const UpdateCard(), const ConfigCard()],
          ],
        ],
      ),
    );
  }

  // The Tabs card (`#stabs`): order, show or hide, and rename the tabs.

  Future<void> _save(SettingsModel m, SettingsChange change) async {
    final err = await m.save(change);
    if (mounted) setState(() => _tabsError = err);
  }

  List<String> _order(SettingsModel m) => [for (final t in m.ordered()) t.id];

  List<String> _hidden(SettingsModel m) => [
    for (final t in m.ordered())
      if (m.hidden(t)) t.id,
  ];

  void _move(SettingsModel m, int i, int by) {
    final ids = _order(m);
    final a = ids[i];
    ids[i] = ids[i + by];
    ids[i + by] = a;
    _save(m, SettingsChange(tabOrder: ids, tabHidden: _hidden(m)));
  }

  void _show(SettingsModel m, TabDef t, bool on) =>
      _save(m, SettingsChange(tabOrder: _order(m), tabHidden: on ? [..._hidden(m).where((id) => id != t.id)] : [..._hidden(m), t.id]));

  /// Every typed name that differs from the tab's own, cleaned like the old
  /// page (`namesNow`).
  void _rename(SettingsModel m) {
    final names = <String, String>{};
    for (final t in tabs) {
      var v = (_names[t.id]?.text ?? '').replaceAll(RegExp('[<>]'), '').trim();
      if (v.length > 24) v = v.substring(0, 24);
      if (v.isNotEmpty && v != t.name) names[t.id] = v;
    }
    _save(m, SettingsChange(tabOrder: _order(m), tabHidden: _hidden(m), tabNames: names));
  }

  Future<void> _reset(SettingsModel m) async {
    if (m.settings.tabNames.isNotEmpty &&
        !await confirm(context, 'Reset the tabs?', 'Every tab gets its first place and name back, and hidden tabs show again.', 'Reset')) {
      return;
    }
    await _save(m, SettingsChange(tabOrder: [for (final t in tabs) t.id], tabHidden: const [], tabNames: const {}));
  }

  /// The card's heading, then a row per menu name and per tab.
  SxListCard _tabsCard(SettingsModel m) {
    final order = m.ordered();
    // the rows are at most 520 wide, with 6 under each
    Widget line(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(padding: const EdgeInsets.only(bottom: 6), child: child),
    );
    return SxListCard(
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
            MiniButton('Reset', onPressed: () => _reset(m)),
          ],
        ),
        ErrorBox(_tabsError),
        const SizedBox(height: 12),
        for (final (i, t) in order.indexed) ...[
          if (i == 0 || order[i - 1].group != t.group)
            line(
              Padding(
                padding: EdgeInsets.fromLTRB(2, i == 0 ? 0 : 10, 2, 0),
                child: Text(
                  t.group.title.toUpperCase(),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: Sx.mute),
                ),
              ),
            ),
          line(_row(m, i, t, first: i == 0 || order[i - 1].group != t.group, last: i == order.length - 1 || order[i + 1].group != t.group)),
        ],
      ],
    );
  }

  /// One tab, the old `.tabrow`.
  Widget _row(SettingsModel m, int i, TabDef t, {required bool first, required bool last}) {
    final c = _names.putIfAbsent(t.id, TextEditingController.new);
    final f = _focus.putIfAbsent(t.id, () {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus && _names[t.id]!.text.trim() != m.nameOf(t)) _rename(m);
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
              onChanged: (v) => _show(m, t, v ?? true),
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
          _Arrow(Icons.arrow_drop_up, 'Move up', first ? null : () => _move(m, i, -1)),
          const SizedBox(width: 4),
          _Arrow(Icons.arrow_drop_down, 'Move down', last ? null : () => _move(m, i, 1)),
        ],
      ),
    );
  }
}

/// The small up and down buttons of a tab row (`.tabrow .mini`). Drawn
/// plainly: an `OutlinedButton` with a `Tooltip` is some 45 widgets, and
/// there are two on every row. [tip] is for screen readers.
class _Arrow extends StatelessWidget {
  const _Arrow(this.icon, this.tip, this.onPressed);

  final IconData icon;
  final String tip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onPressed,
        child: Semantics(
          button: true,
          enabled: on,
          label: tip,
          child: Container(
            width: 32,
            height: 26,
            decoration: ShapeDecoration(
              color: on ? Sx.hover : null,
              shape: StadiumBorder(side: BorderSide(color: Sx.line)),
            ),
            child: Icon(icon, size: 18, color: on ? Sx.text : Sx.mute),
          ),
        ),
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
