import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'scene_work.dart';

// Pieces of the Scene Editor screen: the channel rows, the heads list and a
// few small boxes from the old page's CSS. Only the Scene Editor uses them.

/// The old page's `.gh h3`: a small dim heading, with an optional count after it.
class SceneGroupHead extends StatelessWidget {
  const SceneGroupHead(this.text, {super.key, this.count = '', this.top = 14, this.bottom = 8});

  final String text;
  final String count;
  final double top, bottom;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: bottom),
    child: Row(
      children: [
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w600, color: Sx.dim),
          ),
        ),
        if (count.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(count, style: TextStyle(fontSize: 12, color: Sx.mute)),
          ),
      ],
    ),
  );
}

/// The old page's `.state` pill: "Not saved yet" in blue or "Matches the show" in green.
class SceneStateTag extends StatelessWidget {
  const SceneStateTag({super.key, required this.dirty});

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final c = dirty ? Sx.blue : Sx.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: dirty ? .45 : .35)),
        borderRadius: BorderRadius.circular(99),
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

/// The old page's `.tag`: a small outlined pill.
class SceneTag extends StatelessWidget {
  const SceneTag(this.text, {super.key, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: .45)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// The old page's `.warnbox` with paragraphs that may start in bold:
/// each entry is (bold lead, rest).
class SceneWarnBox extends StatelessWidget {
  const SceneWarnBox(this.paras, {super.key});

  final List<(String, String)> paras;

  @override
  Widget build(BuildContext context) {
    if (paras.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(color: Sx.redText, fontSize: 13, height: 1.4);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: Sx.tint(Sx.red),
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            for (final (i, (b, t)) in paras.indexed) ...[
              if (i > 0) const TextSpan(text: '\n\n'),
              if (b.isNotEmpty)
                TextSpan(
                  text: b,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              TextSpan(text: t),
            ],
          ],
        ),
      ),
    );
  }
}

/// The old page's `.sc` row: a name with a line under it, and something on the right.
class SceneRow extends StatelessWidget {
  const SceneRow({super.key, required this.name, required this.small, this.tag, this.right, this.onTap});

  final String name;
  final String small;
  final Widget? tag;
  final Widget? right;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Material(
      color: Sx.panel,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          name,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Sx.text),
                        ),
                        ?tag,
                      ],
                    ),
                    Text(small, style: TextStyle(fontSize: 11.5, color: Sx.dim)),
                  ],
                ),
              ),
              if (right != null) Padding(padding: const EdgeInsets.only(left: 12), child: right),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The old page's `ask`: a question with Cancel and a [yes] button. The
/// body is a list of (text, bold) pieces.
Future<bool> sceneAsk(BuildContext context, String title, List<(String, bool)> body, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: Sx.title),
        content: Text.rich(
          TextSpan(
            style: TextStyle(color: Sx.text2, fontSize: 14, height: 1.45),
            children: [
              for (final (t, b) in body)
                TextSpan(
                  text: t,
                  style: b ? TextStyle(fontWeight: FontWeight.w700, color: Sx.text) : null,
                ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
        ],
      ),
    ) ??
    false;

/// A dropdown in the old `select` look: well fill, line border, radius 8.
class SceneSelect<T> extends StatelessWidget {
  const SceneSelect({super.key, required this.items, required this.value, required this.hint, required this.onChanged});

  final Map<T, String> items;
  final T? value;
  final String hint;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: Sx.well,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        isExpanded: true,
        isDense: true,
        dropdownColor: Sx.panel,
        style: TextStyle(fontFamily: Sx.body, fontSize: 13, color: Sx.text),
        value: items.containsKey(value) ? value : null,
        hint: Text(hint, style: TextStyle(color: Sx.dim, fontSize: 13)),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged == null
            ? null
            : (v) {
                if (v != null) onChanged!(v);
              },
      ),
    ),
  );
}

/// A small number box, the old `.num` at 13 px.
class SceneNumber extends StatefulWidget {
  const SceneNumber({super.key, required this.text, required this.width, required this.onChanged, this.onDone, this.dim = false, this.decimal = false});

  /// What the box shows while the user is not typing in it.
  final String text;
  final double width;
  final ValueChanged<String> onChanged;

  /// Called when the user leaves the box or presses Enter.
  final VoidCallback? onDone;
  final bool dim;
  final bool decimal;

  @override
  State<SceneNumber> createState() => _SceneNumberState();
}

class _SceneNumberState extends State<SceneNumber> {
  late final _c = TextEditingController(text: widget.text);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) return;
      widget.onDone?.call();
      if (_c.text != widget.text) _c.text = widget.text;
    });
  }

  @override
  void didUpdateWidget(SceneNumber old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _c.text != widget.text) _c.text = widget.text;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: 32,
    child: TextField(
      controller: _c,
      focusNode: _focus,
      textAlign: TextAlign.right,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.decimal),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(widget.decimal ? r'[0-9.,]' : '[0-9]'))],
      style: TextStyle(fontSize: 13, color: widget.dim ? Sx.dim : Sx.text),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Sx.well,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Sx.line),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Sx.accent),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onDone?.call(),
    ),
  );
}

/// One channel of the picked heads in the step on screen, the old `.secr`:
/// name, slider, number, named range, fade, take out.
class SceneChannelRow extends StatelessWidget {
  const SceneChannelRow({
    super.key,
    required this.work,
    required this.step,
    required this.row,
    required this.model,
    required this.narrow,
    required this.onValue,
    required this.onFade,
    required this.onDelete,
  });

