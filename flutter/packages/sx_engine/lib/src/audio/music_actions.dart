import 'dart:convert';

import 'package:sx_api/sx_api.dart';

import 'music_detector.dart';

/// Turns what the music detector hears into OS2L messages for ShowXpress (or
/// the SX Player): every beat, and buttons pressed by title for the break,
/// the build (three levels), snare flashes, the gap and the drop.
///
/// OS2L is VirtualDJ's lighting link. ShowXpress listens for it when
/// Preferences > Network > Virtual DJ is enabled, so SX Studio talks to
/// ShowXpress the way VirtualDJ would:
///
///     {"evt":"beat","change":false,"pos":12,"bpm":128.0,"strength":10}
///     {"evt":"btn","name":"AUTO DROP","page":"","state":"on"}
///
/// Pure logic: no clock and no socket. [now] is in seconds on any steady clock.
class MusicActions {
  MusicActions(this.settings);

  MusicSettings settings;

  /// Titles held on now.
  final on = <String>{};

  final _offAt = <String, double>{}; // flashes still to release
  MusicSection _section = MusicSection.groove;
  int _stage = 0; // build level 0..3
  int _pos = 0; // beats sent
  int _dropLeft = 0; // beats until the drop button goes off

  /// How long a snare flash stays on.
  static const flashS = 0.05;

  static String beatMsg(int pos, double bpm) =>
      jsonEncode({'evt': 'beat', 'change': false, 'pos': pos, 'bpm': double.parse(bpm.toStringAsFixed(2)), 'strength': 10});

  static String btnMsg(String title, bool on) => jsonEncode({'evt': 'btn', 'name': title, 'page': '', 'state': on ? 'on' : 'off'});

  List<String> _set(String title, bool want, List<String> out) {
    if (title.isEmpty) return out;
    if (want && on.add(title)) out.add(btnMsg(title, true));
    if (!want && on.remove(title)) {
      _offAt.remove(title);
      out.add(btnMsg(title, false));
    }
    return out;
  }

  String _stageTitle(int s) => switch (s) {
    1 => settings.build1,
    2 => settings.build2,
    3 => settings.build3,
    _ => '',
  };

  void _setStage(int s, List<String> out) {
    if (s == _stage) return;
    _set(_stageTitle(_stage), false, out);
    _stage = s;
    _set(_stageTitle(s), true, out);
  }

  /// The break, the build and the gap are over.
  void _endBreak(List<String> out) {
    _setStage(0, out);
    _set(settings.gap, false, out);
    _set(settings.breakTitle, false, out);
  }

  /// The messages for one event, in the order to send them.
  List<String> event(MusicEvent e, double now) {
    final out = <String>[];
    switch (e.kind) {
      case MusicEventKind.beat:
        if (settings.beats) out.add(beatMsg(_pos, e.value));
        _pos++;
        if (_dropLeft > 0 && --_dropLeft == 0) _set(settings.drop, false, out);
      case MusicEventKind.section:
        final s = e.section ?? MusicSection.groove;
        if (s == MusicSection.breakdown && _section != MusicSection.build) {
          _dropLeft = 0;
          _set(settings.drop, false, out);
          _set(settings.breakTitle, true, out);
        }
        if (s == MusicSection.groove) _endBreak(out);
        _section = s;
      case MusicEventKind.build:
        if (_section == MusicSection.build || _section == MusicSection.breakdown) {
          final lv = e.value;
          _setStage(
            lv >= 0.85
                ? 3
                : lv >= 0.6
                ? 2
                : lv >= 0.35
                ? 1
                : 0,
            out,
          );
        }
      case MusicEventKind.snare:
        final t = settings.snare;
        if (t.isNotEmpty && (_section == MusicSection.build || settings.snareAlways)) {
          // a flash still on goes off first, so the next one shows
          if (on.contains(t)) _set(t, false, out);
          _set(t, true, out);
          _offAt[t] = now + flashS;
        }
      case MusicEventKind.gap:
        _setStage(0, out);
        _set(settings.gap, true, out);
      case MusicEventKind.drop:
        _endBreak(out);
        _set(settings.drop, false, out); // pressed again from the start
        _set(settings.drop, true, out);
        _dropLeft = settings.dropBars * 4;
      case MusicEventKind.back:
        _endBreak(out);
      case MusicEventKind.kick:
        break;
    }
    return out;
  }

  /// Releases the flashes that are due.
  List<String> tick(double now) {
    final out = <String>[];
    for (final t in [
      for (final x in _offAt.entries)
        if (x.value <= now) x.key,
    ]) {
      _set(t, false, out);
    }
    return out;
  }

  /// Everything off, for when listening stops or the settings change.
  List<String> releaseAll() {
    final out = [for (final t in on) btnMsg(t, false)];
    on.clear();
    _offAt.clear();
    _stage = 0;
    _dropLeft = 0;
    return out;
  }
}
