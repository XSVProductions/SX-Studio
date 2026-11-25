import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../app_state.dart';
import '../theme.dart';

/// A bordered section of a screen. Most screens are one or two of these.
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
      borderRadius: BorderRadius.circular(12),
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
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Sx.contentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, c) in children.indexed)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 18),
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

/// The strip at the bottom of a screen: a hint on the left, buttons on the right.
class SaveBar extends StatelessWidget {
  const SaveBar({super.key, required this.hint, this.actions = const []});

  final String hint;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Sx.bg,
      border: Border(top: BorderSide(color: Sx.line)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Sx.contentWidth),
        child: Row(
          children: [
            Expanded(
              child: Text(hint, style: const TextStyle(color: Sx.text2, fontSize: 13.5)),
            ),
            for (final a in actions) Padding(padding: const EdgeInsets.only(left: 10), child: a),
          ],
        ),
      ),
    ),
  );
}

/// A red box with a problem in it. Renders nothing when [message] is empty.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => message.isEmpty
      ? const SizedBox.shrink()
      : Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x1AFF5C5C),
            border: Border.all(color: const Color(0x66FF5C5C)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(message, style: const TextStyle(color: Sx.redText)),
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
            child: Text('$count', style: const TextStyle(color: Sx.mute, fontSize: 12)),
          ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// Runs a save and tells the user how it went.
///
/// While ShowXpress is open the engine queues the save instead of running it,
/// and the message says so. On a real save [after] runs (reload the screen).
/// A failure opens a dialog with the reason and the tool's full report.
Future<void> runSave(BuildContext context, Future<ToolResult> Function() save, {Future<void> Function()? after}) async {
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
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not saved', style: Sx.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(r.error, style: const TextStyle(color: Sx.redText)),
              if (r.out.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    r.out,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sx.dim),
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: Sx.panel,
      content: Text(queued ? 'Queued. It saves when ShowXpress closes.' : 'Saved.', style: const TextStyle(color: Sx.text)),
    ),
  );
}
