import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'color_screen.dart' show hexColor;

/// JavaScript's `Math.round`: halves go up. The old page did its color maths
/// in JavaScript, so the picker gives the same hex for the same spot.
int jsRound(num v) => (v + 0.5).floor();

/// Hue 0..360, saturation and value 0..1, to `rrggbb`. Port of `hsv2hex`.
String hsvToHex(double h, double s, double v) {
  double f(int n) {
    final k = (n + h / 60) % 6;
    return v - v * s * math.max(0, math.min(k, math.min(4 - k, 1)));
  }

  return [f(5), f(3), f(1)].map((x) => jsRound(x * 255).toRadixString(16).padLeft(2, '0')).join();
}

/// `rrggbb` to (hue 0..360, saturation 0..1, value 0..1). Port of `hex2hsv`.
(double, double, double) hexToHsv(String hex) {
  double ch(int i) => int.parse(hex.substring(i, i + 2), radix: 16) / 255;
  final r = ch(0), g = ch(2), b = ch(4);
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b)), d = mx - mn;
  var h = 0.0;
  if (d != 0) {
    h = mx == r
        ? ((g - b) / d).remainder(6)
        : mx == g
        ? (b - r) / d + 2
        : (r - g) / d + 4;
    h = (h * 60 + 360) % 360;
  }
  return (h, mx == 0 ? 0 : d / mx, mx);
}

/// A hue and saturation wheel to tap or drag on. Drawn as flat segments (no
/// gradients), dimmed to [brightness]. The knob sits on [hex].
class ColorWheel extends StatelessWidget {
  const ColorWheel({super.key, required this.size, required this.hex, required this.brightness, required this.onPick});

  final double size;
  final String hex;
  final double brightness;

  /// Hue 0..360 and saturation 0..1 of the spot touched.
  final void Function(double h, double s) onPick;

  void _at(Offset p) {
    final r = size / 2, x = p.dx - r, y = p.dy - r;
    final s = math.min(1.0, math.sqrt(x * x + y * y) / r);
    final h = (math.atan2(x, -y) * 180 / math.pi + 360) % 360;
    onPick(h, s);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanDown: (d) => _at(d.localPosition),
    onPanUpdate: (d) => _at(d.localPosition),
    child: CustomPaint(
      size: Size.square(size),
      painter: _WheelPainter(brightness: math.max(.25, brightness), hex: hex),
    ),
  );
}

class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.brightness, required this.hex});

  final double brightness;
  final String hex;

  static const _hues = 48, _rings = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), r = size.width / 2;
    final paint = Paint()..isAntiAlias = true;
    final step = 2 * math.pi / _hues;
    for (var ring = 0; ring < _rings; ring++) {
      final r0 = r * ring / _rings, r1 = r * (ring + 1) / _rings;
      final s = (ring + .5) / _rings;
      for (var i = 0; i < _hues; i++) {
        final h = (i + .5) * 360 / _hues;
        // hue 0 points up and goes clockwise, as on the old page
        final a0 = -math.pi / 2 + i * step, a1 = a0 + step + .01;
        final path = Path()
          ..moveTo(c.dx + r0 * math.cos(a0), c.dy + r0 * math.sin(a0))
          ..lineTo(c.dx + r1 * math.cos(a0), c.dy + r1 * math.sin(a0))
          ..arcTo(Rect.fromCircle(center: c, radius: r1), a0, a1 - a0, false)
          ..lineTo(c.dx + r0 * math.cos(a1), c.dy + r0 * math.sin(a1));
        if (r0 > 0) path.arcTo(Rect.fromCircle(center: c, radius: r0), a1, a0 - a1, false);
        path.close();
        canvas.drawPath(path, paint..color = hexColor(hsvToHex(h, s, brightness)));
      }
    }
    if (hex.isEmpty) return;
    final (h, s, _) = hexToHsv(hex);
    final a = h * math.pi / 180;
    // the knob: a light ring with a thin dark edge, from the theme
    final k = Offset(c.dx + math.sin(a) * s * r, c.dy - math.cos(a) * s * r);
    canvas.drawCircle(k, 10, Paint()..color = hexColor(hex));
    canvas.drawCircle(
      k,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Sx.isLight ? Sx.bg : Sx.text,
    );
    canvas.drawCircle(
      k,
      11.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Sx.isLight ? Sx.text : Sx.bg,
    );
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.brightness != brightness || old.hex != hex;
}
