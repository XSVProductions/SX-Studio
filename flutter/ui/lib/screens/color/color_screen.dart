import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../sx_control.dart';
import '../../widgets/sx_widgets.dart';
import 'color_wheel.dart';
import 'on_the_lights.dart';

/// Quick picks: decor colors couples ask for.
const colorPresets = [
  ('Red', 'ff0000'), ('Wine', '8b0a2a'), ('Rose', 'ff2a6d'), ('Blush', 'f4a6b8'), ('Hot pink', 'ff3fa4'), ('Magenta', 'ff00ff'), //
  ('Purple', '8a2be2'), ('Lavender', 'b48cff'), ('Royal blue', '1f3fff'), ('Navy', '0a1a6e'), ('Sky blue', '6ec8ff'),
  ('Teal', '00a8a8'), ('Mint', '7dffc4'), ('Emerald', '00b050'), ('Lime', '9aff00'), ('Gold', 'ffb000'), ('Yellow', 'ffee00'),
  ('Peach', 'ffb38a'), ('Orange', 'ff6a00'), ('Warm white', 'ffd9a8'), ('Cold white', 'e6f2ff'),
];

/// A color from the show or the one picked: data, not a theme color.
Color hexColor(String hex) => Color(0xFF000000 | int.parse(hex, radix: 16));

