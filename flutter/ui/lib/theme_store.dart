import 'page_store.dart';

/// Where the old page kept the theme: `localStorage.sxh_theme`, one of
/// `dark`, `light` or `auto` (the old `themeMode`).
const themeStoreKey = 'sxh_theme';

/// The theme this device picked, as the old page wrote it, or null.
Future<String?> readThemeChoice() async => (await openPageStore()).get(themeStoreKey);

/// Keeps the theme this device picked, under the old page's key.
Future<void> writeThemeChoice(String value) async => (await openPageStore()).set(themeStoreKey, value);
