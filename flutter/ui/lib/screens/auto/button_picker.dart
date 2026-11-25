import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';

bool _isSetup(String page) => RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(page);

/// Picks the buttons of a look, page by page, with a search. Edits [look]'s
/// titles in place (at most 24). Port of the old page's `auPick`.
Future<void> pickButtons(BuildContext context, AutoLook look, List<AutoButton> buttons) => showDialog<void>(
  context: context,
  builder: (c) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660, maxHeight: 640),
      child: _Picker(look: look, buttons: buttons),
    ),
  ),
);

class _Picker extends StatefulWidget {
  const _Picker({required this.look, required this.buttons});

  final AutoLook look;
  final List<AutoButton> buttons;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  var _q = '';

  void _toggle(String t) {
    final ts = widget.look.titles;
    setState(() {
      if (!ts.remove(t) && ts.length < 24) ts.add(t);
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final pages = <String, List<AutoButton>>{};
    for (final b in widget.buttons) {
      if (_isSetup(b.page)) continue;
      if (q.isNotEmpty && !b.title.toLowerCase().contains(q) && !b.page.toLowerCase().contains(q)) continue;
      pages.putIfAbsent(b.page, () => []).add(b);
    }
    final on = widget.look.titles.toSet();
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Buttons in ${widget.look.name}', style: Sx.title),
          const SizedBox(height: 10),
          TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Search buttons'),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: pages.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('No button matches.', style: Sx.sub),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in pages.entries) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 6),
                          child: Text('${e.key}${e.value.first.swap ? ' · one at a time' : ''}'.toUpperCase(), style: Sx.label),
                        ),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final b in e.value)
                              _Chip(
                                b.title,
                                on: on.contains(b.title) && !b.dup,
                                no: b.dup
                                    ? 'Same name as another button. ShowXpress can only press the first one. Rename one in ShowXpress.'
                                    : !b.reach
                                    ? "This page can't be reached by the remote yet"
                                    : null,
                                onTap: () => _toggle(b.title),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {required this.on, required this.no, required this.onTap});

  final String text;
  final bool on;

  /// Why the button can't be used, or null.
  final String? no;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // the old `.pkb`
    final chip = InkWell(
      onTap: no == null ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Sx.accent.withValues(alpha: .12) : Sx.panel,
          border: Border.all(color: on ? Sx.accent : Sx.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: Sx.text)),
      ),
    );
    return no == null
        ? chip
        : Tooltip(
            message: no!,
            child: Opacity(opacity: .4, child: chip),
          );
  }
}
