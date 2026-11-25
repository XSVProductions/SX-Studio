import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// The start screen: a tile per tab, grouped the way a gig night runs.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => ScreenBody(
    children: [
      for (final g in TabGroup.values)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(g.title.toUpperCase(), style: Sx.label),
            ),
            LayoutBuilder(
              builder: (context, box) {
                final columns = box.maxWidth > 900
                    ? 4
                    : box.maxWidth > 560
                    ? 2
                    : 1;
                final width = (box.maxWidth - 12 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final t in tabs.where((t) => t.group == g)) SizedBox(width: width, child: _Tile(t))],
                );
              },
            ),
          ],
        ),
    ],
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.tab);

  final TabDef tab;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    hoverColor: Sx.hover,
    onTap: () => AppScope.read(context).go(tab.id),
    child: Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tab.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(tab.blurb, style: Sx.sub),
        ],
      ),
    ),
  );
}
