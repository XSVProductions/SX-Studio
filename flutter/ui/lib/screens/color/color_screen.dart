import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'color_wheel.dart';

/// Quick picks: decor colors couples ask for.
const colorPresets = [
  ('Red', 'ff0000'), ('Wine', '8b0a2a'), ('Rose', 'ff2a6d'), ('Blush', 'f4a6b8'), ('Hot pink', 'ff3fa4'), ('Magenta', 'ff00ff'), //
  ('Purple', '8a2be2'), ('Lavender', 'b48cff'), ('Royal blue', '1f3fff'), ('Navy', '0a1a6e'), ('Sky blue', '6ec8ff'),
  ('Teal', '00a8a8'), ('Mint', '7dffc4'), ('Emerald', '00b050'), ('Lime', '9aff00'), ('Gold', 'ffb000'), ('Yellow', 'ffee00'),
  ('Peach', 'ffb38a'), ('Orange', 'ff6a00'), ('Warm white', 'ffd9a8'), ('Cold white', 'e6f2ff'),
];

Color hexColor(String hex) => Color(0xFF000000 | int.parse(hex, radix: 16));

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

class _ColorScreenState extends State<ColorScreen> {
  ColorPreview? _data;
  var _error = '';

  /// The picked color, `rrggbb`, or '' before one is picked.
  var _hex = '';

  /// Brightness, 10 to 100.
  var _bright = 100;
  final _name = TextEditingController();
  final _hexField = TextEditingController();
  final _hexFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hexFocus.addListener(() {
      if (!_hexFocus.hasFocus) _typedHex();
    });
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _hexField.dispose();
    _hexFocus.dispose();
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

  bool get _dirty {
    final d = _data;
    return d != null && _hex.isNotEmpty && (_hex != d.hex || _name.text.trim() != d.name);
  }

  void _markDirty() => AppScope.read(context).setDirty('color', _dirty);

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
          FilledButton(
            onPressed: dirty ? () => runSave(context, () => app.client.colorApply(_hex, _name.text.trim()), after: _load) : null,
            child: const Text('Save'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SxHeader(
                "Tonight's color",
                sub:
                    'The decor colour for tonight. Saving makes two ShowXpress buttons called TONIGHTS COLOR: on the MOVER COLORS page '
                    '(every mover on the nearest colour of its wheel, colour only, so it goes on top of any movement) and on the UPLIGHTS page '
                    '(the uplights in exactly this colour).',
                actions: [
                  // on a phone the save bar's hint says the same, and the title needs the room
                  if (d != null && (d.hex.isNotEmpty || _hex.isNotEmpty) && MediaQuery.sizeOf(context).width >= 600)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(dirty ? 'Not saved yet' : 'Matches the show', style: TextStyle(fontSize: 12.5, color: dirty ? Sx.amber : Sx.green)),
                    ),
                  OutlinedButton(onPressed: _load, child: const Text('Refresh')),
                ],
              ),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null)
                LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 720;
                    final left = _pickers(), right = _result(d);
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 3, child: left),
                                const SizedBox(width: 26),
                                Expanded(flex: 2, child: right),
                              ],
                            )
                          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 18), right]),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pickers() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const GroupLabel('Quick picks'),
      LayoutBuilder(
        builder: (context, c) {
          final cols = math.max(2, (c.maxWidth + 6) ~/ 110);
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
          ColorWheel(size: 200, hex: _hex, brightness: _bright / 100, onPick: _wheel),
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
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5),
                    onSubmitted: (_) => _typedHex(),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Brightness  $_bright%', style: const TextStyle(fontSize: 12.5, color: Sx.dim)),
                Slider(min: 10, max: 100, value: _bright.toDouble().clamp(10, 100), onChanged: _brightness),
                const Text('Tap or drag on the wheel. The uplights get exactly this colour, the movers only have their wheel colours.', style: Sx.sub),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  Widget _result(ColorPreview d) {
    final n140 = _hex.isEmpty ? null : nearestWheel(d.wheel140, _hex), n251 = _hex.isEmpty ? null : nearestWheel(d.wheel251, _hex);
    Widget swatch(String hex) => Container(
      width: 14,
      height: 14,
      margin: const EdgeInsets.only(right: 7),
      decoration: BoxDecoration(
        color: hexColor(hex),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Sx.line2),
      ),
    );
    Widget wheelRow(WheelColor? w) => w == null ? const Text('-', style: TextStyle(color: Sx.dim)) : Row(children: [swatch(w.hex), Text(w.name)]);
    Widget row(String label, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(label, style: const TextStyle(fontSize: 13, color: Sx.dim)),
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              child: value,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        Container(
          height: 120,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _hex.isEmpty ? Sx.well : hexColor(_hex),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Sx.line),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: const Color(0x8C000000), borderRadius: BorderRadius.circular(6)),
            child: Text(
              _hex.isEmpty ? 'pick a colour' : '#$_hex',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sx.text),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('color-name'),
          controller: _name,
          maxLength: 30,
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
                  if (_hex.isEmpty) const Text('-', style: TextStyle(color: Sx.dim)) else ...[swatch(_hex), const Text('exact colour')],
                  if (d.washes.isEmpty) const Text('  none found', style: TextStyle(color: Sx.amber)),
                ],
              ),
              if (d.washes.isNotEmpty)
                Text(
                  d.washes.join(', '),
                  style: const TextStyle(fontSize: 12, color: Sx.dim, fontWeight: FontWeight.w400),
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
                    style: const TextStyle(color: Sx.dim, fontWeight: FontWeight.w400),
                  ),
              ],
            ),
          ),
      ],
    );
  }
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
        color: on ? const Color(0x14A3E635) : Sx.panel,
        border: Border.all(color: on ? Sx.accent : Sx.line),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(color: hexColor(hex), borderRadius: BorderRadius.circular(4)),
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