/// The uplight channels for [hex] as `(index, value)`: what TONIGHTS COLOR
/// UPLIGHT will hold, worked out the page's way (JavaScript rounding) for the
/// preview on the lights. Port of `clWash` and `clUpVals`.
List<(int, int)> uplightValues(String hex, List<String> chs) {
  final c = [for (var i = 0; i < 6; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  final mx = c.reduce(math.max), mn = c.reduce(math.min);
  final v = {'dimmer': mx, 'red': 0, 'green': 0, 'blue': 0, 'white': 0};
  if (mx > 0) {
    if (!chs.contains('white')) {
      v['red'] = jsRound(c[0] * 255 / mx);
      v['green'] = jsRound(c[1] * 255 / mx);
      v['blue'] = jsRound(c[2] * 255 / mx);
    } else if (mx == mn) {
      v['white'] = 255;
    } else {
      final k = 1 / (mx - mn), w = mn / mx;
      v['red'] = jsRound(255 * (c[0] - mn) * k);
      v['green'] = jsRound(255 * (c[1] - mn) * k);
      v['blue'] = jsRound(255 * math.pow((c[2] - mn) * k, 1 - 0.85 * w));
      v['white'] = jsRound(255 * (1 - math.pow(1 - w, 1.8)));
    }
  }
  final zero = RegExp(r'^(dimmer|red|green|blue|white|amber|uv|strobe.*|.*macro.*|.*effect.*)$');
  return [
    for (final (i, n) in chs.indexed)
      if (v[n] case final x?) (i, x) else if (zero.hasMatch(n)) (i, 0),
  ];
}

/// What Tonight's Color sends to the lights: movers on the dance-floor center
/// with their aim look and the nearest wheel color, uplights in the color.
/// Nothing picked leaves the movers dark and the uplights at 0. Port of `cpPush`.
LiveFrame colorFrame(ColorPreview d, List<LiveHead> heads, String hex) {
  final on = hex.isNotEmpty;
  final n140 = on ? nearestWheel(d.wheel140, hex) : null, n251 = on ? nearestWheel(d.wheel251, hex) : null;
  final f = <String, String>{};
  for (final h in heads) {
    f['p${h.addr}'] = 's:${h.addr}:${h.addr + 1}:${h.c.$1}';
    f['p${h.addr + 2}'] = 's:${h.addr + 2}:${h.addr + 3}:${h.c.$2}';
    final n = h.is140 ? n140 : n251;
    for (final (i, v) in h.look) {
      final x = i == 5
          ? n?.value ?? 0
          : !on && (i == h.dimI || i == h.shutI)
          ? 0
          : v;
      f['b${h.addr + i}'] = 'b:${h.addr + i}:$x';
    }
  }
  for (final w in d.washFix) {
    final vs = on ? uplightValues(hex, w.chs) : [for (var i = 0; i < w.chs.length; i++) (i, 0)];
    for (final (i, v) in vs) {
      f['b${w.addr + i}'] = 'b:${w.addr + i}:${v.clamp(0, 255)}';
    }
  }
  return f;
}

/// "today at 7:11 AM", or "Mon, Nov 23 7:11 AM", from the saved `yyyy-MM-ddTHH:mm:ss`.
String savedWhen(String saved, DateTime now) {
  final d = DateTime.tryParse(saved);
  if (d == null) return saved;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final t = '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return 'today at $t';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day} $t';
}

/// Tonight's Color: the evening's decor color on the movers and uplights.
class ColorScreen extends StatefulWidget {
  const ColorScreen(BuildContext _, {super.key});

  @override
  State<ColorScreen> createState() => _ColorScreenState();
}

class _ColorScreenState extends State<ColorScreen> with ShowWatcher {
  ColorPreview? _data;
  var _error = '';

  /// The picked color, `rrggbb`, or '' before one is picked.
  var _hex = '';

  /// Brightness, 10 to 100.
  var _bright = 100;
  final _name = TextEditingController();
  final _hexField = TextEditingController();
  final _hexFocus = FocusNode();

  /// The color on the real lights while it is picked.
  late final OnTheLights _lights = OnTheLights(AppScope.read(context), raw: false, frame: () => colorFrame(_data!, _lights.info?.heads ?? const [], _hex));

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus) _typedHex();
    });
    _lights.addListener(_relight);
    _load();
  }

  void _relight() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _hexField.dispose();
    _hexFocus.dispose();
    _lights.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.color();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
        _name.text = d.name;
        _pick(d.hex, keepName: true);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e.message;
      });
    }
    _markDirty();
  }

  /// The queue saved a color into the show: read it again (the old `reloadAll`).
  @override
  void onQueueRan() => _load();

  /// ShowXpress closed: read again unless a color is picked and not saved
  /// (`if(CL&&!clDirty())loadColor()`).
  @override
  void onSxClosed() {
    if (_data != null && !_dirty) _load();
  }

  bool get _dirty {
    final d = _data;
    return d != null && _hex.isNotEmpty && (_hex != d.hex || _name.text.trim() != d.name);
  }

  /// After every change: marks the tab and sends the color to the lights when they are on.
  void _markDirty() {
    AppScope.read(context).setDirty('color', _dirty);
    if (_data != null) _lights.push();
  }

  /// "Show it on the lights". Port of `cpGo`.
  void _lightsOn() => _lights.go(context, title: 'Close ShowXpress to show the colour on the lights?', again: 'Show it on the lights', onLost: _lightsLost);

  void _lightsLost(String error) {
    final reo = _lights.reopen;
    final why = error.startsWith('The DMX output stopped') ? 'the DMX interface was unplugged, or SX Studio lost it.' : error;
    AppScope.read(context).showResult(failedResult('clprev', 'The preview on the lights stopped: $why${reo ? ' ShowXpress is opening again.' : ''}'));
    if (reo) _launchSx();
  }

  Future<void> _launchSx() async {
    if (mounted) await launchSx(context);
  }

  /// Saving needs ShowXpress closed and the interface free: the preview ends
  /// first, and ShowXpress opens again after when the box was ticked.
  Future<void> _save() async {
    final app = AppScope.read(context);
    final reo = _lights.on && _lights.reopen;
    await _lights.stop(reopen: false);
    if (!mounted) return;
    await runSave(
      context,
      () => app.client.colorApply(_hex, _name.text.trim()),
      what: 'color',
      busy: "Saving tonight's color.",
      after: () async {
        await _load();
        app.showEdited();
      },
    );
    if (reo) await _launchSx();
  }

  /// Sets the color. Brightness follows it. [name] replaces the name unless [keepName].
  void _pick(String hex, {String name = '', bool keepName = false}) {
    _hex = hex.toLowerCase();
    if (!keepName) _name.text = name;
    _bright = _hex.isEmpty ? 100 : math.max(10, jsRound(hexToHsv(_hex).$3 * 100));
    if (!_hexFocus.hasFocus) _hexField.text = _hex.isEmpty ? '' : '#$_hex';
  }

  void _set(String hex, {String name = ''}) {
    setState(() => _pick(hex, name: name));
    _markDirty();
  }

  void _typedHex() {
    final v = _hexField.text.trim().replaceFirst(RegExp('^#'), '');
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v)) {
      _set(v);
    } else {
      setState(() => _hexField.text = _hex.isEmpty ? '' : '#$_hex');
    }
  }

  void _wheel(double h, double s) {
    setState(() {
      _hex = hsvToHex(h, s, _bright / 100);
      _name.text = '';
      if (!_hexFocus.hasFocus) _hexField.text = '#$_hex';
    });
    _markDirty();
  }

  void _brightness(double v) {
    setState(() {
      _bright = v.round();
      if (_hex.isNotEmpty) {
        final (h, s, _) = hexToHsv(_hex);
        _hex = hsvToHex(h, s, _bright / 100);
        if (!_hexFocus.hasFocus) _hexField.text = '#$_hex';
      }
    });
    _markDirty();
  }

  void _undo() {
    final d = _data!;
    setState(() {
      _name.text = d.name;
      _pick(d.hex, keepName: true);
    });
    _markDirty();
  }

  String _hint(AppState app) {
    final d = _data;
    if (d == null) return '';
    if (app.sxOpen) return 'ShowXpress is open. This is queued and done as soon as you save and close ShowXpress.';
    if (_hex.isEmpty) return 'Pick a colour.';
    if (!_dirty) return "This is tonight's colour already.";
    final miss = [for (final b in d.buttons.where((b) => !b.there)) b.page];
    return 'Writes the two TONIGHTS COLOR scenes${miss.isEmpty ? '' : ' and adds the button to the ${miss.join(' and ')} page${miss.length > 1 ? 's' : ''}'}.';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    final dirty = _dirty;
    return ScreenBody(
      bar: SaveBar(
        hint: _hint(app),
        actions: [
          TextButton(onPressed: dirty ? _undo : null, child: const Text('Undo')),
          FilledButton(onPressed: dirty ? _save : null, child: const Text('Save')),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(d, dirty),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null)
                // the old `.clwrap`: picks, then a 300 px result column; one column under 860 px
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: MediaQuery.sizeOf(context).width > 860
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _pickers()),
                            const SizedBox(width: 22),
                            SizedBox(width: 300, child: _result(d)),
                          ],
                        )
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_pickers(), const SizedBox(height: 22), _result(d)]),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Title, the saved-or-not pill and Refresh. On a phone the title takes the
  /// full width and the rest goes under it, as on the old page.
  Widget _header(ColorPreview? d, bool dirty) {
    const title = "Tonight's color";
    const sub =
        'The decor colour for tonight. Saving makes two ShowXpress buttons called TONIGHTS COLOR: on the MOVER COLORS page '
        '(every mover on the nearest colour of its wheel, colour only, so it goes on top of any movement) and on the UPLIGHTS page '
        '(the uplights in exactly this colour).';
    final actions = [
      if (d != null && (d.hex.isNotEmpty || _hex.isNotEmpty)) _StateTag(dirty: dirty),
      OutlinedButton(onPressed: _load, child: const Text('Refresh')),
    ];
    if (MediaQuery.sizeOf(context).width > 640) return SxHeader(title, sub: sub, actions: actions);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SxHeader(title, sub: sub),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: actions),
      ],
    );
  }

  Widget _pickers() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const GroupLabel('Quick picks'),
      LayoutBuilder(
        builder: (context, c) {
          // the old `.clpal`: columns of at least 104 px, two on a phone
          final cols = MediaQuery.sizeOf(context).width <= 640 ? 2 : math.max(2, (c.maxWidth + 6) ~/ 110);
          final w = (c.maxWidth - 6 * (cols - 1)) / cols;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (n, h) in colorPresets)
                SizedBox(
                  width: w,
                  child: _Preset(
                    name: n,
                    hex: h,
                    on: h == _hex,
                    onTap: () => _set(h, name: n),
                  ),
                ),
            ],
          );
        },
      ),
      const GroupLabel('Any colour'),
      Wrap(
        spacing: 22,
        runSpacing: 14,
        children: [
          ColorWheel(size: MediaQuery.sizeOf(context).width <= 640 ? 190 : 200, hex: _hex, brightness: _bright / 100, onPick: _wheel),
          SizedBox(
            width: 230,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    key: const Key('color-hex'),
                    controller: _hexField,
                    focusNode: _hexFocus,
                    maxLength: 7,
                    decoration: const InputDecoration(hintText: '#RRGGBB', counterText: ''),
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (_) => _typedHex(),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Brightness  $_bright%', style: TextStyle(fontSize: 12.5, color: Sx.dim)),
                Slider(min: 10, max: 100, value: _bright.toDouble().clamp(10, 100), onChanged: _brightness),
                Text('Tap or drag on the wheel. The uplights get exactly this colour, the movers only have their wheel colours.', style: Sx.sub),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  Widget _result(ColorPreview d) {
    final n140 = _hex.isEmpty ? null : nearestWheel(d.wheel140, _hex), n251 = _hex.isEmpty ? null : nearestWheel(d.wheel251, _hex);
    // the old `.kv` rows and `.sw` swatches
    Widget swatch(String hex) => Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: hexColor(hex),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Sx.line2),
      ),
    );
    Widget none() => Text('-', style: TextStyle(color: Sx.dim));
    Widget wheelRow(WheelColor? w) => w == null ? none() : Row(children: [swatch(w.hex), Text(w.name)]);
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 94,
            child: Text(label, style: TextStyle(fontSize: 12.5, color: Sx.dim)),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12.5, color: Sx.text, fontWeight: FontWeight.w500),
              child: value,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 120,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hex.isEmpty ? Sx.well : hexColor(_hex),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Sx.line),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            // a dark label that reads on any picked colour, in both themes
            decoration: BoxDecoration(color: Sx.isLight ? Sx.text.withValues(alpha: .7) : Sx.bg.withValues(alpha: .55), borderRadius: BorderRadius.circular(6)),
            child: Text(
              _hex.isEmpty ? 'pick a colour' : '#$_hex',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sx.isLight ? Sx.bg : Sx.text),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('color-name'),
          controller: _name,
          maxLength: 30,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(hintText: 'Name (optional), e.g. Blush', counterText: ''),
          onChanged: (_) {
            setState(() {});
            _markDirty();
          },
        ),
        const SizedBox(height: 8),
        row('140 movers', wheelRow(n140)),
        row('251 movers', wheelRow(n251)),
        row(
          'Uplights',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_hex.isEmpty) none() else ...[swatch(_hex), const Text('exact colour')],
                  if (d.washes.isEmpty) Text('  none found', style: TextStyle(color: Sx.amber)),
                ],
              ),
              if (d.washes.isNotEmpty)
                Text(
                  d.washes.join(', '),
                  style: TextStyle(fontSize: 11.5, color: Sx.dim, fontWeight: FontWeight.w400),
                ),
            ],
          ),
        ),
        if (d.hex.isNotEmpty)
          row(
            'Saved',
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                swatch(d.hex),
                Text('#${d.hex}${d.name.isEmpty ? '' : ' ${d.name}'}'),
                if (d.saved.isNotEmpty)
                  Text(
                    '  ${savedWhen(d.saved, DateTime.now())}',
                    style: TextStyle(color: Sx.dim, fontWeight: FontWeight.w400),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (!_lights.on)
          OutlinedButton.icon(
            onPressed: _lights.busy.isEmpty ? _lightsOn : null,
            icon: const Icon(Icons.lightbulb_outline, size: 17),
            label: const Text('Show it on the lights'),
          )
        else
          _LiveBox(_lights),
        if (_lights.busy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_lights.busy, style: TextStyle(fontSize: 12.5, color: Sx.amber)),
          ),
      ],
    );
  }
}

