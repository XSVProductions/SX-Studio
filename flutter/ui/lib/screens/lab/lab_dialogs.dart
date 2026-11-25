import 'package:flutter/material.dart';

import '../../theme.dart';
import 'lab_board.dart';

/// Asks before something that can't be taken back. True when the user said yes.
Future<bool> askUser(BuildContext context, String title, String text, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title),
        content: SizedBox(
          width: 460,
          child: Text(text, style: const TextStyle(color: Sx.text2, height: 1.4)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// Says an action didn't work, with the reason and the tool's report.
Future<void> showFailure(BuildContext context, String error, {String out = ''}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text("Didn't work", style: Sx.title),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, style: const TextStyle(color: Sx.redText)),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Nothing was changed.', style: Sx.sub),
          ),
          if (out.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                out,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sx.dim),
              ),
            ),
        ],
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

/// The name and "one at a time" of a player page (lbPageForm). Null when cancelled.
Future<(String, bool)?> askPageForm(BuildContext context, {required String title, required String yes, String name = '', bool swap = false}) =>
    showDialog<(String, bool)>(
      context: context,
      builder: (context) => _PageForm(title: title, yes: yes, name: name, swap: swap),
    );

class _PageForm extends StatefulWidget {
  const _PageForm({required this.title, required this.yes, required this.name, required this.swap});

  final String title;
  final String yes;
  final String name;
  final bool swap;

  @override
  State<_PageForm> createState() => _PageFormState();
}

class _PageFormState extends State<_PageForm> {
  late final _name = TextEditingController(text: widget.name);
  late var _swap = widget.swap;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, (_name.text, _swap));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title, style: Sx.title),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Name', style: TextStyle(color: Sx.text2)),
          const SizedBox(height: 6),
          TextField(controller: _name, autofocus: true, maxLength: 40, onSubmitted: (_) => _done()),
          CheckboxListTile(
            value: _swap,
            onChanged: (v) => setState(() => _swap = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('One at a time. A button here stops the others on this page (like MOVEMENTS)', style: TextStyle(fontSize: 14)),
          ),
          const Text("This page is only in the SX Player. ShowXpress and its live screen don't change.", style: Sx.sub),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _done, child: Text(widget.yes)),
    ],
  );
}

/// Picks show buttons and files to copy onto a player page. Empty when cancelled.
Future<List<AddItem>> askAddButtons(BuildContext context, String pageName, List<AddItem> items) async =>
    await showDialog<List<AddItem>>(
      context: context,
      builder: (context) => _AddButtons(pageName: pageName, items: items),
    ) ??
    const [];

class _AddButtons extends StatefulWidget {
  const _AddButtons({required this.pageName, required this.items});

  final String pageName;
  final List<AddItem> items;

  @override
  State<_AddButtons> createState() => _AddButtonsState();
}

class _AddButtonsState extends State<_AddButtons> {
  final _picked = <int>{};
  var _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final (i, x) in widget.items.indexed)
        if (q.isEmpty || '${x.title} ${x.sub}'.toLowerCase().contains(q)) i,
    ];
    return AlertDialog(
      title: Text('Add buttons to ${widget.pageName}', style: Sx.title),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tick the buttons to copy onto this page. A copy plays the same scene with the same speed and BPM settings. It has no APC pad or key of its own.',
              style: Sx.sub,
            ),
            const SizedBox(height: 10),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search'),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, k) {
                  final i = shown[k];
                  final x = widget.items[i];
                  return CheckboxListTile(
                    dense: true,
                    value: _picked.contains(i),
                    onChanged: (v) => setState(() => v == true ? _picked.add(i) : _picked.remove(i)),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(x.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(x.sub, style: const TextStyle(fontSize: 12, color: Sx.dim)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, [
            for (final (i, x) in widget.items.indexed)
              if (_picked.contains(i)) x,
          ]),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
