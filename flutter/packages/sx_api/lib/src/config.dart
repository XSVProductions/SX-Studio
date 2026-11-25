import 'client.dart';
import 'json.dart';
import 'settings.dart';

// EXPORT / IMPORT SETTINGS: SX Studio's settings in one JSON file,
// `{ app: 'SX Studio', kind: 'settings', format: 1, version, saved, settings,
// apc40, autoShow, apcMini, speedFaders, phone, device }`. The old app and
// this one read each other's files.

/// The local storage names of this computer's own choices (light or dark,
/// Looks options, live-aim view), as the old page kept them. The phone key is
/// never one of them. Port of the page's `devKeys` test.
final deviceKeyPattern = RegExp(r'^sxh_[\w\-]{1,60}$', caseSensitive: false);

/// The one `sxh_` name that never leaves this computer.
const phoneKeyName = 'sxh_phone_key';

/// A settings file the user picked, read before it is sent. The card checks
/// it and lists what it replaces, as the old page did before asking.
class SettingsFile {
  SettingsFile(this.raw);

  /// The file as it was read. Sent to the engine untouched.
  final Json raw;

  /// The page's own check: `d.app==='SX Studio'&&d.kind==='settings'`.
  bool get isSettingsFile => raw['app'] == 'SX Studio' && raw['kind'] == 'settings';

  /// When it was saved (`yyyy-MM-ddTHH:mm:ss`), or ''.
  String get saved => _text(raw['saved']);

  /// The SX Studio version that saved it, or ''.
  String get version => _text(raw['version']);

  /// This computer's own choices in the file, or null when it has none.
  /// The page's test on import: an `sxh_` name, not the phone key, and text.
  Map<String, String>? get device {
    final d = raw['device'];
    if (d is! Map) return null;
    return {
      for (final MapEntry(:key, :value) in d.entries)
        if (key is String && key.startsWith('sxh_') && key != phoneKeyName && value is String) key: value,
    };
  }

  /// What the file replaces, in the old page's words and order.
  List<String> get parts => [
    if (_truthy(raw['settings'])) 'the tabs and the SX Player pages',
    if (_truthy(raw['apc40'])) 'the APC40 pads and faders',
    if (_truthy(raw['apcMini'])) 'the APC mini pads',
    if (_truthy(raw['speedFaders'])) 'the speed faders',
    if (_truthy(raw['autoShow'])) 'the Auto Show',
    if (_truthy(raw['phone'])) 'phone access on/off',
    if (raw['device'] is Map) "this computer's own choices",
  ];

  static String _text(Object? v) => v == null ? '' : '$v';

  /// JavaScript's truthiness, as the page tested each part.
  static bool _truthy(Object? v) => switch (v) {
    null => false,
    bool b => b,
    num n => n != 0 && !n.isNaN,
    String s => s.isNotEmpty,
    _ => true,
  };
}

/// What `/api/config/export` answers when the file was saved.
class ConfigExportResult {
  const ConfigExportResult({required this.path, required this.name, required this.folder});

  factory ConfigExportResult.fromJson(Json j) => ConfigExportResult(path: j.str('path'), name: j.str('name'), folder: j.str('folder'));

  /// The whole path of the file.
  final String path;

  /// The file's name, `SX Studio settings <date>.json`.
  final String name;

  /// The folder it is in: Downloads, or SX Studio's own `exports` folder.
  final String folder;

  Json toJson() => {'ok': true, 'path': path, 'name': name, 'folder': folder};
}

/// What `/api/config/import` answers when the import ran.
class ConfigImportResult {
  const ConfigImportResult({required this.done, required this.warn, required this.settings, required this.backup});

  factory ConfigImportResult.fromJson(Json j) =>
      ConfigImportResult(done: j.strList('done'), warn: j.strList('warn'), settings: SxSettings.fromJson(j.obj('settings')), backup: j.str('backup'));

  /// The parts that were imported, in the order they were applied.
  final List<String> done;

  /// The parts that were kept as they were, and why.
  final List<String> warn;

  /// The settings as they are now.
  final SxSettings settings;

  /// The folder holding what was there before.
  final String backup;
}

/// "a, b and c", the page's `andList`.
String andList(List<String> a) => a.length > 1 ? '${a.sublist(0, a.length - 1).join(', ')} and ${a.last}' : a.join();

extension ConfigApi on SxClient {
  /// Saves the settings to one file, with this computer's own choices
  /// [device]. Computer only.
  Future<ConfigExportResult> configExport(Map<String, String> device) => post('/api/config/export', {'device': device}, ConfigExportResult.fromJson);

  /// Imports a settings file. Computer only.
  Future<ConfigImportResult> configImport(Json data) => post('/api/config/import', {'data': data}, ConfigImportResult.fromJson);

  /// Shows the last exported file in Explorer or Finder.
  Future<ToolResult> revealExport() => run('/api/open', {'what': 'export'});
}
