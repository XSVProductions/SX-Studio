import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';

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
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (rig != null && look != null) ...[
                const SizedBox(height: 14),
                _templates(),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (context, c) {
                    final opts = _options(rig), right = _heads(rig, look);
                    if (c.maxWidth < 720) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [opts, right]);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: opts),
                        const SizedBox(width: 26),
                        Expanded(child: right),
                      ],
                    );
                  },
                ),
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
            child: SxHeader(
              'Made: $_made',
              sub:
                  "A new scene in the show. To play it, add a button for it on ShowXpress's live board (if ShowXpress is open, open the show "
                  'again so it lists the new scene).${_madeBeat ? ' Set the button to BPM with flash, so it flashes on every beat.' : ''}',
            ),
          ),
      ],
    );
  }

  Widget _templates() => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth >= 720 ? 4 : 2;
      final w = (c.maxWidth - 8 * (cols - 1)) / cols;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
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
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: t == _t ? const Color(0x14A3E635) : Sx.panel,
                    border: Border.all(color: t == _t ? Sx.accent : Sx.line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        style: TextStyle(fontWeight: FontWeight.w700, color: t == _t ? Sx.accent : Sx.text),
                      ),
                      Text(t.blurb, style: const TextStyle(fontSize: 12, color: Sx.dim)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (_t) {
        LookTemplate.contrast => [
          const GroupLabel('Colour pairs'),
          const Text('One colour on half the heads, the other on the rest.', style: Sx.sub),
          for (final (i, p) in o.pairs.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Flexible(child: _colorMenu(p.$1, (v) => _changed(() => o.pairs[i] = (v, o.pairs[i].$2)))),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('with', style: Sx.sub),
                  ),
                  Flexible(child: _colorMenu(p.$2, (v) => _changed(() => o.pairs[i] = (o.pairs[i].$1, v)))),
                  if (o.pairs.length > 1)
                    IconButton(
                      tooltip: 'Take this pair out',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _changed(() => o.pairs.removeAt(i)),
                      icon: const Icon(Icons.close, size: 16, color: Sx.dim),
                    ),
                ],
              ),
            ),
          if (o.pairs.length < 8)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _changed(() {
                  final u = [for (final c in lookColors) c.$1], k = o.pairs.length;
                  o.pairs.add((u[(k * 3 + 1) % u.length], u[(k * 3 + 7) % u.length]));
                }),
                child: const Text('+ Add a pair'),
              ),
            ),
          _field('Split the heads', _menu<ContrastSplit>(ContrastSplit.values, o.split, (s) => s.label, (v) => _changed(() => o.split = v), width: 220)),
          _check('Swap the two colours each step', o.swap, (v) => _changed(() => o.swap = v)),
          _field('Each step', _seconds('hold', o.hold, (v) => _changed(() => o.hold = v))),
          _check('Fade between steps (LED lights)', o.fade, (v) => _changed(() => o.fade = v)),
        ],
        LookTemplate.chase => [
          const GroupLabel('Colours'),
          const Text('In the order you tick them.', style: Sx.sub),
          const SizedBox(height: 6),
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
            children: [
              TextButton(onPressed: () => _changed(o.cols.clear), child: const Text('Clear')),
              TextButton(
                onPressed: () => _changed(
                  () => o.cols
                    ..clear()
                    ..addAll(LookOptions.rainbow),
                ),
                child: const Text('Rainbow'),
              ),
            ],
          ),
          _check('Back and forth (the colour wheel never jumps far)', o.pingPong, (v) => _changed(() => o.pingPong = v)),
          _check('Spread over the heads (a rainbow that moves)', o.spread, (v) => _changed(() => o.spread = v)),
          _field('Each colour', _seconds('chase', o.chaseHold, (v) => _changed(() => o.chaseHold = v))),
          _check('Fade between colours (LED lights)', o.chaseFade, (v) => _changed(() => o.chaseFade = v)),
        ],
        LookTemplate.strobe => [
          const GroupLabel('Colour'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (name, hex) in lookColors) _colorChip(name, hex, on: name == o.strobeColor, onTap: () => _changed(() => o.strobeColor = name)),
            ],
          ),
          _field(
            'Strobe',
            _menu<bool>(const [true, false], o.beat, (b) => b ? 'One flash each beat' : 'Steady on / off', (v) => _changed(() => o.beat = v), width: 200),
          ),
          if (o.beat)
            const Text(
              'One short flash, then dark. Set its button to BPM with flash ("run from step 1") in ShowXpress and it flashes on every beat.',
              style: Sx.sub,
            )
          else ...[
            _field('On for', _seconds('on', o.strobeOn, (v) => _changed(() => o.strobeOn = v))),
            _field('Off for', _seconds('off', o.strobeOff, (v) => _changed(() => o.strobeOff = v))),
          ],
        ],
        LookTemplate.prism => _prismOptions(rig),
      },
    );
  }

  List<Widget> _prismOptions(LookRig rig) {
    final o = _o, groups = lookGroups(rig);
    final g =
        groups.where((g) => lookGroupOn(o, g, LookTemplate.prism)).firstOrNull ?? groups.where((g) => (g.caps?.prisms ?? const []).isNotEmpty).firstOrNull;
    final names = [for (final p in g?.caps?.prisms ?? const <Prism>[]) p.name];
    return [
      const GroupLabel('Prisms'),
      const Text('No colour of its own. Play it with a colour look.', style: Sx.sub),
      if (names.isEmpty) const Text("None of the show's lights has a prism.", style: Sx.sub),
      for (final (j, name) in names.take(2).indexed) ...[
        () {
          while (o.prisms.length <= j) {
            o.prisms.add(PrismSetting(PrismMode.off, 50));
          }
          final q = o.prisms[j];
          return _field(
            name,
            _menu<PrismMode>(PrismMode.values, q.m, (m) => m.label, (v) => _changed(() => q.m = v), width: 140),
            below: q.m == PrismMode.l || q.m == PrismMode.r
                ? _slider('Speed', q.s, 0, 100, (v) => _changed(() => q.s = v.round()), key: Key('look-prism-speed-$j'))
                : null,
          );
        }(),
      ],
      _slider('Zoom', _o.zoom, 0, 255, (v) => _changed(() => o.zoom = v.round())),
      _slider('Focus', _o.focus, 0, 255, (v) => _changed(() => o.focus = v.round())),
      const Text('Spin speed: try it on the lights, each fixture counts it its own way. The gobos are set open and frost off.', style: Sx.sub),
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
        GroupLabel('Heads', count: heads),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final g in groups)
              () {
                final can = lookCan(g.caps, _t), picked = lookGroupOn(_o, g, _t);
                return Tooltip(
                  message: can ? '' : "This look doesn't use these lights",
                  child: _chip(
                    '${picked ? '✓ ' : ''}${g.label}  ×${g.heads.length}',
                    on: picked,
                    onTap: can ? () => _changed(() => _o.on[_t]![g.model] = !picked) : null,
                  ),
                );
              }(),
          ],
        ),
        if (rig.skipped.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Not used (a group of several heads, or no fixture definition): ${rig.skipped.join(', ')}', style: Sx.sub),
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
            style: const TextStyle(fontSize: 12, color: Sx.dim),
          ),
        ),
        if (on.isEmpty) const Text('No lights picked.', style: Sx.sub) else _steps(on, look),
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
                  child: Text('${i + 1}  ${s.len / 100} s', style: const TextStyle(fontSize: 11.5, color: Sx.dim)),
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
        if (look.steps.length > most) Text('and ${look.steps.length - most} more steps', style: Sx.sub),
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

  Widget _chip(String text, {required bool on, VoidCallback? onTap}) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: onTap == null ? Sx.mute : (on ? Sx.accent : Sx.text2))),
    ),
  );

  Widget _colorChip(String name, String hex, {required bool on, String? badge, required VoidCallback onTap}) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: _hexColor(hex), borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 6),
          Text(name, style: TextStyle(fontSize: 12.5, color: on ? Sx.text : Sx.text2)),
          if (badge != null)
            Text(
              '  $badge',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Sx.accent),
            ),
        ],
      ),
    ),
  );

  Widget _colorMenu(String value, ValueChanged<String> onPick) => _menu<String>(
    [for (final c in lookColors) c.$1],
    value,
    (n) => n,
    onPick,
    width: 130,
    lead: (n) => Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(right: 7),
      decoration: BoxDecoration(color: _hexColor(lookColorHex(n)), borderRadius: BorderRadius.circular(3)),
    ),
  );

  Widget _menu<T>(List<T> items, T value, String Function(T) label, ValueChanged<T> onPick, {required double width, Widget Function(T)? lead}) => SizedBox(
    width: width,
    height: 34,
    child: DropdownButtonHideUnderline(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Sx.well,
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButton<T>(
          isExpanded: true,
          isDense: true,
          dropdownColor: Sx.panel,
          style: const TextStyle(fontFamily: Sx.body, fontSize: 13.5, color: Sx.text),
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

  Widget _field(String label, Widget control, {Widget? below}) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13, color: Sx.text2)),
            ),
            control,
          ],
        ),
        ?below,
      ],
    ),
  );

  Widget _check(String label, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13, color: Sx.text2)),
          ),
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        ],
      ),
    ),
  );

  /// A seconds box. Empty is allowed while typing (it counts as 1 s).
  Widget _seconds(String id, num? value, ValueChanged<num?> onChanged) => SizedBox(
    width: 96,
    child: TextFormField(
      key: Key('look-seconds-$id'),
      initialValue: value == null ? '' : '$value',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(suffixText: 's'),
      onChanged: (v) => onChanged(num.tryParse(v.trim())),
    ),
  );

  Widget _slider(String label, num value, double min, double max, ValueChanged<double> onChanged, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      children: [
        SizedBox(
          width: 60,
          child: Text(label, style: const TextStyle(fontSize: 13, color: Sx.text2)),
        ),
        Expanded(
          child: Slider(key: key, min: min, max: max, value: value.toDouble().clamp(min, max), onChanged: onChanged),
        ),
        SizedBox(
          width: 32,
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12.5, color: Sx.dim),
          ),
        ),
      ],
    ),
  );
}
