import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';

// Pieces shared by Tonight's Rig, Skip Flash and Rig Test.

/// Light accent and blue fills for "on" tiles.
const rigOnFill = Color(0x21A3E635);
const rigBlueFill = Color(0x1F5096FF);

/// One moving head as a tappable tile: its number, a word under it, and a
/// blue dot when it differs from what is saved.
class HeadTile extends StatelessWidget {
  const HeadTile({
    super.key,
    required this.title,
    this.sub,
    required this.on,
    required this.changed,
    this.onTap,
    this.onColor = Sx.accent,
    this.onFill = rigOnFill,
    this.extra,
  });

  final String title;
  final String? sub;
  final bool on;
  final bool changed;
  final VoidCallback? onTap;
  final Color onColor;
  final Color onFill;

  /// Shown under the title instead of [sub], for tiles with their own buttons.
  final Widget? extra;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    selected: on,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(2, 9, 2, 8),
        decoration: BoxDecoration(
          color: on ? onFill : Sx.panel,
          border: Border.all(color: on ? onColor : Sx.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: on ? Sx.text : Sx.mute),
                  ),
                  if (extra != null) extra! else if (sub != null) Text(sub!, style: TextStyle(fontSize: 11, color: on ? onColor : Sx.mute)),
                ],
              ),
            ),
            if (changed) const Positioned(top: -3, right: 5, child: _Dot()),
          ],
        ),
      ),
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'changed, not saved yet',
    child: Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(color: Sx.blue, shape: BoxShape.circle),
    ),
  );
}

/// Tiles in equal columns: 8 across on a wide screen, 4 on a phone.
class HeadGrid extends StatelessWidget {
  const HeadGrid({super.key, required this.children, this.wideCols = 8, this.narrowCols = 4});

  final List<Widget> children;
  final int wideCols;
  final int narrowCols;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth >= 620 ? wideCols : narrowCols;
      const gap = 8.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in children) SizedBox(width: w, child: t)],
      );
    },
  );
}

/// A model's heading over its tiles ("140SR  3 of 16 hung") with All and None.
class HeadGroupHeader extends StatelessWidget {
  const HeadGroupHeader(this.name, this.count, {super.key, this.onAll, this.onNone});

  final String name;
  final String count;
  final VoidCallback? onAll;
  final VoidCallback? onNone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Row(
      children: [
        Text(name, style: Sx.label),
        const SizedBox(width: 10),
        Text(count, style: const TextStyle(color: Sx.dim, fontSize: 12)),
        const Spacer(),
        if (onAll != null) MiniButton('All', onAll),
        if (onNone != null) MiniButton('None', onNone),
      ],
    ),
  );
}

/// A small text button for rows of tiles.
class MiniButton extends StatelessWidget {
  const MiniButton(this.text, this.onPressed, {super.key});

  final String text;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    ),
    child: Text(text),
  );
}

/// "Not saved yet" or "Matches the show", next to a card's title.
class StateTag extends StatelessWidget {
  const StateTag(this.dirty, {super.key});

  final bool dirty;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(dirty ? '● Not saved yet' : '✓ Matches the show', style: TextStyle(fontSize: 12.5, color: dirty ? Sx.blue : Sx.green)),
  );
}

/// Loads the screen again each time its tab comes back into view, unless it
/// holds unsaved edits. Saves in one rig tab change what the others show.
mixin ReloadWhenShown<T extends StatefulWidget> on State<T> {
  String get tabId;
  bool get dirty;
  Future<void> load();

  AppState? _app;
  var _wasShown = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (identical(app, _app)) return;
    _app?.removeListener(_onApp);
    _app = app..addListener(_onApp);
    _wasShown = app.tab == tabId;
  }

  void _onApp() {
    final shown = _app!.tab == tabId;
    if (shown && !_wasShown && !dirty) load();
    _wasShown = shown;
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    super.dispose();
  }
}
