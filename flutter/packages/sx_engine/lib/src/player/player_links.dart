// How the SX Player and the areas around it reach each other inside the
// engine. The player shares [PlayerControl] with `e.provide`. The other three
// are for other areas to provide. The player looks each up with `e.find`
// when it needs it, so the order areas register in doesn't matter, and a
// missing one simply means "not there" (no Auto Show running, nothing
// pressed in ShowXpress, no pages of the player's own).

/// The running SX Player, for the Auto Show. Replaces the old named pipe
/// (`-Pipe`, which took ton / toff / seton / setoff / bpm / sync / tap) and the
/// status file the Auto Show read (`-PlayerStatus`).
///
/// Find it with `e.find<PlayerControl>()`.
abstract interface class PlayerControl {
  /// True while the player plays. The Auto Show plays its looks on the player
  /// when this is true at its start, as `Start-Auto` did with `Test-Player`.
  bool get running;

  /// What the player is doing now, or null when it isn't running.
  PlayerStatus? get status;

  /// Turns the show's first button called [title] on (not a toggle), like
  /// ShowXpress's BUTTON_PRESS. False when the player isn't running. An
  /// unknown title shows up in the status's `err`, as before.
  bool titleOn(String title);

  /// Turns it off. False when the player isn't running.
  bool titleOff(String title);

  /// Sets the tempo, 40 to 250 (others are ignored, as before).
  bool setBpm(double bpm);

  /// Now is beat 1.
  bool sync();

  /// A tap on the tempo.
  bool tap();
}

/// One status of the running player, as the old status file had it.
class PlayerStatus {
  const PlayerStatus(this.json);

  /// Key for key the old status file: ok, bo, on, err, fd, midi, led, bpm,
  /// beat, src, os2l, os2lPort, os2lErr, os2lBeats, iface, reconn, warn.
  final Map<String, Object?> json;

  /// The slots (button sections) playing now, oldest press first.
  List<String> get on => [for (final o in (json['on'] as List?) ?? const []) '${(o as Map)['slot']}'];

  double get bpm => (json['bpm'] as num?)?.toDouble() ?? 0;

  /// Where the tempo comes from: manual, tap or VirtualDJ.
  String get src => '${json['src'] ?? ''}';
}

/// The Auto Show, as the player's server side sees it. Provided by the Auto
/// Show area with `e.provide<PlayerAutoShowLink>(...)`.
abstract interface class PlayerAutoShowLink {
  /// The Auto Show is running (`Test-Auto`).
  bool get running;

  /// It plays its looks on the player rather than ShowXpress (`$script:autoPl`).
  bool get onPlayer;

  /// Starts it again on the same look (`Start-Auto` with the status's
  /// lookId). It then plays on the player if that is running, else on
  /// ShowXpress.
  Future<void> restart();
}

/// One button pressed in ShowXpress.
typedef PressedButton = ({String page, String title});

/// ShowXpress's remote control, as the player's server side needs it.
/// Provided by the area that ports `sx_remote.ps1`, with
/// `e.provide<PlayerShowXpressLink>(...)`.
abstract interface class PlayerShowXpressLink {
  /// The buttons pressed in ShowXpress now (`Invoke-Remote 'State'`), or
  /// null when it couldn't connect.
  Future<List<PressedButton>?> pressed();

  /// Presses [titles] once ShowXpress is open (`Set-PendingPress`).
  void setPendingPress(List<String> titles, String label);

  /// Drops the pending press if its label is [label].
  void clearPendingPress(String label);
}

/// One of the SX Player's own pages (settings `playerLayout.custom`),
/// already checked the way `Get-PlayerLayout` does.
class PlayerPageSpec {
  const PlayerPageSpec({required this.id, required this.swap, required this.buttons});

  /// `x<n>`.
  final String id;
  final bool swap;
  final List<PlayerButtonSpec> buttons;
}

/// A button on one of the player's own pages.
class PlayerButtonSpec {
  const PlayerButtonSpec({
    required this.id,
    required this.title,
    required this.file,
    required this.fader,
    required this.bpm,
    required this.flash,
    required this.beats,
  });

  /// `x<n>_b<m>`.
  final String id;
  final String title;

  /// A scene or movement file name of the show.
  final String file;
  final int fader;
  final bool bpm, flash;
  final double beats;
}

/// The player's own pages. Provided by the settings area with
/// `e.provide<PlayerLayoutSource>(...)`. After saving a layout it calls
/// [LabPlayerHooks.syncExtras] so a changed button plays straight away.
abstract interface class PlayerLayoutSource {
  List<PlayerPageSpec> get customPages;
}

/// What the settings area calls on the player after saving a layout. Found
/// with `e.find<LabPlayerHooks>()`.
abstract interface class LabPlayerHooks {
  /// Sends the player the buttons on its own pages that changed
  /// (`Sync-PlayerExtras`). Does nothing when the player isn't running.
  void syncExtras();
}
