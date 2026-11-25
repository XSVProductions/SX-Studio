import 'package:flutter/material.dart';

/// One set of the old app's CSS color variables (`:root` and `html.light` in
/// `df_aim_gui.ps1`).
class SxPalette {
  const SxPalette({
    required this.light,
    required this.bg,
    required this.card,
    required this.panel,
    required this.well,
    required this.hover,
    required this.tabOn,
    required this.line,
    required this.line2,
    required this.text,
    required this.text2,
    required this.dim,
    required this.mute,
    required this.accent,
    required this.amber,
    required this.green,
    required this.red,
    required this.redText,
    required this.blue,
  });

  final bool light;
  final Color bg, card, panel, well, hover, tabOn, line, line2;
  final Color text, text2, dim, mute;
  final Color accent, amber, green, red, redText, blue;
}

const _dark = SxPalette(
  light: false,
  bg: Color(0xFF0E1014),
  card: Color(0xFF171A21),
  panel: Color(0xFF12151B),
  well: Color(0xFF0F1217),
  hover: Color(0xFF1D212A),
  tabOn: Color(0xFF262B36),
  line: Color(0xFF262B36),
  line2: Color(0xFF3A4150),
  text: Color(0xFFE9ECF1),
  text2: Color(0xFFC7CDD8),
  dim: Color(0xFF8B93A3),
  mute: Color(0xFF5D6574),
  accent: Color(0xFFA3E635),
  amber: Color(0xFFFFB020),
  green: Color(0xFF3DDC84),
  red: Color(0xFFFF5C5C),
  redText: Color(0xFFFFC9C9),
  blue: Color(0xFF5AA9FF),
);

const _light = SxPalette(
  light: true,
  bg: Color(0xFFEEF0F4),
  card: Color(0xFFFFFFFF),
  panel: Color(0xFFF4F6F9),
  well: Color(0xFFE8EBF0),
  hover: Color(0xFFE6E9EF),
  tabOn: Color(0xFFFFFFFF),
  line: Color(0xFFD3D8E1),
  line2: Color(0xFFAAB2BF),
  text: Color(0xFF141821),
  text2: Color(0xFF2B313D),
  dim: Color(0xFF566070),
  mute: Color(0xFF7D8696),
  accent: Color(0xFF4D7C0F),
  amber: Color(0xFFD98200),
  green: Color(0xFF13994B),
  red: Color(0xFFD63333),
  redText: Color(0xFFB3261E),
  blue: Color(0xFF1D6AD0),
);

/// SX Studio's colors, fonts and text styles, copied from the old app.
///
/// The colors are getters because Settings can switch between the dark and
/// the light set. So never write `const` around one, never keep one in a
/// field or a `static final`, and never use a literal color. Read them in
/// `build` (or `paint`) every time.
abstract final class Sx {
  static SxPalette _p = _dark;

  /// Switches every color. The app calls this, then rebuilds the whole tree.
  static void use({required bool light}) => _p = light ? _light : _dark;

  static bool get isLight => _p.light;

  static Color get bg => _p.bg;
  static Color get card => _p.card;
  static Color get panel => _p.panel;
  static Color get well => _p.well;
  static Color get hover => _p.hover;

  /// Fill of the tab or segment that is on.
  static Color get tabOn => _p.tabOn;
  static Color get line => _p.line;
  static Color get line2 => _p.line2;
  static Color get text => _p.text;
  static Color get text2 => _p.text2;
  static Color get dim => _p.dim;
  static Color get mute => _p.mute;
  static Color get accent => _p.accent;
  static Color get amber => _p.amber;
  static Color get green => _p.green;
  static Color get red => _p.red;
  static Color get redText => _p.redText;
  static Color get blue => _p.blue;

  /// The lime of the main button, the same in both themes, and its text.
  static const primaryTop = Color(0xFFB8F25A);
  static const primaryBottom = Color(0xFF8CCF1F);
  static const onPrimary = Color(0xFF142000);

  /// Body font and the wide display font used for headings and labels.
  static const body = 'Saira';
  static const display = 'Orbitron';

  /// Widest a screen's content grows on a big window.
  static const contentWidth = 1080.0;

  /// A card title ("Speed faders").
  static TextStyle get title => TextStyle(fontFamily: display, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: .5, color: text);

  /// A small caps label over a group ("BEFORE THE GIG").
  static TextStyle get label => TextStyle(fontFamily: display, fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: 1.4, color: dim);

  /// Secondary text under a title or in a row.
  static TextStyle get sub => TextStyle(fontSize: 13, color: dim, height: 1.4);

  /// A tinted box: [color] as a faint fill with a stronger border. The old
  /// app's pills, warning boxes and queue bar all use this.
  static BoxDecoration tint(Color color, {double radius = 10}) => BoxDecoration(
    color: color.withValues(alpha: .08),
    border: Border.all(color: color.withValues(alpha: .4)),
    borderRadius: BorderRadius.circular(radius),
  );
}

/// The Material theme built from the current [Sx] colors.
ThemeData sxTheme() {
  final base = ThemeData(
    brightness: Sx.isLight ? Brightness.light : Brightness.dark,
    fontFamily: Sx.body,
    scaffoldBackgroundColor: Sx.bg,
    colorScheme: (Sx.isLight ? const ColorScheme.light() : const ColorScheme.dark()).copyWith(
      primary: Sx.accent,
      onPrimary: Sx.isLight ? Colors.white : Sx.onPrimary,
      surface: Sx.card,
      onSurface: Sx.text,
      error: Sx.red,
      outline: Sx.line,
    ),
    // No ripple: it repaints every frame while it spreads.
    splashFactory: NoSplash.splashFactory,
    dividerColor: Sx.line,
  );
  final round = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  final text = base.textTheme.apply(bodyColor: Sx.text, displayColor: Sx.text);
  return base.copyWith(
    textTheme: text.copyWith(bodyMedium: text.bodyMedium?.copyWith(fontSize: 14.5, letterSpacing: .1)),
    // The main button on a screen: the old app's `.primary`.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        foregroundColor: Sx.onPrimary,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: Sx.mute,
        shape: round,
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: .4),
        backgroundBuilder: (context, states, child) => DecoratedBox(
          decoration: states.contains(WidgetState.disabled)
              ? BoxDecoration(color: Sx.hover, borderRadius: BorderRadius.circular(10))
              : BoxDecoration(
                  gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Sx.primaryTop, Sx.primaryBottom]),
                  borderRadius: BorderRadius.circular(10),
                ),
          child: child,
        ),
      ),
    ),
    // Every other button: the old app's plain `button`.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: Sx.hover,
        foregroundColor: Sx.text,
        disabledForegroundColor: Sx.mute,
        side: BorderSide(color: Sx.line),
        shape: round,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Sx.text2, shape: round),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Sx.well,
      hintStyle: TextStyle(color: Sx.mute),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Sx.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Sx.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Sx.accent),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Sx.panel),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(color: Sx.line),
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Sx.card,
      barrierColor: Sx.isLight ? const Color(0x59141821) : const Color(0x99000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Sx.line),
      ),
    ),
  );
}
