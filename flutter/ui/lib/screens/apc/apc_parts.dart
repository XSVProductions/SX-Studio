import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import 'apc_palette.dart';

// Pieces the APC mini and APC40 tabs share: the colour swatches, the small
// tags and label rows of the side panel, the pad menu, and pad dragging.

/// The swatches for one of a pad's two colours, the old `.pals` row of `.psw`.
class PadPalette extends StatelessWidget {
  const PadPalette({super.key, required this.current, required this.onPick});

  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 3, bottom: 7),
    child: Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final v in padSwatches)
          Tooltip(
            message: v == 0 ? 'off' : 'colour $v',
            child: GestureDetector(
              onTap: () => onPick(v),
              child: Container(
                width: 17,
                height: 17,
                foregroundDecoration: v == current
                    ? BoxDecoration(
                        border: Border.all(color: Sx.accent, width: 2),
                        borderRadius: BorderRadius.circular(4),
                      )
                    : null,
                decoration: BoxDecoration(
                  color: padColor(v),
                  border: Border.all(color: Sx.line2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A 12 px colour square, the old `.sw`.
class PadSwatch extends StatelessWidget {
  const PadSwatch(this.color, {super.key});

  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: color ?? apcBody,
      border: Border.all(color: Sx.line2),
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// A small outlined pill, the old app's `.tag`. [color] null is the plain one.
class ApcTag extends StatelessWidget {
  const ApcTag(this.text, this.color, {super.key});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color?.withValues(alpha: .45) ?? Sx.line),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color ?? Sx.dim),
    ),
  );
}

/// Label and value pairs, the old app's `.kv`.
class ApcKv extends StatelessWidget {
  const ApcKv(this.rows, {super.key});

  final List<(String, Widget)> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(k, style: TextStyle(fontSize: 12.5, color: Sx.dim)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 12.5), child: v),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// The dashed outline of a free or empty pad, or in the accent colour
/// ([accent]) round a pad or page a dragged pad would drop on (`.a4drop`).
class PadDashed extends CustomPainter {
  const PadDashed({this.accent = false});

  final bool accent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accent ? Sx.accent : Sx.line
      ..strokeWidth = accent ? 2 : 1
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(PadDashed old) => old.accent != accent;
}

/// One line of a [showPadMenu].
typedef PadMenuItem = ({String text, bool enabled, VoidCallback go});

/// A pad's right-click menu at [at], the old page's `ctxOpen`: a small
/// heading, then [items]. Runs the chosen item's `go`.
Future<void> showPadMenu(BuildContext context, Offset at, String title, List<PadMenuItem> items) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final picked = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    color: Sx.panel,
    surfaceTintColor: Colors.transparent,
    // `box-shadow: 0 10px 28px rgba(0,0,0,.45)`: dark in both themes.
    shadowColor: Sx.isLight ? Sx.text : Sx.bg,
    elevation: 10,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: Sx.line2),
    ),
    constraints: const BoxConstraints(minWidth: 190, maxWidth: 284),
    menuPadding: const EdgeInsets.all(4),
    items: [
      PopupMenuItem(
        enabled: false,
        height: 0,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: Sx.mute, fontWeight: FontWeight.w600, letterSpacing: .5),
        ),
      ),
      for (final (i, it) in items.indexed)
        PopupMenuItem(
          value: i,
          enabled: it.enabled,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(it.text, style: TextStyle(fontSize: 13, color: it.enabled ? Sx.text : Sx.mute)),
        ),
    ],
  );
  if (picked != null) items[picked].go();
}

/// A pad that can be dragged, as the old `draggable="true"` pads: a mouse
/// drags it straight away, a finger after a long press, so a finger can
/// still scroll the page over the grid.
class PadDraggable<T extends Object> extends StatelessWidget {
  const PadDraggable({super.key, required this.data, required this.size, required this.child, this.onDragStarted});

  final T? data;

  /// The pad's size, for the copy that follows the pointer.
  final Size size;
  final Widget child;
  final VoidCallback? onDragStarted;

  @override
  Widget build(BuildContext context) {
    if (data == null) return child;
    // The browser's drag image: the pad, see-through, under the pointer.
    final feedback = Opacity(
      opacity: .75,
      child: SizedBox.fromSize(size: size, child: child),
    );
    return _MouseDraggable<T>(
      data: data,
      feedback: feedback,
      onDragStarted: onDragStarted,
      child: _TouchDraggable<T>(
        data: data,
        feedback: feedback,
        onDragStarted: onDragStarted,
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
      ),
    );
  }
}

class _MouseDraggable<T extends Object> extends Draggable<T> {
  const _MouseDraggable({super.data, required super.feedback, super.onDragStarted, required super.child});

  @override
  MultiDragGestureRecognizer createRecognizer(GestureMultiDragStartCallback onStart) =>
      ImmediateMultiDragGestureRecognizer(supportedDevices: const {PointerDeviceKind.mouse, PointerDeviceKind.trackpad})..onStart = onStart;
}

class _TouchDraggable<T extends Object> extends Draggable<T> {
  const _TouchDraggable({super.data, required super.feedback, super.onDragStarted, required super.child});

  @override
  MultiDragGestureRecognizer createRecognizer(GestureMultiDragStartCallback onStart) => DelayedMultiDragGestureRecognizer(
    supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus, PointerDeviceKind.unknown},
  )..onStart = onStart;
}

/// Calls [onEsc] when Esc is pressed anywhere, as the old page's document
/// `keydown` handler. The screen decides whether it is on show.
class EscCatcher extends StatefulWidget {
  const EscCatcher({super.key, required this.onEsc, required this.child});

  final VoidCallback onEsc;
  final Widget child;

  @override
  State<EscCatcher> createState() => _EscCatcherState();
}

class _EscCatcherState extends State<EscCatcher> {
  bool _key(KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape && (ModalRoute.of(context)?.isCurrent ?? true)) widget.onEsc();
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
