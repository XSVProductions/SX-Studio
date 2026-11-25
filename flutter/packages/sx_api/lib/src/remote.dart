import 'client.dart';
import 'json.dart';

/// Whether ShowXpress's remote control is switched on in the show and its
/// settings. Port of `Get-SetupJson` in `sx_remote.ps1`.
class RemoteSetup {
  const RemoteSetup({required this.appOn, required this.allowed, required this.password, required this.pagesOff});

  factory RemoteSetup.fromJson(Json j) =>
      RemoteSetup(appOn: j.boolean('appOn'), allowed: j.boolean('allowed'), password: j.boolean('password'), pagesOff: j.strList('pagesOff'));

  /// param.ini `[Network] LIVEMOBILEENABLE = yes` (External App).
  final bool appOn;

  /// live.ini `[live] allow_live_mobile = yes`.
  final bool allowed;

  /// live.ini has a `live_mobile_password`.
  final bool password;

  /// Names of live pages the remote can't reach (no `live_mobile = yes`).
  final List<String> pagesOff;

  Json toJson() => {'appOn': appOn, 'allowed': allowed, 'password': password, 'pagesOff': pagesOff};
}

/// A button that is playing in ShowXpress.
class PressedOnAir {
  const PressedOnAir({required this.title, required this.page});

  factory PressedOnAir.fromJson(Json j) => PressedOnAir(title: j.str('title'), page: j.str('page'));

  final String title;
  final String page;

  Json toJson() => {'title': title, 'page': page};
}

/// What ShowXpress's remote said, and what a press did.
///
/// Port of the JSON `sx_remote.ps1` prints for State, Press, Release and Off.
/// When the engine could not run the remote at all, [ok] is false and only
/// [error] is set ([setup] is null).
class RemoteState {
  const RemoteState({
    this.ok = true,
    this.ready = false,
    this.open = false,
    this.connected = false,
    this.pressed = const [],
    this.titles = const [],
    this.error = '',
    this.setup,
    this.pressedNow = const [],
    this.released = const [],
    this.missing = const [],
    this.skipped = false,
    this.playing = const [],
  });

  const RemoteState.failed(this.error)
    : ok = false,
      ready = false,
      open = false,
      connected = false,
      pressed = const [],
      titles = const [],
      setup = null,
      pressedNow = const [],
      released = const [],
      missing = const [],
      skipped = false,
      playing = const [];

  factory RemoteState.fromJson(Json j) => RemoteState(
    ok: j['ok'] != false,
    ready: j.boolean('ready'),
    open: j.boolean('open'),
    connected: j.boolean('connected'),
    pressed: j.list('pressed', PressedOnAir.fromJson),
    titles: j.strList('titles'),
    error: j.str('error'),
    setup: switch (j.objOrNull('setup')) {
      final s? => RemoteSetup.fromJson(s),
      null => null,
    },
    pressedNow: j.strList('pressedNow'),
    released: j.strList('released'),
    missing: j.strList('missing'),
    skipped: j.boolean('skipped'),
    playing: j.strList('playing'),
  );

  final bool ok;

  /// The remote is switched on in the show (see [RemoteSetup]).
  final bool ready;

  /// ShowXpress is open.
  final bool open;

  /// SX Studio got through to ShowXpress and read its buttons.
  final bool connected;

  /// Buttons playing after the action.
  final List<PressedOnAir> pressed;

  /// Every button title ShowXpress has, once each.
  final List<String> titles;
  final String error;
  final RemoteSetup? setup;

  /// Titles this action turned on.
  final List<String> pressedNow;

  /// Titles this action turned off.
  final List<String> released;

  /// Asked-for titles ShowXpress doesn't have.
  final List<String> missing;

  /// An idle press found the show playing and pressed nothing.
  final bool skipped;

  /// What was playing outside the SETUP page when [skipped].
  final List<String> playing;

  Json toJson() => {
    'ok': ok,
    'ready': ready,
    'open': open,
    'connected': connected,
    'pressed': [for (final p in pressed) p.toJson()],
    'titles': titles,
    'error': error,
    'setup': setup?.toJson(),
    'pressedNow': pressedNow,
    'released': released,
    'missing': missing,
    'skipped': skipped,
    'playing': playing,
  };
}

/// The last automatic press (pending presses), for the status poll.
/// Port of `$script:remLast` in `df_aim_gui.ps1`.
class RemoteLast {
  const RemoteLast({required this.at, required this.label, required this.ok, required this.skipped, required this.playing, required this.error});

  factory RemoteLast.fromJson(Json j) => RemoteLast(
    at: j.str('at'),
    label: j.str('label'),
    ok: j.boolean('ok'),
    skipped: j.boolean('skipped'),
    playing: j.strList('playing'),
    error: j.str('error'),
  );

  /// When it happened (ISO 8601). A new value means a new press.
  final String at;
  final String label;

  /// The buttons were turned on.
  final bool ok;

  /// The show was playing, so nothing was pressed.
  final bool skipped;
  final List<String> playing;
  final String error;

  Json toJson() => {'at': at, 'label': label, 'ok': ok, 'skipped': skipped, 'playing': playing, 'error': error};
}

extension RemoteApi on SxClient {
  /// What ShowXpress is playing. Never throws: a failure comes back as [RemoteState.failed].
  Future<RemoteState> remote() => _remote(() => get('/api/remote', RemoteState.fromJson));

  /// Presses [titles]. [solo] turns off everything else first, [idle] presses
  /// nothing when the show is playing, [release] turns those titles off too.
  Future<RemoteState> remotePress(List<String> titles, {bool solo = false, bool idle = false, List<String> release = const []}) =>
      _remote(() => post('/api/remote/press', {'titles': titles, 'release': release, 'solo': solo, 'idle': idle}, RemoteState.fromJson));

  /// Turns off every button that is playing.
  Future<RemoteState> remoteOff() => _remote(() => post('/api/remote/off', const {}, RemoteState.fromJson));

  /// Switches the remote on in the show. A save: queued while ShowXpress is open.
  Future<ToolResult> remoteEnable() => run('/api/remote/enable');

  Future<RemoteState> _remote(Future<RemoteState> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      return RemoteState.failed(e.message);
    }
  }
}
