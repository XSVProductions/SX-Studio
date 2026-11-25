import 'client.dart';
import 'json.dart';

/// The tab ids the settings know, in the old app's default order.
const settingsTabIds = ['rt', 'aim', 'color', 'pre', 'lab', 'auto', 'rig', 'skip', 'apc', 'speed', 'scene', 'move', 'look', 'health'];

/// One button on a page the SX Player made itself (`custom[].buttons[]`).
class PlayerButton {
  const PlayerButton({
    required this.id,
    required this.title,
    required this.file,
    this.fader = 0,
    this.bpm = false,
    this.flash = false,
    this.beats = 1.0,
    this.color = -1,
  });

  factory PlayerButton.fromJson(Json j) => PlayerButton(
    id: j.str('id'),
    title: j.str('title'),
    file: j.str('file'),
    fader: j.integer('fader'),
    bpm: j.boolean('bpm'),
    flash: j.boolean('flash'),
    beats: j.number('beats'),
    color: j.integer('color'),
  );

  /// `x<page>_b<n>`.
  final String id;
  final String title;

  /// The show's `.scex` or `.gpj` file it plays.
  final String file;

  /// Master speed fader, 0 to 15.
  final int fader;
  final bool bpm;
  final bool flash;
  final double beats;

  /// 0xRRGGBB, or -1 for none.
  final int color;

  Json toJson() => {'id': id, 'title': title, 'file': file, 'fader': fader, 'bpm': bpm, 'flash': flash, 'beats': beats, 'color': color};
}

/// A page that only exists in the SX Player (`custom[]`).
class PlayerPage {
  const PlayerPage({required this.id, required this.name, this.swap = false, this.buttons = const []});

  factory PlayerPage.fromJson(Json j) => PlayerPage(id: j.str('id'), name: j.str('name'), swap: j.boolean('swap'), buttons: j.list('buttons', PlayerButton.fromJson));

  /// `x<n>`.
  final String id;
  final String name;
  final bool swap;
  final List<PlayerButton> buttons;

  Json toJson() => {
    'id': id,
    'name': name,
    'swap': swap,
    'buttons': [for (final b in buttons) b.toJson()],
  };
}

/// How the SX Player tab arranges the show's pages and buttons. Only the
/// player's own view: ShowXpress's live screen is never changed.
class PlayerLayout {
  const PlayerLayout({this.pages = const [], this.order = const {}, this.hidden = const [], this.collapsed = const [], this.custom = const []});

  factory PlayerLayout.fromJson(Json j) => PlayerLayout(
    pages: j.strList('pages'),
    order: {for (final e in j.obj('order').entries) e.key: <String, Object?>{'v': e.value}.strList('v')},
    hidden: j.strList('hidden'),
    collapsed: j.strList('collapsed'),
    custom: j.list('custom', PlayerPage.fromJson),
  );

  /// Page numbers (`"3"`) and player page ids (`"x1"`) in the order shown.
  final List<String> pages;

  /// Button sections in the order shown, per page.
  final Map<String, List<String>> order;
  final List<String> hidden;
  final List<String> collapsed;
  final List<PlayerPage> custom;

  Json toJson() => {
    'pages': pages,
    'order': order,
    'hidden': hidden,
    'collapsed': collapsed,
    'custom': [for (final c in custom) c.toJson()],
  };
}

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
