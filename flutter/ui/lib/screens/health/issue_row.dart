import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// One problem line, the old app's `.iss`: a round level mark, the title in
/// bold, a dim detail, an optional "Fix:" box, and buttons on the right.
///
/// [level] is `error`, `warn`, `info`, `ok` or `done`. Health Check,
/// Pre-show Check and the APC mini tab all use it.
class IssueRow extends StatelessWidget {
  const IssueRow({super.key, required this.level, required this.title, this.detail = '', this.advice = '', this.actions = const [], this.first = false});

  final String level;
  final String title;
  final String detail;
  final String advice;
  final List<Widget> actions;

  /// The first row of a list has no line above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      'error' => Sx.red,
      'warn' => Sx.amber,
      'ok' || 'done' => Sx.green,
      _ => Sx.blue,
    };
    final mark = switch (level) {
      'error' => const Text('!'),
      'warn' => const Text('?'),
      'ok' || 'done' => const Icon(Icons.check, size: 13),
      _ => const Text('i'),
    };
    final phone = sxGutter(context) < 22;
    final buttons = Wrap(spacing: 6, runSpacing: 6, children: actions);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: Sx.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: .15), shape: BoxShape.circle),
            child: IconTheme.merge(
              data: IconThemeData(color: color),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800, height: 1),
                child: mark,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Sx.text),
                ),
                if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(detail, style: TextStyle(fontSize: 12.5, color: Sx.dim)),
                  ),
                if (advice.isNotEmpty) _Advice(advice),
                if (phone && actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: buttons),
              ],
            ),
          ),
          if (!phone && actions.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 10), child: buttons),
        ],
      ),
    );
  }
}

/// The green-edged "Fix: ..." box under an issue.
class _Advice extends StatelessWidget {
  const _Advice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 5),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: Sx.green.withValues(alpha: .06),
      border: Border(left: BorderSide(color: Sx.green.withValues(alpha: .55), width: 2)),
      borderRadius: const BorderRadius.only(topRight: Radius.circular(6), bottomRight: Radius.circular(6)),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Fix: ',
            style: TextStyle(color: Sx.green, fontWeight: FontWeight.w600),
          ),
          TextSpan(text: text),
        ],
      ),
      style: TextStyle(fontSize: 12.5, color: Sx.text),
    ),
  );
}

/// Asks before doing something, the old app's `ask()`. True when the user
/// pressed [yes].
Future<bool> askConfirm(BuildContext context, String title, Widget body, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title.copyWith(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: Sx.text2, fontSize: 14),
            child: body,
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: Text(yes),
          ),
        ],
      ),
    ) ??
    false;

/// Paragraphs for [askConfirm]: the first in bold, the rest plain.
Widget confirmText(String bold, List<String> rest) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    if (bold.isNotEmpty) Text(bold, style: const TextStyle(fontWeight: FontWeight.w700)),
    for (final r in rest)
      Padding(
        padding: EdgeInsets.only(top: bold.isEmpty && r == rest.first ? 0 : 12),
        child: Text(r),
      ),
  ],
);