/// The old `.clpv`: the color is live on the lights, with Stop.
class _LiveBox extends StatelessWidget {
  const _LiveBox(this.lights);

  final OnTheLights lights;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Sx.green.withValues(alpha: .07),
      border: Border.all(color: Sx.green.withValues(alpha: .45)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 12.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: Sx.green,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Sx.green, blurRadius: 8)],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Live on the lights',
                  style: TextStyle(fontWeight: FontWeight.w700, color: Sx.text),
                ),
              ),
              MiniButton(
                'Stop',
                onPressed: lights.busy.isEmpty ? () => lights.stop(reopen: lights.reopen, context: context) : null,
              ),
            ],
          ),
          ReopenBox(lights),
          Text('ShowXpress is closed while this is on. Movers go to the dance-floor center on their nearest wheel colour.', style: TextStyle(color: Sx.dim)),
        ],
      ),
    ),
  );
}

class _Preset extends StatelessWidget {
  const _Preset({required this.name, required this.hex, required this.on, required this.onTap});

  final String name;
  final String hex;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: on ? Sx.accent.withValues(alpha: .08) : Sx.panel,
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: hexColor(hex),
              shape: BoxShape.circle,
              border: Border.all(color: Sx.line2),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    ),
  );
}

/// The old page's `.state` pill: blue "Not saved yet" or green "Matches the show".
class _StateTag extends StatelessWidget {
  const _StateTag({required this.dirty});

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final c = dirty ? Sx.blue : Sx.green;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: dirty ? .45 : .35)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(dirty ? Icons.circle : Icons.check, size: dirty ? 8 : 14, color: c),
          const SizedBox(width: 6),
          Text(
            dirty ? 'Not saved yet' : 'Matches the show',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}
