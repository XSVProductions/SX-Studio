import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// Small pieces the Movement Editor uses. None of them are in `sx_widgets.dart`
/// yet; the confirm dialog and the tag would fit there if another screen needs them.

/// Asks before something that can't be taken back: the old app's `ask`
/// (title, text, Cancel and a lime button). True when the user said yes.
Future<bool> moveAsk(BuildContext context, String title, List<InlineSpan> text, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title.copyWith(fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text.rich(
            TextSpan(children: text),
            style: TextStyle(color: Sx.text2, fontSize: 14, height: 1.45),
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), textStyle: const TextStyle(fontSize: 14)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(yes),
          ),
        ],
      ),
    ) ??
    false;

/// Bold text inside a [moveAsk] message.
TextSpan moveBold(String t) => TextSpan(
  text: t,
  style: TextStyle(fontWeight: FontWeight.w700, color: Sx.text),
);

/// A small rounded label after a name, the old `.tag` (`.tag.amber`, `.tag.blue`, `.tag.red`).
class MoveTag extends StatelessWidget {
  const MoveTag(this.text, {super.key, this.color});

  final String text;

  /// Text and border color; null is the plain dim tag.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c == null ? Sx.line : c.withValues(alpha: .45)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c ?? Sx.dim),
      ),
    );
  }
}

/// "Not saved yet" or "Matches the show", the old `.state` pill (`stateTag`).
class MoveStateTag extends StatelessWidget {
  const MoveStateTag({super.key, required this.dirty});

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final c = dirty ? Sx.blue : Sx.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.withValues(alpha: dirty ? .45 : .35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(dirty ? Icons.circle : Icons.check, size: dirty ? 8 : 14, color: c),
          const SizedBox(width: 5),
          Text(
            dirty ? 'Not saved yet' : 'Matches the show',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

/// A number box that takes its value when the user leaves it or presses
/// Enter, like the old page's `onchange`. While it has the focus, a redraw
/// doesn't overwrite what is being typed.
class MoveNum extends StatefulWidget {
  const MoveNum({super.key, required this.value, required this.onCommit, this.width = 96, this.enabled = true, this.changed = false});

  /// The value to show, as text.
  final String value;

  /// The text typed, with a comma read as the decimal point.
  final ValueChanged<String> onCommit;
  final double width;
  final bool enabled;

  /// Differs from the file: blue, like the old `.num.chg`.
  final bool changed;

  @override
  State<MoveNum> createState() => _MoveNumState();
}

class _MoveNumState extends State<MoveNum> {
  late final _c = TextEditingController(text: widget.value);
  final _f = FocusNode();

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(MoveNum old) {
    super.didUpdateWidget(old);
    if (!_f.hasFocus && _c.text != widget.value) _c.text = widget.value;
  }

  void _commit() {
    if (_c.text != widget.value) widget.onCommit(_c.text.replaceAll(',', '.').trim());
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edge = widget.changed ? Sx.blue : Sx.line;
    OutlineInputBorder b(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c),
    );
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _c,
        focusNode: _f,
        enabled: widget.enabled,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        style: TextStyle(fontSize: 13, color: widget.changed ? Sx.blue : Sx.text),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
          enabledBorder: b(edge),
          border: b(edge),
          disabledBorder: b(Sx.line),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// A dropdown in the old `select` style (well background, thin border, radius 8), 32 high.
class MoveDrop<T> extends StatelessWidget {
  const MoveDrop({super.key, required this.value, required this.items, required this.onChanged, this.width = 130});

  final T value;
  final Map<T, String> items;

  /// Null disables it.
  final ValueChanged<T>? onChanged;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 32,
    child: SxMenu<T>(items: items, value: value, onPick: onChanged),
  );
}

/// The DMX values a scene's first step puts on the heads, to light a movement
/// while it plays on the rig: 1-based channel to value. [scene] is the answer
/// of `/api/scene`. Port of the old page's `mvLiteLoad`.
Map<int, int> moveLiteFrame(Json scene) {
  final addr = {for (final h in scene.list('heads', (h) => h)) h.str('id'): h.integer('addr')};
  final steps = scene.list('steps', (s) => s);
  final out = <int, int>{};
  if (steps.isEmpty) return out;
  for (final x in steps.first.list('fx', (x) => x)) {
    final a = addr[x.str('id')] ?? 0;
    if (a == 0) continue;
    final ch = switch (x['ch']) {
      final List<Object?> l => l,
      _ => const <Object?>[],
    };
    for (final c in ch) {
      if (c is! List<Object?> || c.length < 3) continue;
      final off = c[0], v = c[2];
      final n = a + (off is num ? off.toInt() : int.tryParse('$off') ?? 0);
      final val = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
      if (n >= 1 && n <= 8192) out[n] = val.isFinite ? val.clamp(0, 255).toInt() : 0;
    }
  }
  return out;
}
