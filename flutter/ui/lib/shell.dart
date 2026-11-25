import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'queue_bar.dart';
import 'tabs.dart';
import 'theme.dart';
import 'widgets/sx_widgets.dart';

/// The frame around every screen, laid out like the old app's page: brand and
/// ShowXpress status on top, the tab bar under them, the queue bar, then the
/// tab on show.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// Tabs opened so far, in order. Their screens stay alive so unsaved edits
  /// survive a trip to another tab.
  final _opened = <String>['home'];

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!_opened.contains(app.tab)) _opened.add(app.tab);
    final gutter = sxGutter(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _Header(),
            if (!app.connected)
              Container(
                width: double.infinity,
                margin: EdgeInsets.fromLTRB(gutter, 14, gutter, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: Sx.tint(Sx.amber, radius: 12),
                child: Text("Can't reach the laptop. Trying again.", style: TextStyle(color: Sx.amber, fontSize: 13)),
              ),
            const QueueBar(),
            Expanded(
              child: IndexedStack(
                index: _opened.indexOf(app.tab),
                children: [
                  for (final id in _opened)
                    KeyedSubtree(
                      key: ValueKey(id),
                      child: Builder(builder: (c) => buildTab(c, id)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The logo shown in the light theme. It is chrome on transparent, made for a
/// dark page, so the old app darkens it (`brightness(.62) contrast(1.25)`).
const _darkenMark = ColorFilter.matrix([.775, 0, 0, 0, -31.875, 0, .775, 0, 0, -31.875, 0, 0, .775, 0, -31.875, 0, 0, 0, 1, 0]);

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final open = app.sxOpen;
    final gutter = sxGutter(context);
    final mark = Image.asset('assets/img/sx_mark.png', height: gutter < 22 ? 30 : 38, filterQuality: FilterQuality.medium);
    final state = open ? Sx.amber : Sx.green;
    return Container(
      decoration: BoxDecoration(
        color: Sx.bg,
        border: Border(bottom: BorderSide(color: Sx.line)),
      ),
      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              InkWell(
                onTap: () => app.go('home'),
                hoverColor: Colors.transparent,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Sx.isLight ? ColorFiltered(colorFilter: _darkenMark, child: mark) : mark,
                    const SizedBox(width: 10),
                    Text(
                      'STUDIO',
                      style: TextStyle(fontFamily: Sx.display, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 4, color: Sx.text2),
                    ),
                  ],
                ),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (app.status != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: Sx.tint(state, radius: 99),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            open ? 'ShowXpress is open' : 'ShowXpress closed',
                            style: TextStyle(color: state, fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                          if (!open)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(Icons.check, size: 14, color: state),
                            ),
                        ],
                      ),
                    ),
                    open
                        ? MiniButton('Close ShowXpress', icon: Icons.stop, onPressed: () => runSave(context, () => app.client.sxClose(), quiet: true))
                        : MiniButton('Launch ShowXpress', icon: Icons.play_arrow, onPressed: () => runSave(context, app.client.sxLaunch, quiet: true)),
                  ],
                  Tooltip(
                    message: 'Settings',
                    child: InkWell(
                      onTap: () => app.go('settings'),
                      customBorder: const CircleBorder(),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Sx.hover,
                          shape: BoxShape.circle,
                          border: Border.all(color: app.tab == 'settings' ? Sx.accent : Sx.line),
                        ),
                        child: Icon(Icons.settings, size: 17, color: app.tab == 'settings' ? Sx.accent : Sx.text),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const _TabBar(),
        ],
      ),
    );
  }
}

/// Home, then one menu per group. A group that holds the tab on show says
/// which one ("Rig & Control · Speed Faders").
class _TabBar extends StatelessWidget {
  const _TabBar();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final pad = EdgeInsets.symmetric(horizontal: width >= 1300 ? 14 : 10, vertical: 7);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Wrap(
        spacing: 3,
        runSpacing: 3,
        children: [
          SegButton(on: app.tab == 'home', onTap: () => app.go('home'), padding: pad, child: const Text('Home')),
          for (final g in TabGroup.values)
            MenuAnchor(
              alignmentOffset: const Offset(0, 7),
              menuChildren: [
                for (final t in tabs.where((t) => t.group == g))
                  MenuItemButton(
                    onPressed: () => app.go(t.id),
                    style: MenuItemButton.styleFrom(
                      foregroundColor: app.tab == t.id ? Sx.accent : Sx.dim,
                      overlayColor: Sx.tabOn,
                      minimumSize: const Size(200, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: .3),
                    ),
                    child: Text(app.dirtyTabs.contains(t.id) ? '${t.name}  (unsaved)' : t.name),
                  ),
              ],
              builder: (context, menu, _) {
                final current = tabs.where((t) => t.group == g && t.id == app.tab).firstOrNull;
                return SegButton(
                  on: current != null,
                  onTap: () => menu.isOpen ? menu.close() : menu.open(),
                  padding: pad,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A phone has no room for both, so it shows the tab's name only.
                      if (current == null || width > 620) Text(g.title, style: current == null ? null : TextStyle(color: Sx.dim)),
                      if (current != null && width > 620) Text('  ·  ', style: TextStyle(color: Sx.mute)),
                      if (current != null) Text(current.name),
                      Icon(Icons.arrow_drop_down, size: 16, color: Sx.mute),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
