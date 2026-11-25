import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'tabs.dart';
import 'theme.dart';
import 'widgets/sx_widgets.dart';

/// The frame around every screen: brand and ShowXpress status on top, the tab
/// bar under it, then the tab on show.
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _Header(),
            const _TabBar(),
            const Divider(height: 1, thickness: 1, color: Sx.line),
            if (!app.connected) const _Strip("Can't reach the laptop. Trying again.", Sx.amber),
            if (app.status case final s? when s.queue.items.isNotEmpty)
              _Strip('${s.queue.items.length} save(s) waiting for ShowXpress to close: ${s.queue.items.map((i) => i.label).join(', ')}', Sx.blue),
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

class _Strip extends StatelessWidget {
  const _Strip(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Sx.line)),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 13)),
  );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final open = app.sxOpen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 10),
      child: Row(
        children: [
          InkWell(
            onTap: () => app.go('home'),
            child: Row(
              children: [
                Image.asset('assets/img/sx_mark.png', height: 30, filterQuality: FilterQuality.medium),
                const SizedBox(width: 10),
                const Text(
                  'STUDIO',
                  style: TextStyle(fontFamily: Sx.display, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 4, color: Sx.text2),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (app.status != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: (open ? Sx.amber : Sx.green).withValues(alpha: .09),
                border: Border.all(color: (open ? Sx.amber : Sx.green).withValues(alpha: .38)),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                open ? 'ShowXpress open' : 'ShowXpress closed ✓',
                style: TextStyle(color: open ? Sx.amber : Sx.green, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => runSave(context, open ? () => app.client.sxClose() : app.client.sxLaunch),
              child: Text(open ? 'Close ShowXpress' : 'Launch ShowXpress'),
            ),
          ],
          IconButton(
            onPressed: () => app.go('settings'),
            icon: const Icon(Icons.settings, size: 20, color: Sx.dim),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Row(
          children: [
            _TabButton('Home', on: app.tab == 'home', onTap: () => app.go('home')),
            for (final g in TabGroup.values)
              MenuAnchor(
                menuChildren: [
                  for (final t in tabs.where((t) => t.group == g))
                    MenuItemButton(
                      onPressed: () => app.go(t.id),
                      child: Text(
                        app.dirtyTabs.contains(t.id) ? '${t.name}  (unsaved)' : t.name,
                        style: TextStyle(color: app.tab == t.id ? Sx.accent : Sx.text),
                      ),
                    ),
                ],
                builder: (context, menu, _) {
                  final current = tabs.where((t) => t.group == g && t.id == app.tab).firstOrNull;
                  return _TabButton(
                    current == null ? g.title : '${g.title}: ${current.name}',
                    on: current != null,
                    menu: true,
                    onTap: () => menu.isOpen ? menu.close() : menu.open(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton(this.text, {required this.on, required this.onTap, this.menu = false});

  final String text;
  final bool on;
  final bool menu;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    hoverColor: Sx.hover,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: on ? Sx.accent : Colors.transparent, width: 2)),
      ),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: .3, color: on ? Sx.text : Sx.dim),
          ),
          if (menu)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.arrow_drop_down, size: 16, color: Sx.mute),
            ),
        ],
      ),
    ),
  );
}
