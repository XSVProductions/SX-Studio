import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'result_card.dart';

export 'result_card.dart';
export 'sx_menu.dart';

/// Space left and right of a screen's content: 22 on a laptop, 10 on a phone.
double sxGutter(BuildContext context) => MediaQuery.sizeOf(context).width <= 640 ? 10 : 22;

/// The fill, border and corners of a card.
BoxDecoration _cardBox() => BoxDecoration(
  color: Sx.card,
  border: Border.all(color: Sx.line),
  borderRadius: BorderRadius.circular(14),
  boxShadow: Sx.isLight ? const [BoxShadow(color: Color(0x0F141821), blurRadius: 3, offset: Offset(0, 1))] : null,
);

const _cardPadding = EdgeInsets.fromLTRB(20, 18, 20, 18);

/// A bordered section of a screen, the old app's `.card`. Most screens are
/// one or two of these. A card with a long list in it is an [SxListCard].
class SxCard extends StatelessWidget {
  const SxCard({super.key, required this.child, this.padding = _cardPadding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(padding: padding, decoration: _cardBox(), child: child);
}

/// An [SxCard] for a long list. Only the [children] on screen (and a little
/// beyond) are built, laid out and painted, so a show with 300 buttons costs
/// what a screenful of them costs.
///
/// It works only as a direct child of [ScreenBody]. The children are laid
/// out as in a `Column`: at their own width on the left, or filling the card
/// when [stretch] is set. A child that scrolls away loses the State of its
/// widgets, so keep what the user edits in the screen's State.
class SxListCard extends StatelessWidget {
  const SxListCard({super.key, required this.children, this.padding = _cardPadding, this.stretch = false});

  final List<Widget> children;
  final EdgeInsets padding;

  /// The children fill the card's width (`CrossAxisAlignment.stretch`).
  /// Otherwise each keeps its own width (`CrossAxisAlignment.start`).
  final bool stretch;

  @override
  Widget build(BuildContext context) => DecoratedSliver(
    decoration: _cardBox(),
    sliver: SliverPadding(
      padding: padding,
      sliver: SliverList(
        delegate: SliverChildListDelegate(stretch ? children : [for (final c in children) Align(alignment: Alignment.centerLeft, child: c)]),
      ),
    ),
  );
}

/// A card's heading row: title, optional one-line explanation, and buttons on the right.
class SxHeader extends StatelessWidget {
  const SxHeader(this.title, {super.key, this.sub, this.actions = const []});

  final String title;
  final String? sub;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Sx.title),
            if (sub != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(sub!, style: Sx.sub),
              ),
          ],
        ),
      ),
      for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
    ],
  );
}

/// The scrolling body every screen uses: centered, capped at [Sx.contentWidth],
/// with room at the bottom for the [SaveBar]. The last save's [ResultCard]
/// comes after the screen's own cards, as the old `#result` did.
///
/// A child that is an [SxListCard] builds only its rows on screen. Every
/// other child is built whole.
class ScreenBody extends StatelessWidget {
  const ScreenBody({super.key, required this.children, this.bar});

  final List<Widget> children;

  /// Pinned to the bottom of the screen, usually a [SaveBar].
  final Widget? bar;

  @override
  Widget build(BuildContext context) {
    final gutter = sxGutter(context);
    final app = AppScope.maybeOf(context);
    final shown = app?.result;
    final tab = TabScope.of(context);
    final children = [...this.children, if (shown != null && (tab == null || tab == app!.resultTab)) ResultCard(shown, key: ValueKey(app!.resultSeq))];
    // the screen is as wide as the window: content sits in the middle, at most [Sx.contentWidth] wide
    final side = math.max(gutter, (MediaQuery.sizeOf(context).width - Sx.contentWidth) / 2);
    final gap = gutter < 22 ? 12.0 : 18.0;
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              for (final (i, c) in children.indexed)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(side, i == 0 ? (gutter < 22 ? 12 : 20) : gap, side, i == children.length - 1 ? 28 : 0),
                  // its own layer, so a change in one card redraws that card only
                  sliver: c is SxListCard ? c : SliverToBoxAdapter(child: RepaintBoundary(child: c)),
                ),
            ],
          ),
        ),
        ?bar,
      ],
    );
  }
}

