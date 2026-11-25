/// What can be asked of the running player. These were lines on the old
/// player's stdin (see the top of `player.ps1`). Now they are messages to
/// the player's isolate, so they are plain values.
sealed class PlayerCommand {
  const PlayerCommand();
}

/// `on <slot> <file path>`: start (or restart) a scene or movement.
class PlayOn extends PlayerCommand {
  const PlayOn(this.slot, this.path);
  final String slot, path;
}

/// `off <slot>`.
class PlayOff extends PlayerCommand {
  const PlayOff(this.slot);
  final String slot;
}

/// `alloff`.
class AllOffCommand extends PlayerCommand {
  const AllOffCommand();
}

/// `bo 1` / `bo 0`.
class BlackoutCommand extends PlayerCommand {
  const BlackoutCommand(this.on);
  final bool on;
}

/// `press <sec>`: toggle a live button (swap pages release the rest of the page).
class PressCommand extends PlayerCommand {
  const PressCommand(this.sec);
  final String sec;
}

/// `key <c>`: a keyboard trigger.
class KeyCommand extends PlayerCommand {
  const KeyCommand(this.key);
  final String key;
}

/// `fader <k> <0..1>`: set speed fader k.
class FaderCommand extends PlayerCommand {
  const FaderCommand(this.k, this.v);
  final int k;
  final double v;
}

/// `mi <status> <d1> <d2>`: a MIDI message as if it came from the APC.
class MidiCommand extends PlayerCommand {
  const MidiCommand(this.msg);

  /// status | d1 << 8 | d2 << 16.
  final int msg;
}

/// `bpm <40..250>`.
class BpmCommand extends PlayerCommand {
  const BpmCommand(this.bpm);
  final double bpm;
}

/// `tap`.
class TapCommand extends PlayerCommand {
  const TapCommand();
}

/// `sync`: now is beat 1.
class SyncCommand extends PlayerCommand {
  const SyncCommand();
}

/// `seton <sec>`: on, not toggle.
class SetOnCommand extends PlayerCommand {
  const SetOnCommand(this.sec);
  final String sec;
}

/// `setoff <sec>`.
class SetOffCommand extends PlayerCommand {
  const SetOffCommand(this.sec);
  final String sec;
}

/// `ton <title>`: on by title, like ShowXpress.
class TitleOnCommand extends PlayerCommand {
  const TitleOnCommand(this.title);
  final String title;
}

/// `toff <title>`.
class TitleOffCommand extends PlayerCommand {
  const TitleOffCommand(this.title);
  final String title;
}

/// A button on one of the SX Player's own pages (not in live.ini). No pad, no key.
class ExtraButton {
  const ExtraButton({
    required this.sec,
    required this.group,
    required this.swap,
    required this.fader,
    required this.bpm,
    required this.flash,
    required this.beats,
    required this.path,
    required this.title,
  });

  /// `x<page>_b<n>`.
  final String sec;

  /// The page it swaps with: 1000 + the player page's number, so it never meets a ShowXpress page.
  final int group;
  final bool swap;
  final int fader;
  final bool bpm, flash;
  final double beats;

  /// The file it plays, or '' when it is missing.
  final String path;
  final String title;

  @override
  bool operator ==(Object other) =>
      other is ExtraButton &&
      other.sec == sec &&
      other.group == group &&
      other.swap == swap &&
      other.fader == fader &&
      other.bpm == bpm &&
      other.flash == flash &&
      other.beats == beats &&
      other.path == path &&
      other.title == title;

  @override
  int get hashCode => Object.hash(sec, group, swap, fader, bpm, flash, beats, path, title);
}

/// `addb ...`: add (or replace) a button on one of the player's own pages.
class AddButtonCommand extends PlayerCommand {
  const AddButtonCommand(this.b);
  final ExtraButton b;
}

/// `delb <sec>`: take such a button away again (it stops if it was playing).
class RemoveButtonCommand extends PlayerCommand {
  const RemoveButtonCommand(this.sec);
  final String sec;
}
