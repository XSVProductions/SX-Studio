import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A dropdown, the old page's `<select>`: the picked label in a box with an
/// arrow, and the list of [items] (value to label) when it is pressed.
///
/// Material's `DropdownButton` keeps every item built while it is closed,
/// about a hundred widgets for a list of four. Speed Faders shows one per
/// button of the show, which made that tab slow to open and to change. This
/// one is a dozen widgets, and the list exists only while it is open.
class SxMenu<T> extends StatelessWidget {
  const SxMenu({
    super.key,
    required this.items,
    required this.value,
    required this.onPick,
    this.hint = '',
    this.hintColor,
    this.lead,
    this.fontSize = 13,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    this.expand = true,
  });

  final Map<T, String> items;

  /// The picked value. One that isn't in [items], or null, shows [hint].
  final T? value;

  /// Null turns the dropdown off.
  final ValueChanged<T>? onPick;
  final String hint;

  /// [hint]'s color, dim when null.
  final Color? hintColor;

  /// Something in front of an item's label, a color swatch for example.
  final Widget Function(T value)? lead;
  final double fontSize;
  final EdgeInsets padding;

  /// Fills the width it is given. Otherwise it is as wide as the picked label.
  final bool expand;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<T>(
      context: context,
      // over the box, with the picked item where the box is
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx - box.size.width, overlay.size.height - at.dy - box.size.height),
      constraints: BoxConstraints(minWidth: box.size.width, maxWidth: math.max(box.size.width, 320)),
      color: Sx.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Sx.line),
      ),
      // opens at once: the old page's list did, and a fade repaints the window for a third of a second
      popUpAnimationStyle: AnimationStyle.noAnimation,
      initialValue: items.containsKey(value) ? value : null,
      items: [
        for (final e in items.entries)
          PopupMenuItem<T>(
            value: e.key,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: TextStyle(fontFamily: Sx.body, fontSize: fontSize, color: Sx.text),
            child: Row(
              children: [
                ?lead?.call(e.key),
                Expanded(child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onPick?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final on = onPick != null;
    final picked = value;
    final label = picked == null ? null : items[picked];
    final text = Text(
      label ?? hint,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontFamily: Sx.body, fontSize: fontSize, color: label == null ? hintColor ?? Sx.dim : (on ? Sx.text : Sx.mute)),
    );
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: on ? () => _open(context) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Sx.well,
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: padding,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (lead != null && picked != null && label != null) lead!(picked),
                expand ? Expanded(child: text) : Flexible(child: text),
                Icon(Icons.arrow_drop_down, size: 24, color: on ? Sx.text2 : Sx.mute),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