/// The bar under a screen with its hint and buttons, the old app's `.bar`.
/// On a phone the hint gets its own line and the buttons share the row under
/// it, as the old phone rule did.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key, required this.hint, this.failed = false, this.actions = const []});

  final String hint;

  /// The hint reports a save that failed, so it is red.
  final bool failed;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width <= 640;
    final text = Text(
      hint,
      style: TextStyle(color: failed ? Sx.red : Sx.dim, fontSize: phone ? 12 : 13),
    );
    return Container(
      decoration: BoxDecoration(
        color: Sx.bg,
        border: Border(top: BorderSide(color: Sx.line)),
      ),
      padding: phone ? const EdgeInsets.all(10) : EdgeInsets.symmetric(horizontal: sxGutter(context), vertical: 14),
      child: phone
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hint.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(bottom: actions.isEmpty ? 0 : 8),
                    child: text,
                  ),
                if (actions.isNotEmpty)
                  Row(
                    children: [
                      for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: a)],
                    ],
                  ),
              ],
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Sx.contentWidth),
                child: Row(
                  children: [
                    Expanded(child: text),
                    for (final a in actions) Padding(padding: const EdgeInsets.only(left: 12), child: a),
                  ],
                ),
              ),
            ),
    );
  }
}

/// A red box with a problem in it, the old app's `.warnbox`. Renders nothing
/// when [message] is empty.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => message.isEmpty
      ? const SizedBox.shrink()
      : Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: Sx.tint(Sx.red),
          child: Text(message, style: TextStyle(color: Sx.redText, fontSize: 13)),
        );
}

/// A small caps label with an optional count, over a group of rows.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key, this.count, this.trailing});

  final String text;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(
      children: [
        Text(text.toUpperCase(), style: Sx.label),
        if (count != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text('$count', style: TextStyle(color: Sx.mute, fontSize: 12)),
          ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// A small pill button, the old app's `.mini`. [primary] makes it lime, [on]
/// marks something that is running (green).
class MiniButton extends StatelessWidget {
  const MiniButton(this.text, {super.key, required this.onPressed, this.icon, this.primary = false, this.on = false});

  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool on;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 12, fontWeight: FontWeight.w600),
      backgroundColor: primary
          ? Sx.primaryBottom
          : on
          ? Sx.green.withValues(alpha: .1)
          : Sx.hover,
      foregroundColor: primary
          ? Sx.onPrimary
          : on
          ? Sx.green
          : Sx.text,
      side: primary ? BorderSide.none : BorderSide(color: on ? Sx.green : Sx.line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(icon, size: 14)),
        Text(text),
      ],
    ),
  );
}

/// One button of the tab bar or of a [Seg]. The one that is [on] gets the
/// lighter fill and the lime line under it.
class SegButton extends StatefulWidget {
  const SegButton({
    super.key,
    required this.child,
    required this.on,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
  });

  final Widget child;
  final bool on;
  final VoidCallback onTap;
  final EdgeInsets padding;

  @override
  State<SegButton> createState() => _SegButtonState();
}

class _SegButtonState extends State<SegButton> {
  var _hover = false;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: widget.onTap,
      onHover: (h) => setState(() => _hover = h),
      hoverColor: Colors.transparent,
      child: Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: widget.on ? Sx.tabOn : null,
          border: Border(bottom: BorderSide(color: widget.on ? Sx.accent : Colors.transparent, width: 2)),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: .3, color: widget.on || _hover ? Sx.text : Sx.dim),
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Pick one of a few options, the old app's `.seg`. [options] maps each value
/// to its label, in order.
class Seg<T> extends StatelessWidget {
  const Seg({super.key, required this.value, required this.options, required this.onChanged});

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
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
        for (final o in options.entries)
          SegButton(
            on: o.key == value,
            onTap: () => onChanged(o.key),
            padding: EdgeInsets.symmetric(horizontal: sxGutter(context) < 22 ? 14 : 24, vertical: 8),
            child: Text(o.value),
          ),
      ],
    ),
  );
}

/// A dialog with a tool's text report, and the reason on top when it failed.
Future<void> showReport(BuildContext context, String title, String report, {String error = ''}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title, style: Sx.title),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error.isNotEmpty) Text(error, style: TextStyle(color: Sx.redText)),
          if (report.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: error.isEmpty ? 0 : 12),
              child: SelectableText(
                report,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sx.text2),
              ),
            ),
        ],
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

/// For a screen that shows show files: says when its copy went stale. The
/// old page's poll did this for every tab (`reloadAll`, and the reloads
/// after `was&&!sxOpen`).
mixin ShowWatcher<T extends StatefulWidget> on State<T> {
  int? _runs, _closes;

  /// The queue just saved into the show. Read everything again. Edits that
  /// were waiting in the queue are saved now.
  void onQueueRan();

  /// ShowXpress just closed. Read again, unless the screen holds unsaved
  /// edits.
  void onSxClosed() {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final (runs, closes) = (_runs, _closes);
    _runs = app.queueRuns;
    _closes = app.sxCloses;
    if (runs != null && runs != app.queueRuns) {
      onQueueRan();
    } else if (closes != null && closes != app.sxCloses) {
      onSxClosed();
    }
  }
}
