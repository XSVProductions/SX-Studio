import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';

// Cheap stand-ins for Material's Tooltip and InkWell, for things repeated
// dozens of times on a screen: head tiles, step dots, list rows. Tonight's
// Rig, the Scene Editor and the Movement Editor use them.

/// A tap target that knows when the mouse is over it, for the old page's
/// `:hover` rules (a lighter border or fill). [builder] gets that flag. With
/// no [onTap] it is the plain box, no cursor and no hover.
///
/// A `GestureDetector` and a `MouseRegion`, where an `InkWell` in a
/// `Material` is about 30 widgets and an ink splash.
class HoverTap extends StatefulWidget {
  const HoverTap({super.key, required this.builder, this.onTap});

  final Widget Function(BuildContext context, bool hover) builder;
  final VoidCallback? onTap;

  @override
  State<HoverTap> createState() => _HoverTapState();
}

class _HoverTapState extends State<HoverTap> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final tap = widget.onTap;
    if (tap == null) return widget.builder(context, false);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: tap, child: widget.builder(context, _hover)),
    );
  }
}

/// A tooltip for the mouse: [message] in a small box under the child once the
/// pointer rests on it for a moment. A press hides it. Touch screens don't
/// show it.
///
/// Material's `Tooltip` is eight widgets and an overlay controller per use.
/// This is a `MouseRegion`, and the box exists only while it shows, one at a
/// time for the whole app.
class HoverTip extends StatefulWidget {
  const HoverTip({super.key, required String this.message, required this.child}) : messageAt = null;

  /// A tip that depends on where the pointer is, for one painted widget with
  /// many parts (a scene's row of steps). [messageAt] gets the pointer in the
  /// child's coordinates and returns null where there is nothing to say.
  /// The box shows under the pointer.
  const HoverTip.at({super.key, required String? Function(Offset local) this.messageAt, required this.child}) : message = null;

  final String? message;
  final String? Function(Offset local)? messageAt;
  final Widget child;

  @override
  State<HoverTip> createState() => _HoverTipState();
}

class _HoverTipState extends State<HoverTip> {
  static const _wait = Duration(milliseconds: 300);

  /// The tip on screen, from whichever [HoverTip] shows it.
  static _HoverTipState? _showing;

  Timer? _timer;
  OverlayEntry? _entry;
  var _text = '';

  /// What the box points at, in the overlay's coordinates: below this point.
  var _anchor = Rect.zero;

  void _hover(PointerHoverEvent e) {
    final at = widget.messageAt;
    final text = at == null ? widget.message! : at(e.localPosition);
    if (text == null || text.isEmpty) return _hide();
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final ob = overlay.context.findRenderObject()! as RenderBox;
    // under the pointer for a painted row, under the whole child otherwise
    final local = at == null ? Offset.zero & box.size : Rect.fromCenter(center: e.localPosition, width: 1, height: 16);
    final anchor = Rect.fromPoints(box.localToGlobal(local.topLeft, ancestor: ob), box.localToGlobal(local.bottomRight, ancestor: ob));
    final e0 = _entry;
    if (e0 != null) {
      if (text != _text) {
        _text = text;
        _anchor = anchor;
        e0.markNeedsBuild();
      }
      return;
    }
    _text = text;
    _anchor = anchor;
    _timer?.cancel();
    _timer = Timer(_wait, () => _show(overlay));
  }

  void _show(OverlayState overlay) {
    if (!mounted) return;
    _showing?._hide();
    _showing = this;
    final e = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: CustomSingleChildLayout(
            delegate: _TipPlace(_anchor),
            child: DecoratedBox(
              decoration: BoxDecoration(color: Sx.text.withValues(alpha: .92), borderRadius: BorderRadius.circular(4)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  _text,
                  style: TextStyle(fontFamily: Sx.body, fontSize: 12, color: Sx.bg, decoration: TextDecoration.none),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _entry = e;
    overlay.insert(e);
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    if (_showing == this) _showing = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final child = MouseRegion(
      onHover: _hover,
      onExit: (_) => _hide(),
      child: Listener(onPointerDown: (_) => _hide(), child: widget.child),
    );
    return m == null ? child : Semantics(tooltip: m, child: child);
  }
}

/// Puts the tip centered under [anchor], or over it when there is no room
/// below, and inside the window.
class _TipPlace extends SingleChildLayoutDelegate {
  _TipPlace(this.anchor);

  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => c.loosen().deflate(const EdgeInsets.all(8));

  @override
  Offset getPositionForChild(Size size, Size child) {
    const gap = 6.0, margin = 8.0;
    final below = anchor.bottom + gap;
    final y = below + child.height <= size.height - margin ? below : anchor.top - gap - child.height;
    final x = (anchor.center.dx - child.width / 2).clamp(margin, size.width - margin - child.width);
    return Offset(x, y.clamp(margin, size.height - margin - child.height));
  }

  @override
  bool shouldRelayout(_TipPlace old) => old.anchor != anchor;
}
