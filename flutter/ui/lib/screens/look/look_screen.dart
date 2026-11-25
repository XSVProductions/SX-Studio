import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

/// A light's color from the look: data, not a theme color.
Color _hexColor(String hex) => Color(0xFF000000 | int.parse(hex, radix: 16));

/// One-click Looks: a new scene from a template for the heads picked.
///
/// The steps are worked out here with `buildLook`, the engine only checks
/// them and writes the new file. No scene the show has and no live button is
/// ever changed.
class LookScreen extends StatefulWidget {
  const LookScreen(BuildContext _, {super.key});

  @override
  State<LookScreen> createState() => _LookScreenState();
}

class _LookScreenState extends State<LookScreen> {
  LookRig? _rig;
  var _error = '';
  var _t = LookTemplate.contrast;

  /// Every template's settings. They stay while the app runs.
  final _o = LookOptions();
  final _name = TextEditingController();

  /// True once the user typed a name, so the automatic one stops following the settings.
  var _nameSet = false;

  /// The last look made, for the "Made" card.
  String? _made;
  var _madeBeat = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    setState(() {
      _rig = null;
      _error = '';
    });
    try {
      final r = await app.client.looks();
      if (!mounted) return;
      setState(() {
        _rig = r;
        _syncName();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// Rebuilds after a settings change. The name follows unless the user typed one.
  void _changed(VoidCallback f) => setState(() {
    f();
    _syncName();
  });

  void _syncName() {
    final rig = _rig;
    if (rig != null && !_nameSet) _name.text = lookAutoName(_t, _o, rig.scenes);
  }

  String get _clean => lookCleanName(_name.text);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final rig = _rig;
    final look = rig == null ? null : buildLook(rig, _t, _o);
    final n = _clean, taken = rig != null && lookNameTaken(n, rig.scenes);
    final canMake = rig != null && look != null && look.err.isEmpty && n.isNotEmpty && !taken;

    return ScreenBody(
      bar: SaveBar(
        hint: look == null
            ? ''
            : look.err.isNotEmpty
            ? look.err
            : n.isEmpty || taken
            ? ''
            : 'Makes a new scene. Nothing else in the show changes.',
        actions: [
          FilledButton(
            onPressed: canMake
                ? () => runSave(
                    context,
                    () => app.client.looksMake(look.draft('$n.scex')),
                    after: () async => setState(() {
                      rig.scenes.add('$n.scex');
                      _made = n;
                      _madeBeat = look.beat;
                      _nameSet = false;
                      _syncName();
                    }),
                  )
                : null,
            child: const Text('Make the scene'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SxHeader(
                'One-click Looks',
                sub:
                    "Make a new scene from a template. It's always a new scene file: no scene you have is changed, and ShowXpress's live board "
                    "isn't touched. Put the look on a button in ShowXpress.",
                actions: [OutlinedButton(onPressed: _load, child: const Text('Reload'))],
              ),
              ErrorBox(_error),
              if (rig == null && _error.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (rig != null && look != null) ...[
                const SizedBox(height: 14),
                _templates(),
                const SizedBox(height: 14),
                // the old `.lkgrid`: options 1.1, heads 1, one column up to 760 px
                () {
                  final opts = _options(rig), right = _heads(rig, look);
                  if (MediaQuery.sizeOf(context).width <= 760) {
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [opts, const SizedBox(height: 14), right]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: opts),
                      const SizedBox(width: 14),
                      Expanded(flex: 10, child: right),
                    ],
                  );
                }(),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Name of the new scene', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    SizedBox(
                      width: 340,
                      child: TextField(
                        key: const Key('look-name'),
                        controller: _name,
                        maxLength: 100,
                        style: const TextStyle(fontSize: 14),
                        decoration: const InputDecoration(counterText: ''),
                        onChanged: (v) => setState(() => _nameSet = v.trim().isNotEmpty),
                      ),
                    ),
                    Text(
                      n.isEmpty
                          ? 'Give it a name.'
                          : taken
                          ? "There's already a scene called that. Pick another name."
                          : 'a new file: scenes/$n.scex',
                      style: TextStyle(fontSize: 13, color: n.isEmpty || taken ? Sx.amber : Sx.dim),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_made != null)
          SxCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.check, size: 18, color: Sx.green),
                ),
                Expanded(
                  child: SxHeader(
                    'Made: $_made',
                    sub:
                        "A new scene in the show. To play it, add a button for it on ShowXpress's live board (if ShowXpress is open, open the show "
                        'again so it lists the new scene).${_madeBeat ? ' Set the button to BPM with flash, so it flashes on every beat.' : ''}',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _templates() => LayoutBuilder(
    builder: (context, c) {
      // the old `.lktpl`: four across, two up to 760 px
      final cols = MediaQuery.sizeOf(context).width > 760 ? 4 : 2;
      final w = (c.maxWidth - 10 * (cols - 1)) / cols;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final t in LookTemplate.values)
            SizedBox(
              width: w,
              child: InkWell(
                key: Key('look-template-${t.name}'),
                onTap: t == _t
                    ? null
                    : () => _changed(() {
                        _t = t;
                        _nameSet = false;
                      }),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                  decoration: BoxDecoration(
                    color: t == _t ? Sx.accent.withValues(alpha: .12) : Sx.panel,
                    border: Border.all(color: t == _t ? Sx.accent : Sx.line),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Sx.text),
                      ),
                      const SizedBox(height: 2),
                      Text(t.blurb, style: TextStyle(fontSize: 12, color: Sx.dim)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  // ---------------------------------------------------------------- options

  Widget _options(LookRig rig) {
    final o = _o;
    // the old `.lkopts` box
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 9,
        children: switch (_t) {
          LookTemplate.contrast => [
            _gh('Colour pairs', 'one colour on half the heads, the other on the rest'),
            for (final (i, p) in o.pairs.indexed)
              Row(
                spacing: 7,
                children: [
                  _sw(lookColorHex(p.$1)),
                  Flexible(child: _colorMenu(p.$1, (v) => _changed(() => o.pairs[i] = (v, o.pairs[i].$2)))),
                  Text('with', style: Sx.sub),
                  _sw(lookColorHex(p.$2)),
                  Flexible(child: _colorMenu(p.$2, (v) => _changed(() => o.pairs[i] = (o.pairs[i].$1, v)))),
                  if (o.pairs.length > 1)
                    Tooltip(
                      message: 'Take this pair out',
                      child: MiniButton('', icon: Icons.close, onPressed: () => _changed(() => o.pairs.removeAt(i))),
                    ),
                ],
              ),
            if (o.pairs.length < 8)
              Align(
                alignment: Alignment.centerLeft,
                child: MiniButton(
                  'Add a pair',
                  icon: Icons.add,
                  onPressed: () => _changed(() {
                    final u = [for (final c in lookColors) c.$1], k = o.pairs.length;
                    o.pairs.add((u[(k * 3 + 1) % u.length], u[(k * 3 + 7) % u.length]));
                  }),
                ),
              ),
            _field('Split the heads', _menu<ContrastSplit>(ContrastSplit.values, o.split, (s) => s.label, (v) => _changed(() => o.split = v), width: 210)),
            _check('Swap the two colours each step', o.swap, (v) => _changed(() => o.swap = v)),
            _field('Each step', _seconds('hold', o.hold, (v) => _changed(() => o.hold = v))),
            _check('Fade between steps (LED lights)', o.fade, (v) => _changed(() => o.fade = v)),
          ],
          LookTemplate.chase => [
            _gh('Colours', 'in the order you tick them'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (name, hex) in lookColors)
                  _colorChip(
                    name,
                    hex,
                    on: o.cols.contains(name),
                    badge: o.cols.contains(name) ? '${o.cols.indexOf(name) + 1}' : null,
                    onTap: () => _changed(() => o.cols.contains(name) ? o.cols.remove(name) : o.cols.add(name)),
                  ),
              ],
            ),
            Row(
              spacing: 6,
              children: [
                MiniButton('Clear', onPressed: () => _changed(o.cols.clear)),
                MiniButton(
                  'Rainbow',
                  onPressed: () => _changed(
                    () => o.cols
                      ..clear()
                      ..addAll(LookOptions.rainbow),
                  ),
                ),
              ],
            ),
            _check('Back and forth (the colour wheel never jumps far)', o.pingPong, (v) => _changed(() => o.pingPong = v)),
            _check('Spread over the heads (a rainbow that moves)', o.spread, (v) => _changed(() => o.spread = v)),
            _field('Each colour', _seconds('chase', o.chaseHold, (v) => _changed(() => o.chaseHold = v))),
            _check('Fade between colours (LED lights)', o.chaseFade, (v) => _changed(() => o.chaseFade = v)),
          ],
          LookTemplate.strobe => [
            _gh('Colour'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (name, hex) in lookColors) _colorChip(name, hex, on: name == o.strobeColor, onTap: () => _changed(() => o.strobeColor = name)),
              ],
            ),
            _field(
              'Strobe',
              _menu<bool>(const [true, false], o.beat, (b) => b ? 'One flash each beat' : 'Steady on / off', (v) => _changed(() => o.beat = v), width: 190),
            ),
            if (o.beat)
              Text(
                'One short flash, then dark. Set its button to BPM with flash ("run from step 1") in ShowXpress and it flashes on every beat.',
                style: Sx.sub.copyWith(fontSize: 12.5),
              )
            else ...[
              _field('On for', _seconds('on', o.strobeOn, (v) => _changed(() => o.strobeOn = v))),
              _field('Off for', _seconds('off', o.strobeOff, (v) => _changed(() => o.strobeOff = v))),
            ],
          ],
          LookTemplate.prism => _prismOptions(rig),
        },
      ),
    );
  }

  /// A heading inside the options box: the old `.gh` with its note.
  Widget _gh(String text, [String note = '']) => Row(
    children: [
      Text(text.toUpperCase(), style: Sx.label),
      if (note.isNotEmpty) ...[
        const SizedBox(width: 8),
        Flexible(
          child: Text(note, style: TextStyle(color: Sx.mute, fontSize: 12)),
        ),
      ],
    ],
  );

  /// The old `.lksw`: a round swatch of a look color.
  Widget _sw(String hex) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: _hexColor(hex),
      shape: BoxShape.circle,
      border: Border.all(color: Sx.line2),
    ),
  );

  List<Widget> _prismOptions(LookRig rig) {
    final o = _o, groups = lookGroups(rig);
    final g =
        groups.where((g) => lookGroupOn(o, g, LookTemplate.prism)).firstOrNull ?? groups.where((g) => (g.caps?.prisms ?? const []).isNotEmpty).firstOrNull;
    final names = [for (final p in g?.caps?.prisms ?? const <Prism>[]) p.name];
    return [
      _gh('Prisms', 'no colour of its own, play it with a colour look'),
      if (names.isEmpty) Text("None of the show's lights has a prism.", style: Sx.sub),
      for (final (j, name) in names.take(2).indexed) ...[
        () {
          while (o.prisms.length <= j) {
            o.prisms.add(PrismSetting(PrismMode.off, 50));
          }
          final q = o.prisms[j];
          return _field(
            name,
            _menu<PrismMode>(PrismMode.values, q.m, (m) => m.label, (v) => _changed(() => q.m = v), width: 118),
            below: q.m == PrismMode.l || q.m == PrismMode.r
                ? _slider('Speed', q.s, 0, 100, (v) => _changed(() => q.s = v.round()), key: Key('look-prism-speed-$j'))
                : null,
          );
        }(),
      ],
      _slider('Zoom', _o.zoom, 0, 255, (v) => _changed(() => o.zoom = v.round())),
      _slider('Focus', _o.focus, 0, 255, (v) => _changed(() => o.focus = v.round())),
      Text(
        'Spin speed: try it on the lights, each fixture counts it its own way. The gobos are set open and frost off.',
        style: Sx.sub.copyWith(fontSize: 12.5),
      ),
    ];
  }

  // ---------------------------------------------------------------- heads and the look itself

  Widget _heads(LookRig rig, BuiltLook look) {
    final groups = lookGroups(rig), on = groups.where((g) => lookGroupOn(_o, g, _t)).toList();
    final heads = on.fold(0, (a, g) => a + g.heads.length);
    final n = look.steps.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text('HEADS', style: Sx.label),
              const SizedBox(width: 8),
              Text('$heads head${heads == 1 ? '' : 's'}', style: TextStyle(color: Sx.mute, fontSize: 12)),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final g in groups)
              () {
                final can = lookCan(g.caps, _t), picked = lookGroupOn(_o, g, _t);
                return Tooltip(
                  message: can ? '' : "This look doesn't use these lights",
                  child: _chip(g.label, g.heads.length, on: picked, onTap: can ? () => _changed(() => _o.on[_t]![g.model] = !picked) : null),
                );
              }(),
          ],
        ),
        if (rig.skipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Not used (a group of several heads, or no fixture definition): ${rig.skipped.join(', ')}', style: Sx.sub.copyWith(fontSize: 12)),
          ),
        GroupLabel(
          'How it looks',
          trailing: Text(
            look.err.isNotEmpty
                ? ''
                : look.beat
                ? 'one flash, then dark till the next beat'
                : n == 1
                ? 'one look that holds'
                : '$n steps, ${(look.seconds * 100).round() / 100} s round',
            style: TextStyle(fontSize: 12, color: Sx.mute),
          ),
        ),
        // the old `.lkvis` box
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Sx.well,
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: on.isEmpty ? Text('No lights picked.', style: Sx.sub) : _steps(on, look),
        ),
      ],
    );
  }

  /// The look as a table: a row per step, a dot per head in its color. It
  /// stands still, unlike the old page's animation, so nothing repaints.
  Widget _steps(List<LookGroup> groups, BuiltLook look) {
    const most = 16;
    final shown = look.steps.take(most).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, s) in shown.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 58,
                  child: Text('${i + 1}  ${s.len / 100} s', style: TextStyle(fontSize: 11.5, color: Sx.dim)),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 3,
                    runSpacing: 3,
                    children: [
                      for (final (gi, g) in groups.indexed) ...[
                        if (gi > 0) const SizedBox(width: 8),
                        for (final h in g.heads) _dot(s.show[h.id], prism: look.prism),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (look.steps.length > most) Text('and ${look.steps.length - most} more steps', style: Sx.sub.copyWith(fontSize: 12)),
      ],
    );
  }

  Widget _dot(String? hex, {required bool prism}) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: hex == null ? Sx.well : _hexColor(hex),
      shape: prism ? BoxShape.rectangle : BoxShape.circle,
      border: Border.all(color: Sx.line2),
    ),
  );

  // ---------------------------------------------------------------- small pieces

  /// The old `.chip.lkgc`: a group of heads, ticked when it is in the look,
  /// faded when this template can't use it.
  Widget _chip(String label, int count, {required bool on, VoidCallback? onTap}) => Opacity(
    opacity: onTap == null ? .4 : 1,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Sx.accent.withValues(alpha: .13) : Sx.panel,
          border: Border.all(color: on ? Sx.accent : Sx.line),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (on)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.check, size: 14, color: Sx.text),
              ),
            Text(label, style: TextStyle(fontSize: 12.5, color: Sx.text)),
            Text('  x$count', style: TextStyle(fontSize: 11, color: Sx.dim)),
          ],
        ),
      ),
    ),
  );

  /// The old `.lkcc`: a look color to tick, with its place in the chase.
  Widget _colorChip(String name, String hex, {required bool on, String? badge, required VoidCallback onTap}) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(99),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: on ? Sx.accent.withValues(alpha: .12) : Sx.card,
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          _sw(hex),
          Text(name, style: TextStyle(fontSize: 12.5, color: Sx.text)),
          if (badge != null)
            Text(
              badge,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Sx.accent),
            ),
        ],
      ),
    ),
  );

  Widget _colorMenu(String value, ValueChanged<String> onPick) => _menu<String>([for (final c in lookColors) c.$1], value, (n) => n, onPick, width: 118);

  Widget _menu<T>(List<T> items, T value, String Function(T) label, ValueChanged<T> onPick, {required double width, Widget Function(T)? lead}) => SizedBox(
    width: width,
    height: 34,
    child: DropdownButtonHideUnderline(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: Sx.well,
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButton<T>(
          isExpanded: true,
          isDense: true,
          dropdownColor: Sx.panel,
          style: TextStyle(fontFamily: Sx.body, fontSize: 13, color: Sx.text),
          value: value,
          items: [
            for (final it in items)
              DropdownMenuItem(
                value: it,
                child: Row(
                  children: [
                    ?lead?.call(it),
                    Expanded(child: Text(label(it), overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null) onPick(v);
          },
        ),
      ),
    ),
  );

  /// The old `.mvf` row: the label on the left, the control on the right.
  Widget _field(String label, Widget control, {Widget? below}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: Sx.text)),
          ),
          control,
        ],
      ),
      ?below,
    ],
  );

  /// A `.mvf` row with a checkbox on the right.
  Widget _check(String label, bool value, ValueChanged<bool> onChanged) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 13, color: Sx.text)),
        ),
        SizedBox(
          width: 24,
          height: 24,
          child: Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        ),
      ],
    ),
  );

  /// A seconds box. Empty is allowed while typing (it counts as 1 s).
  Widget _seconds(String id, num? value, ValueChanged<num?> onChanged) => SizedBox(
    width: 96,
    child: TextFormField(
      key: Key('look-seconds-$id'),
      style: const TextStyle(fontSize: 13),
      initialValue: value == null ? '' : '$value',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(suffixText: 's'),
      onChanged: (v) => onChanged(num.tryParse(v.trim())),
    ),
  );

  /// A label, a slider and its value.
  Widget _slider(String label, num value, double min, double max, ValueChanged<double> onChanged, {Key? key}) => Row(
    children: [
      SizedBox(
        width: 60,
        child: Text(label, style: TextStyle(fontSize: 13, color: Sx.text)),
      ),
      Expanded(
        child: Slider(key: key, min: min, max: max, value: value.toDouble().clamp(min, max), onChanged: onChanged),
      ),
      SizedBox(
        width: 32,
        child: Text(
          '$value',
          textAlign: TextAlign.right,
          style: TextStyle(fontSize: 12.5, color: Sx.dim),
        ),
      ),
    ],
  );
}
