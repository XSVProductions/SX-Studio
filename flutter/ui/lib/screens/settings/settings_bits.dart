import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "today at 6:20 AM" or "Mon, Nov 23 6:20 AM" for a laptop time
/// (`yyyy-MM-ddTHH:mm:ss`). Text that isn't a time comes back as it is.
String whenText(String s, {DateTime? now}) {
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  final n = now ?? DateTime.now();
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final t = '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  if (d.year == n.year && d.month == n.month && d.day == n.day) return 'today at $t';
  return '${_days[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day} $t';
}

/// Asks before something that can't be undone. True when the user said yes.
Future<bool> confirm(BuildContext context, String title, String text, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title),
        content: Text(text, style: const TextStyle(color: Sx.text2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// Copies [text] and says so for a moment.
class CopyButton extends StatefulWidget {
  const CopyButton(this.text, {super.key, this.label = 'Copy'});

  final String text;
  final String label;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  var _done = false;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (!mounted) return;
      setState(() => _done = true);
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (mounted) setState(() => _done = false);
    },
    child: Text(_done ? 'Copied' : widget.label, style: TextStyle(color: _done ? Sx.green : Sx.text2)),
  );
}

/// A tick box with its words, the whole row clickable.
class CheckRow extends StatelessWidget {
  const CheckRow(this.text, {super.key, required this.value, required this.onChanged});

  final String text;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: Row(
      children: [
        Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false)),
        Expanded(
          child: Text(text, style: const TextStyle(color: Sx.text2)),
        ),
      ],
    ),
  );
}
