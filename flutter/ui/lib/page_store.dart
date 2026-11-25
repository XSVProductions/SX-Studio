import 'page_store_web.dart' if (dart.library.io) 'page_store_io.dart' as impl;

/// The settings this device keeps between visits, under the old page's own
/// `localStorage` keys (`sxh_theme`, `sxh_looks`, `sxh_mvlite`, `sxh_lvspd`,
/// `sxh_flip_<id>`). A phone loads the page from the same address the old app
/// used, so it keeps what it had. The laptop app keeps them in its own
/// preferences under the same keys.
abstract interface class PageStore {
  /// The kept value, or null.
  String? get(String key);

  /// Keeps [value] under [key]. Fails quietly when storage is off.
  void set(String key, String value);
}

/// This device's store.
Future<PageStore> openPageStore() => impl.open();
