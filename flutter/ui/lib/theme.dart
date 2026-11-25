import 'package:flutter/material.dart';

/// SX Studio's colors. Dark only, on true black.
abstract final class Sx {
  static const bg = Color(0xFF000000);
  static const card = Color(0xFF14171D);
  static const panel = Color(0xFF12151B);
  static const well = Color(0xFF0C0E12);
  static const hover = Color(0xFF1D212A);
  static const line = Color(0xFF262B36);
  static const line2 = Color(0xFF3A4150);
  static const text = Color(0xFFFFFFFF);
  static const text2 = Color(0xFFC7CDD8);
  static const dim = Color(0xFF8B93A3);
  static const mute = Color(0xFF5D6574);
  static const accent = Color(0xFFA3E635);
  static const amber = Color(0xFFFFB020);
  static const green = Color(0xFF3DDC84);
  static const red = Color(0xFFFF5C5C);
  static const redText = Color(0xFFFFC9C9);
  static const blue = Color(0xFF5AA9FF);

  /// Body font and the wide display font used for headings and labels.
  static const body = 'Saira';
  static const display = 'Orbitron';

  /// Widest a screen's content grows on a big window.
  static const contentWidth = 1080.0;

  /// A card title ("Speed faders").
  static const title = TextStyle(fontFamily: display, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: .5, color: text);

  /// A small caps label over a group ("BEFORE THE GIG").
  static const label = TextStyle(fontFamily: display, fontSize: 10.5, fontWeight: FontWeight.w500, letterSpacing: 1.4, color: dim);

  /// Secondary text under a title or in a row.
  static const sub = TextStyle(fontSize: 13, color: dim, height: 1.4);
}

ThemeData sxTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    fontFamily: Sx.body,
    scaffoldBackgroundColor: Sx.bg,
    colorScheme: const ColorScheme.dark(primary: Sx.accent, onPrimary: Colors.black, surface: Sx.card, onSurface: Sx.text, error: Sx.red, outline: Sx.line),
    // No ripple: it repaints every frame while it spreads.
    splashFactory: NoSplash.splashFactory,
    dividerColor: Sx.line,
  );
  final flat = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Sx.text, displayColor: Sx.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Sx.accent,
        foregroundColor: Colors.black,
        disabledBackgroundColor: Sx.hover,
        disabledForegroundColor: Sx.mute,
        shape: flat,
        textStyle: const TextStyle(fontFamily: Sx.body, fontWeight: FontWeight.w700, letterSpacing: .4),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Sx.text,
        side: const BorderSide(color: Sx.line2),
        shape: flat,
        textStyle: const TextStyle(fontFamily: Sx.body, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Sx.text2, shape: flat),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Sx.well,
      hintStyle: const TextStyle(color: Sx.mute),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Sx.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Sx.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Sx.accent),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Sx.panel),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Sx.line),
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Sx.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Sx.line),
      ),
    ),
  );
}
