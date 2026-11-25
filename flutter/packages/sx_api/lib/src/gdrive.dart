import 'client.dart';
import 'json.dart';

/// Where the show and its Google Drive copy are, and when they last moved.
/// What `gdrive.ps1 -Action Preview` printed.
class DriveInfo {
  const DriveInfo({
    required this.show,
    required this.here,
    required this.found,
    required this.target,
    this.last = '',
    this.srcFound = false,
    this.srcTime = '',
    this.lastImport = '',
    this.my = '',
    this.override = '',
    this.account = '',
    this.appFound = false,
  });

  factory DriveInfo.fromJson(Json j) => DriveInfo(
    show: j.str('show'),
    here: j.boolean('here'),
    found: j.boolean('found'),
    target: j.str('target'),
    last: j.str('last'),
    srcFound: j.boolean('srcFound'),
    srcTime: j.str('srcTime'),
    lastImport: j.str('lastImport'),
    my: j.str('my'),
    override: j.str('override'),
    account: j.str('account'),
    appFound: j.boolean('appFound'),
  );

  /// The show folder on this computer.
  final String show;

  /// The show folder has a show in it.
  final bool here;

  /// Google Drive was found on this computer.
  final bool found;

  /// The show's folder on Google Drive.
  final String target;

  /// Last sync, `yyyy-MM-ddTHH:mm:ss`, or ''.
  final String last;

  /// Google Drive has a show to import.
  final bool srcFound;

  /// When the Google Drive copy's live.ini was saved.
  final String srcTime;
  final String lastImport;

  /// The My Drive folder in use.
  final String my;

  /// The My Drive folder set by hand in Settings, or ''.
  final String override;

  /// The signed-in Google account, when the folder name shows it (Mac).
  final String account;

  /// Google Drive for desktop is installed.
  final bool appFound;

  Json toJson() => {
    'ok': true,
    'show': show,
    'here': here,
    'found': found,
    'target': target,
    'last': last,
    'srcFound': srcFound,
    'srcTime': srcTime,
    'lastImport': lastImport,
    'my': my,
    'override': override,
    'account': account,
    'appFound': appFound,
  };
}

extension DriveApi on SxClient {
  Future<DriveInfo> gdrive() => get('/api/gdrive', DriveInfo.fromJson);

  /// Copies the show to Google Drive. Waits while ShowXpress is open.
  Future<ToolResult> gdriveSync() => run('/api/gdrive/sync');

  /// Replaces the show with the Google Drive copy. Waits while ShowXpress is open.
  Future<ToolResult> gdriveImport() => run('/api/gdrive/import');
}
