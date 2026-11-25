import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

// Small pieces the Settings cards share. Sizes and colors follow the old
// page's CSS (`.setsec`, `.link`, `.phbox`, `.txt` in `df_aim_gui.ps1`).

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "today at 6:20 AM" or "Mon, Nov 23 6:20 AM" for a laptop time
/// (`yyyy-MM-ddTHH:mm:ss`). Text that isn't a time comes back as it is.
/// Port of the old page's `fmtT`.
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
        content: Text(text, style: TextStyle(color: Sx.text2, fontSize: 13.5, height: 1.45)),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// A card heading with an icon in front, the old `.setsec h2`.
class SetTitle extends StatelessWidget {
  const SetTitle(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Icon(icon, size: 17, color: Sx.text),
        ),
      Flexible(child: Text(text, style: Sx.title)),
    ],
  );
}

/// A card's title row with buttons on the right, wrapping under the title
/// on a narrow screen.
class SetHead extends StatelessWidget {
  const SetHead(this.text, {super.key, this.icon, this.sub, this.actions = const []});

  final String text;
  final IconData? icon;
  final String? sub;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SetTitle(text, icon: icon),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(sub!, style: Sx.sub),
          ),
      ],
    );
    if (actions.isEmpty) return title;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        ConstrainedBox(constraints: const BoxConstraints(minWidth: 200, maxWidth: 640), child: title),
        Wrap(spacing: 6, runSpacing: 6, children: actions),
      ],
    );
  }
}

/// Copies [text], and says so for a moment (the old `.phcopy`).
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
  Widget build(BuildContext context) => MiniButton(
    _done ? 'Copied' : widget.label,
    icon: _done ? Icons.check : Icons.content_copy,
    on: _done,
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (!mounted) return;
      setState(() => _done = true);
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      if (mounted) setState(() => _done = false);
    },
  );
}

/// A tick box with its words, the old `label.link`: dim 13 px, the whole row
/// clickable.
class LinkCheck extends StatelessWidget {
  const LinkCheck(this.text, {super.key, required this.value, required this.onChanged});

  final String text;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    hoverColor: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text, style: TextStyle(color: Sx.dim, fontSize: 13)),
          ),
        ],
      ),
    ),
  );
}

/// A panel inside a card with a small heading, the old `.phbox`.
class PanelBox extends StatelessWidget {
  const PanelBox({super.key, required this.title, required this.child, this.center = false});

  final String title;
  final Widget child;
  final bool center;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: Sx.panel,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w600, color: Sx.dim),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}

/// The old `.txt` field look: well fill, thin line, 13 px.
InputDecoration txtDecoration({String? hint}) => InputDecoration(
  hintText: hint,
  isDense: true,
  filled: true,
  fillColor: Sx.well,
  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: Sx.line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: Sx.line),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: Sx.accent),
  ),
);

/// A fold-out section, the old `details` with its dim `summary` line.
class Details extends StatefulWidget {
  const Details(this.summary, {super.key, required this.children});

  final String summary;
  final List<Widget> children;

  @override
  State<Details> createState() => _DetailsState();
}

class _DetailsState extends State<Details> {
  var _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        hoverColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Sx.dim),
              Flexible(
                child: Text(widget.summary, style: TextStyle(fontSize: 12.5, color: Sx.dim)),
              ),
            ],
          ),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.children),
        ),
    ],
  );
}