  final SceneWork work;
  final int step;
  final ChRow row;
  final String model;
  final bool narrow;
  final ValueChanged<int> onValue;
  final ValueChanged<bool> onFade;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final w = work.steps[step], o = work.maps[w.src];
    final k0 = row.keys.first, n = work.chName(model, row.ix, k0);
    final line = Border(bottom: BorderSide(color: Sx.line));
    Widget name(String extra, {Color? color}) => SizedBox(
      width: narrow ? 90 : 110,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            n,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color ?? Sx.text),
          ),
          Text('ch ${row.ix + 1}$extra', style: TextStyle(fontSize: 12.5, color: Sx.mute)),
        ],
      ),
    );
    if (row.keys.any((k) => work.fixedValue(step, k))) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(border: line),
        child: Row(
          children: [
            name(''),
            const SizedBox(width: 8),
            Expanded(child: Text("a value SX Studio doesn't change, edit it in ShowXpress", style: Sx.sub)),
          ],
        ),
      );
    }
    final vs = [for (final k in row.keys) w.ch[k]!.v], fs = [for (final k in row.keys) w.ch[k]!.fade];
    final v = vs.first, mix = vs.any((x) => x != v), fm = fs.any((x) => x != fs.first);
    final chg = row.keys.any((k) {
      final c = o[k], x = w.ch[k]!;
      return c == null || c.v != x.v || c.fade != x.fade;
    });
    final rs = work.scene.models?[model]?.ranges[n.toLowerCase()] ?? const <SceneRange>[];
    final picked = rs.indexWhere((x) => v >= x.lo && v <= x.hi);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: Sx.accent,
        thumbColor: Sx.accent,
        inactiveTrackColor: Sx.line,
      ),
      child: Slider(value: v.toDouble(), max: 255, onChanged: (x) => onValue(x.round())),
    );
    final number = SceneNumber(
      text: '$v',
      width: narrow ? 58 : 64,
      dim: mix,
      onChanged: (t) {
        if (t.isNotEmpty) onValue((int.tryParse(t) ?? 0).clamp(0, 255));
      },
    );
    final select = rs.isEmpty
        ? const SizedBox.shrink()
        : SceneSelect<int>(
            items: {for (final (i, x) in rs.indexed) i: '${x.n} (${x.lo}${x.hi != x.lo ? '-${x.hi}' : ''})'},
            value: picked < 0 ? null : picked,
            hint: 'named...',
            onChanged: (i) => onValue(jsRound((rs[i].lo + rs[i].hi) / 2)),
          );
    final fade = Tooltip(
      message: "Glide from the step before over this step's time",
      child: InkWell(
        onTap: () => onFade(!(fs.first && !fm)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(value: fs.first && !fm, onChanged: (b) => onFade(b ?? false), visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'fade',
                softWrap: false,
                overflow: TextOverflow.clip,
                style: TextStyle(fontSize: 12, color: Sx.dim),
              ),
            ),
          ],
        ),
      ),
    );
    final x = SizedBox(
      width: 20,
      child: IconButton(
        tooltip: 'Take this channel out of these heads, in every step',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        iconSize: 18,
        color: Sx.mute,
        hoverColor: Colors.transparent,
        icon: const Icon(Icons.close),
        onPressed: onDelete,
      ),
    );
    final nm = name(mix ? ' · mixed' : '', color: chg ? Sx.blue : null);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(border: line),
      child: narrow
          ? Column(
              children: [
                Row(
                  children: [
                    nm,
                    const SizedBox(width: 8),
                    Expanded(child: slider),
                    const SizedBox(width: 8),
                    number,
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: select),
                    const SizedBox(width: 8),
                    fade,
                    const SizedBox(width: 8),
                    x,
                  ],
                ),
              ],
            )
          : Row(
              children: [
                nm,
                const SizedBox(width: 8),
                Expanded(child: slider),
                const SizedBox(width: 8),
                number,
                const SizedBox(width: 8),
                SizedBox(width: 160, child: select),
                const SizedBox(width: 8),
                SizedBox(width: 64, child: fade),
                const SizedBox(width: 8),
                x,
              ],
            ),
    );
  }
}

/// The old page's `.seheads`: the scene's heads by model, the picked ones
/// marked, the ones not in the step on screen faded.
class SceneHeads extends StatelessWidget {
  const SceneHeads({
    super.key,
    required this.work,
    required this.step,
    required this.sel,
    required this.maxHeight,
    required this.onTap,
    required this.onAll,
    required this.onNone,
  });

  final SceneWork work;
  final int step;
  final Set<String> sel;
  final double maxHeight;
  final ValueChanged<SceneHead> onTap;
  final VoidCallback onAll, onNone;

  @override
  Widget build(BuildContext context) {
    final w = step < work.steps.length ? work.steps[step] : null;
    final groups = <String, List<SceneHead>>{};
    for (final h in work.heads) {
      groups.putIfAbsent(h.model, () => []).add(h);
    }
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Heads',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Sx.text),
                  ),
                ),
                MiniButton('All', onPressed: onAll),
                const SizedBox(width: 6),
                MiniButton('None', onPressed: onNone),
              ],
            ),
            for (final g in groups.entries) ...[
              SceneGroupHead(g.key, top: 10, bottom: 4),
              for (final h in g.value)
                Opacity(
                  opacity: w != null && !work.inStep(w, h.id) ? .45 : 1,
                  child: Material(
                    color: sel.contains(h.id) ? Sx.accent.withValues(alpha: .15) : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(7),
                      hoverColor: Sx.hover,
                      onTap: () => onTap(h),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(h.name, style: TextStyle(fontSize: 13, color: Sx.text)),
                            ),
                            const SizedBox(width: 6),
                            Text(h.addr != 0 ? 'DMX ${h.addr}' : 'not patched', style: TextStyle(fontSize: 13, color: Sx.dim)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
