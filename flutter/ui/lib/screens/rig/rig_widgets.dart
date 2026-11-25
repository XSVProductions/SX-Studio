import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

// Pieces shared by Tonight's Rig, Strobe and Rig Test.

/// True below the old page's 760 px break, where head tiles go 4 across.
bool rigNarrow(BuildContext context) => MediaQuery.sizeOf(context).width <= 760;

/// One moving head as a tappable tile, the old app's `.hd`: its number, a
/// word under it, and a blue dot when it differs from what is saved.
class HeadTile extends StatelessWidget {
  const HeadTile({super.key, required this.title, this.sub, required this.on, required this.changed, this.onTap, this.blue = false, this.extra});

  final String title;
  final String? sub;
  final bool on;
  final bool changed;
  final VoidCallback? onTap;

  /// The reversed-heads look (`.fxg .hd`): blue when on, tighter padding.
  final bool blue;

  /// Shown under the title instead of [sub], for tiles with their own buttons.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final onColor = blue ? Sx.blue : Sx.accent;
    final phone = MediaQuery.sizeOf(context).width <= 640;
    return Semantics(
      button: onTap != null,
      selected: on,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: blue ? const EdgeInsets.fromLTRB(2, 10, 2, 8) : EdgeInsets.fromLTRB(2, phone ? 11 : 12, 2, phone ? 9 : 10),
          decoration: BoxDecoration(
            color: on ? onColor.withValues(alpha: blue ? .12 : .13) : Sx.panel,
            border: Border.all(color: on ? onColor : Sx.line),
            borderRadius: BorderRadius.circular(12),
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
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: phone ? 16 : 17, color: on ? Sx.text : Sx.mute),
                    ),
                    if (extra != null)
                      extra!
                    else if (sub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          sub!,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: on ? onColor : Sx.mute),
                        ),
                      ),
                  ],
                ),
              ),
              if (changed)
                Positioned(
                  top: -5,
                  right: 6,
                  child: Tooltip(
                    message: 'changed - not saved yet',
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: Sx.blue, shape: BoxShape.circle),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiles in equal columns, the old app's `.heads`: 8 across, 4 on a narrow screen.
class HeadGrid extends StatelessWidget {
  const HeadGrid({super.key, required this.children, this.wideCols = 8, this.narrowCols = 4, this.gap});

  final List<Widget> children;
  final int wideCols;
  final int narrowCols;

  /// Space between tiles. Defaults to 8, or 6 on a phone.
  final double? gap;

  @override
  Widget build(BuildContext context) {
    final cols = rigNarrow(context) ? narrowCols : wideCols;
    final g = gap ?? (MediaQuery.sizeOf(context).width <= 640 ? 6.0 : 8.0);
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - g * (cols - 1)) / cols;
        return Wrap(
          spacing: g,
          runSpacing: g,
          children: [for (final t in children) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}

/// A model's heading over its tiles, the old app's `.gh`: "140SR  3 of 16 hung",
/// then All and None on the right.
class HeadGroupHeader extends StatelessWidget {
  const HeadGroupHeader(this.name, this.count, {super.key, this.onAll, this.onNone});

  final String name;
  final String count;
  final VoidCallback? onAll;
  final VoidCallback? onNone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Row(
      children: [
        Text(name.toUpperCase(), style: Sx.label),
        const SizedBox(width: 8),
        Text(count, style: TextStyle(color: Sx.mute, fontSize: 12)),
        const Spacer(),
        if (onAll != null) MiniButton('All', onPressed: onAll),
        if (onNone != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: MiniButton('None', onPressed: onNone),
          ),
      ],
    ),
  );
}

/// "Not saved yet" or "Matches the show", the old app's `.state` pill.
class StateTag extends StatelessWidget {
  const StateTag(this.dirty, {super.key});

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final c = dirty ? Sx.blue : Sx.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: dirty ? .45 : .35)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(dirty ? Icons.circle : Icons.check, size: dirty ? 8 : 14, color: c),
          const SizedBox(width: 5),
          Text(
            dirty ? 'Not saved yet' : 'Matches the show',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

/// A card's top row as the rig tabs have it: title and explanation, then the
/// saved/unsaved pill and Refresh. On a phone the pill goes under the text.
class RigHeader extends StatelessWidget {
  const RigHeader(this.title, {super.key, this.sub, this.subText, this.dirty, required this.onRefresh});

  final String title;
  final String? sub;

  /// Used instead of [sub] when the explanation has bold words.
  final Widget? subText;

  /// Null hides the pill (while loading or after an error).
  final bool? dirty;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Sx.title),
        const SizedBox(height: 4),
        subText ?? Text(sub ?? '', style: Sx.sub),
      ],
    );
    final refresh = OutlinedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh, size: 17), label: const Text('Refresh'));
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          text,
          const SizedBox(height: 10),
          Row(children: [if (dirty != null) StateTag(dirty!), const Spacer(), refresh]),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: text),
        if (dirty != null) Padding(padding: const EdgeInsets.only(left: 10), child: StateTag(dirty!)),
        Padding(padding: const EdgeInsets.only(left: 10), child: refresh),
      ],
    );
  }
}

/// A box with a dashed 1 px border, like CSS `border: 1px dashed`. Flutter's
/// own borders are solid only.
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.color, this.radius = 3, this.fill, this.padding, this.child});

  final Color color;
  final double radius;
  final Color? fill;
  final EdgeInsets? padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _Dashes(color, radius, fill),
    child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
  );
}

class _Dashes extends CustomPainter {
  _Dashes(this.color, this.radius, this.fill);

  final Color color;
  final double radius;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius((Offset.zero & size).deflate(.5), Radius.circular(radius));
    if (fill != null) canvas.drawRRect(r, Paint()..color = fill!);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in (Path()..addRRect(r)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), pen);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color || old.radius != radius || old.fill != fill;
}

/// When the rig tabs read the show again, as the old page's poll did:
///
/// - the queue saved into the show (`reloadAll`): always, unsaved edits
///   included, since the queue just saved them;
/// - ShowXpress closed: unless the screen holds unsaved edits;
/// - the tab comes back into view: unless it holds unsaved edits. Saves in
///   one rig tab change what the others show.
mixin RigReloads<T extends StatefulWidget> on ShowWatcher<T> {
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
  void onQueueRan() => load();

  @override
  void onSxClosed() {
    if (!dirty) load();
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    super.dispose();
  }
}
