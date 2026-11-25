import 'theme_store_web.dart' if (dart.library.io) 'theme_store_io.dart' as impl;

/// Where the old page kept the theme: `localStorage.sxh_theme`, one of
/// `dark`, `light` or `auto` (the old `themeMode`).
const themeStoreKey = 'sxh_theme';

/// The theme this device picked, as the old page wrote it, or null.
Future<String?> readThemeChoice() => impl.read();

/// Keeps the theme this device picked, under the old page's key.
Future<void> writeThemeChoice(String value) => impl.write(value);
