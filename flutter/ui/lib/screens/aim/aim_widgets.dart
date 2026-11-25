import 'package:flutter/material.dart';

import '../../theme.dart';

/// The old page's `ask()`: a yes / no dialog. True when [yes] was pressed.
Future<bool> askUser(BuildContext context, String title, Widget body, String yes) async =>
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
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// Text with **bold** parts, for the old copy's `<b>` tags. [text] uses `*`
/// around the bold words.
Text boldText(String text, {TextStyle? style, Color? bold}) {
  final parts = text.split('*');
  return Text.rich(
    TextSpan(
      children: [
        for (final (i, p) in parts.indexed)
          TextSpan(
            text: p,
            style: i.isOdd ? TextStyle(fontWeight: FontWeight.w600, color: bold ?? Sx.text) : null,
          ),
      ],
    ),
    style: style,
  );
}

/// A checkbox with its label, the old `label.link`.
class CheckRow extends StatelessWidget {
  const CheckRow(this.label, {super.key, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            activeColor: Sx.accent,
            checkColor: Sx.isLight ? Sx.card : Sx.onPrimary,
            side: BorderSide(color: Sx.line2),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: TextStyle(color: Sx.dim, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// A small pill, the old `.tag` (blue, amber or red).
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: .45)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}
