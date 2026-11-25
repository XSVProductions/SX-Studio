import 'client.dart';
import 'json.dart';
import 'lab.dart';

/// The tab ids the settings know, in the old app's default order.
const settingsTabIds = ['rt', 'aim', 'color', 'pre', 'lab', 'auto', 'rig', 'skip', 'apc', 'speed', 'scene', 'move', 'look', 'health'];

/// SX Studio's own settings (`settings.json` in the settings folder). The
/// laptop, phones and tablets share the tab layout.
class SxSettings {
  const SxSettings({
    this.tabOrder = settingsTabIds,
    this.tabHidden = const [],
    this.tabNames = const {},
    this.playerLayout = const PlayerLayout(),
    this.reopen = true,
    this.autoUpd = true,
    this.driveFolder = '',
  });

  factory SxSettings.fromJson(Json j) => SxSettings(
    tabOrder: j.strList('tabOrder'),
    tabHidden: j.strList('tabHidden'),
    tabNames: {for (final e in j.obj('tabNames').entries) e.key: '${e.value}'},
    playerLayout: PlayerLayout.fromJson(j.obj('playerLayout')),
    reopen: j.boolean('reopen'),
    autoUpd: j.boolean('autoUpd'),
    driveFolder: j.str('driveFolder'),
  );

  /// Every tab id once. The tab bar sorts them into their menus and keeps
  /// this order inside each menu.
  final List<String> tabOrder;

  /// Tabs the user unticked. They leave the tab bar and the Home screen.
  final List<String> tabHidden;

  /// The user's own names, by tab id. A tab not in here keeps its own name.
  final Map<String, String> tabNames;
  final PlayerLayout playerLayout;

  /// Open ShowXpress again after the save queue ran.
  final bool reopen;

  /// Check GitHub for a new version when SX Studio opens.
  final bool autoUpd;

  /// Google Drive's My Drive folder, set by hand. Empty means find it.
  final String driveFolder;

  Json toJson() => {
    'tabOrder': tabOrder,
    'tabHidden': tabHidden,
    'tabNames': tabNames,
    'playerLayout': playerLayout.toJson(),
    'reopen': reopen,
    'autoUpd': autoUpd,
    'driveFolder': driveFolder,
  };
}

/// What `/api/settings` answers.
class SettingsInfo {
  const SettingsInfo({required this.settings, required this.ver, this.phone = false});

  factory SettingsInfo.fromJson(Json j) => SettingsInfo(settings: SxSettings.fromJson(j.obj('settings')), ver: j.str('ver'), phone: j.boolean('phone'));

  final SxSettings settings;

  /// SX Studio's version.
  final String ver;

  /// True when a phone or tablet asked. The laptop-only parts are hidden then.
  final bool phone;

  Json toJson() => {'ok': true, 'settings': settings.toJson(), 'ver': ver, 'phone': phone};
}

/// A change to the settings. Only the fields that are set are sent. A phone
/// may change the tabs and the player layout, the rest is laptop only.
class SettingsChange {
  const SettingsChange({this.tabOrder, this.tabHidden, this.tabNames, this.playerLayout, this.reopen, this.autoUpd, this.driveFolder});

  final List<String>? tabOrder;
  final List<String>? tabHidden;
  final Map<String, String>? tabNames;
  final PlayerLayout? playerLayout;
  final bool? reopen;
  final bool? autoUpd;
  final String? driveFolder;

  Json toJson() => {
    'tabOrder': ?tabOrder,
    'tabHidden': ?tabHidden,
    'tabNames': ?tabNames,
    'playerLayout': ?playerLayout?.toJson(),
    'reopen': ?reopen,
    'autoUpd': ?autoUpd,
    'driveFolder': ?driveFolder,
  };
}

/// What `/api/open` can open on the laptop.
enum OpenTarget {
  /// The show folder.
  show,

  /// The folder with the shows kept before each Google Drive import.
  backups,

  /// Google's download page for Google Drive for desktop.
  gddl,

  /// Google Drive for desktop itself.
  gdapp,
}

extension SettingsApi on SxClient {
  Future<SettingsInfo> settings() => get('/api/settings', SettingsInfo.fromJson);

  /// Saves [change] and answers the settings as they are now.
  Future<SxSettings> settingsSet(SettingsChange change) => post('/api/settings/set', change.toJson(), (j) => SxSettings.fromJson(j.obj('settings')));

  /// Opens a folder, app or page on the laptop. Laptop only.
  Future<ToolResult> openOnComputer(OpenTarget what) => run('/api/open', {'what': what.name});
}
