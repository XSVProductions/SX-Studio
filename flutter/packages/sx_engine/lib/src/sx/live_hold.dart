/// Keeps the save queue from reopening ShowXpress while live aim or the SX
/// Player is about to take the DMX interface. Port of `$script:liveHold` in
/// `df_aim_gui.ps1`: set by `/api/sx/close` with `live: true` and by the start
/// of live aim, cleared when live aim stops or applies. It wears off by itself
/// after 180 seconds, as before.
///
/// Find it with `e.find<LiveHold>()`. The queue counts it as busy.
class LiveHold {
  LiveHold({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _at;

  /// How long a hold lasts when nobody clears it.
  static const length = Duration(seconds: 180);

  /// Starts (or restarts) the hold. `$script:liveHold = Get-Date`.
  void start() => _at = _now();

  /// Ends it. `$script:liveHold = [datetime]::MinValue`.
  void clear() => _at = null;

  /// The queue must not reopen ShowXpress now.
  bool get on {
    final at = _at;
    return at != null && _now().difference(at) < length;
  }
}
