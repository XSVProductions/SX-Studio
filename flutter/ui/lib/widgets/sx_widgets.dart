import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../app_state.dart';
import '../theme.dart';

/// Space left and right of a screen's content: 22 on a laptop, 10 on a phone.
double sxGutter(BuildContext context) => MediaQuery.sizeOf(context).width <= 640 ? 10 : 22;

/// A bordered section of a screen, the old app's `.card`. Most screens are
/// one or two of these.
class SxCard extends StatelessWidget {
  const SxCard({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Sx.card,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(14),
      boxShadow: Sx.isLight ? const [BoxShadow(color: Color(0x0F141821), blurRadius: 3, offset: Offset(0, 1))] : null,
    ),
    child: child,
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
/// with room at the bottom for the [SaveBar].
class ScreenBody extends StatelessWidget {
  const ScreenBody({super.key, required this.children, this.bar});

  final List<Widget> children;

  /// Pinned to the bottom of the screen, usually a [SaveBar].
  final Widget? bar;

  @override
  Widget build(BuildContext context) {
    final gutter = sxGutter(context);
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(gutter, gutter < 22 ? 12 : 20, gutter, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Sx.contentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, c) in children.indexed)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : (gutter < 22 ? 12 : 18)),
                        child: c,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ?bar,
      ],
    );
  }
}

/// The strip at the bottom of a screen, the old app's `.bar`: a hint on the
/// left, buttons on the right.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key, required this.hint, this.actions = const []});

  final String hint;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Sx.bg,
      border: Border(top: BorderSide(color: Sx.line)),
    ),
    padding: EdgeInsets.symmetric(horizontal: sxGutter(context), vertical: 14),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Sx.contentWidth),
        child: Row(
          children: [
            Expanded(
              child: Text(hint, style: TextStyle(color: Sx.dim, fontSize: 13)),
            ),
            for (final a in actions) Padding(padding: const EdgeInsets.only(left: 12), child: a),
          ],
        ),
      ),
    ),
  );
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

/// Runs a save and tells the user how it went.
///
/// While ShowXpress is open the engine queues the save instead of running it,
/// and the message says so. On a real save [after] runs (reload the screen).
/// A failure opens a dialog with the reason and the tool's full report.
/// [quiet] skips the message on success, for actions that are not saves.
Future<void> runSave(BuildContext context, Future<ToolResult> Function() save, {Future<void> Function()? after, bool quiet = false}) async {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  ToolResult r;
  try {
    r = await save();
  } on ApiException catch (e) {
    r = ToolResult.failed(e.message);
  }
  final queued = r.extra['queued'] == true;
  if (r.ok && !queued) await after?.call();
  await app.refresh();
  if (!context.mounted) return;
  if (!r.ok) {
    await showReport(context, 'Not saved', r.out, error: r.error);
    return;
  }
  if (quiet) return;
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: Sx.panel,
      content: Text(queued ? 'Queued. It saves when ShowXpress closes.' : 'Saved.', style: TextStyle(color: Sx.text)),
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
