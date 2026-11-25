import 'dart:math' as math;

import 'client.dart';
import 'json.dart';

/// One slot of a mover's color wheel: its name, the DMX value that selects it
/// and about how it looks (`rrggbb`).
class WheelColor {
  const WheelColor({required this.name, required this.value, required this.hex});

  factory WheelColor.fromJson(Json j) => WheelColor(name: j.str('name'), value: j.integer('value'), hex: j.str('hex'));

  final String name;
  final int value;
  final String hex;

  Json toJson() => {'name': name, 'value': value, 'hex': hex};
}

/// One of the two TONIGHTS COLOR live buttons and whether the show has it yet.
class ColorButton {
  const ColorButton({required this.page, required this.scene, required this.there});

  factory ColorButton.fromJson(Json j) => ColorButton(page: j.str('page'), scene: j.str('scene'), there: j.boolean('there'));

  /// The live page the button goes on (MOVER COLORS, UPLIGHTS).
  final String page;

  /// The scene's name without `.scex`.
  final String scene;
  final bool there;

  Json toJson() => {'page': page, 'scene': scene, 'there': there};
}

/// An uplight with its DMX start address, for showing the color on the real lights.
class WashFixture {
  const WashFixture({required this.name, required this.addr, required this.chs});

  factory WashFixture.fromJson(Json j) => WashFixture(name: j.str('name'), addr: j.integer('addr'), chs: j.strList('chs'));

  final String name;
  final int addr;

  /// Channel names, lowercase, in DMX order.
  final List<String> chs;

  Json toJson() => {'name': name, 'addr': addr, 'chs': chs};
}

/// What the Tonight's Color screen shows.
class ColorPreview {
  const ColorPreview({
    required this.show,
    required this.hex,
    required this.name,
    required this.saved,
    required this.wheel140,
    required this.wheel251,
    required this.washes,
    required this.buttons,
    required this.washFix,
  });

  factory ColorPreview.fromJson(Json j) => ColorPreview(
    show: j.str('show'),
    hex: j.str('hex'),
    name: j.str('name'),
    saved: j.str('saved'),
    wheel140: j.list('wheel140', WheelColor.fromJson),
    wheel251: j.list('wheel251', WheelColor.fromJson),
    washes: j.strList('washes'),
    buttons: j.list('buttons', ColorButton.fromJson),
    washFix: j.list('washFix', WashFixture.fromJson),
  );

  final String show;

  /// The saved color (`rrggbb`), or '' when none was ever saved.
  final String hex;
  final String name;

  /// When it was saved, as `yyyy-MM-ddTHH:mm:ss` local time, or ''.
  final String saved;
  final List<WheelColor> wheel140;
  final List<WheelColor> wheel251;

  /// Names of the uplights that get the exact color.
  final List<String> washes;
  final List<ColorButton> buttons;
  final List<WashFixture> washFix;

  Json toJson() => {
    'ok': true,
    'show': show,
    'hex': hex,
    'name': name,
    'saved': saved,
    'wheel140': [for (final w in wheel140) w.toJson()],
    'wheel251': [for (final w in wheel251) w.toJson()],
    'washes': washes,
    'buttons': [for (final b in buttons) b.toJson()],
    'washFix': [for (final w in washFix) w.toJson()],
  };
}

/// `[r, g, b]` of an `rrggbb` string.
List<int> hexRgb(String hex) => [for (var i = 0; i < 6; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];

/// The wheel slot that looks most like [hex]. Both are compared at full
/// brightness, so a dark navy still picks blue. Null for an empty wheel.
///
/// Port of `Get-Nearest` in `color.ps1` (and `nearest()` on the old page).
WheelColor? nearestWheel(List<WheelColor> wheel, String hex) {
  final c = hexRgb(hex);
  final mx = [1, ...c].reduce((a, b) => a > b ? a : b);
  final s = [for (final x in c) x * 255.0 / mx];
  WheelColor? best;
  var bd = double.maxFinite;
  for (final w in wheel) {
    final r = hexRgb(w.hex);
    // [Math]::Pow like the old tool, not x * x, so near-ties break the same way
    final d = 0.30 * math.pow(s[0] - r[0], 2) + 0.59 * math.pow(s[1] - r[1], 2) + 0.11 * math.pow(s[2] - r[2], 2);
    if (d < bd) {
      bd = d;
      best = w;
    }
  }
  return best;
}

extension ColorApi on SxClient {
  Future<ColorPreview> color() => get('/api/color', ColorPreview.fromJson);

  /// Saves [hex] (`rrggbb`) as tonight's color. [name] is optional.
  Future<ToolResult> colorApply(String hex, String name) => run('/api/color/apply', {'hex': hex, 'name': name});
}
