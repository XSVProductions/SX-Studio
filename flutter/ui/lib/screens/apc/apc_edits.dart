import 'package:sx_api/sx_api.dart';

/// "row 3, column 5" for pad note [n] (row 1 is the top row).
String padPlace(int n) => 'row ${8 - n ~/ 8}, column ${n % 8 + 1}';

/// The unsaved edits on the APC mini tab: where each button sits and its pad
/// colours, and the pad picked for a move. Port of the old page's APC script.
class ApcEdits {
  ApcEdits(this.data) : note = {for (final p in data.pads) p.sec: p.note};

  final ApcPreview data;

  /// The note each button is on now, saved or not. -1 = taken off the pads.
  final Map<String, int> note;

  /// Changed pad colours, (playing, idle), by button.
  final colours = <String, (int, int)>{};

  /// The button picked for a move, or null.
  String? selected;

  /// What the side panel says after a tap that did nothing.
  var message = '';

  ApcPad pad(String sec) => data.pads.firstWhere((p) => p.sec == sec);

  int on(ApcPad p) => colours[p.sec]?.$1 ?? p.on;
  int off(ApcPad p) => colours[p.sec]?.$2 ?? p.off;
  bool colourChanged(ApcPad p) => colours.containsKey(p.sec) && (colours[p.sec]!.$1 != p.on || colours[p.sec]!.$2 != p.off);
  bool moved(ApcPad p) => note[p.sec] != p.note;
  bool changed(ApcPad p) => moved(p) || colourChanged(p);

  /// On one of the 64 pads, as edited.
  bool onGrid(ApcPad p) => p.type == 0 && note[p.sec]! >= 0 && note[p.sec]! <= 63;

  List<ApcPad> at(int n) => [...data.pads.where((p) => onGrid(p) && note[p.sec] == n)];

  bool get dirty => data.pads.any(changed);

  /// A tap on pad [n]: pick what is on it, or move the picked button there.
  /// A tap on a used pad swaps the two.
  void tap(int n) {
    final here = at(n);
    final sel = selected;
    if (sel == null) {
      if (here.isNotEmpty) {
        selected = here.first.sec;
        message = '';
      }
      return;
    }
    final sp = pad(sel), from = note[sel]!;
    if (onGrid(sp) && from == n) {
      // Tapping its own pad again picks the next button on it, or lets go.
      if (here.length > 1) {
        selected = here[(here.indexWhere((p) => p.sec == sel) + 1) % here.length].sec;
      } else {
        selected = null;
        message = '';
      }
      return;
    }
    if (here.length > 1) {
      message = 'That pad already has ${here.length} buttons on it. Move those apart first.';
      return;
    }
    if (here.length == 1) {
      if (!onGrid(sp)) {
        message = 'That pad is taken. Pick an empty pad.';
        return;
      }
      note[here.first.sec] = from;
    }
    note[sel] = n;
    selected = null;
    message = '';
  }

  /// The button a drag from pad [n] carries: the picked one when it is on
  /// that pad, else the first. Null for a free pad, which can't be dragged.
  String? dragFrom(int n) {
    final here = at(n);
    if (here.isEmpty) return null;
    return here.any((p) => p.sec == selected) ? selected : here.first.sec;
  }

  /// Button [sec] dropped on pad [n]: the same as picking it and tapping
  /// [n], so a used pad swaps. Dropped on its own pad, nothing happens.
  void drop(String sec, int n) {
    if (note[sec] == n) return;
    selected = sec;
    tap(n);
  }

  /// Takes [sec] off the pads from the pad menu. Lets go of it if it was picked.
  void takeOffFromMenu(String sec) {
    note[sec] = -1;
    if (selected == sec) selected = null;
    message = '';
  }

  /// Lets go of the picked button, as Done, a click elsewhere or Esc.
  void deselect() {
    selected = null;
    message = '';
  }

  /// Sets the playing ([playing] true) or idle colour of [p].
  void setColour(ApcPad p, bool playing, int v) {
    final c = colours[p.sec] ?? (p.on, p.off);
    colours[p.sec] = playing ? (v, c.$2) : (c.$1, v);
  }

  void takeOff(String sec) {
    note[sec] = -1;
    selected = null;
    message = '';
  }

  void putBack(String sec) => note[sec] = pad(sec).note;

  void undo() {
    for (final p in data.pads) {
      note[p.sec] = p.note;
    }
    colours.clear();
    selected = null;
    message = '';
  }

  /// What Save sends.
  List<ApcChange> get changes => [
    for (final p in data.pads.where(changed))
      ApcChange(
        sec: p.sec,
        title: p.title,
        note: note[p.sec]!,
        on: colourChanged(p) && note[p.sec]! >= 0 ? colours[p.sec]!.$1 : null,
        off: colourChanged(p) && note[p.sec]! >= 0 ? colours[p.sec]!.$2 : null,
      ),
  ];

  /// The pad problems list: (level, title, detail, section the buttons act on, what they offer).
  List<({String level, String title, String detail, String? sec, ApcIssueAction action})> get issues => [
    for (var n = 0; n < 64; n++)
      if (at(n).length > 1)
        (
          level: 'error',
          title: '${padPlace(n)} plays ${at(n).length} buttons',
          detail:
              '${at(n).map((p) => '${p.title} (${p.pageName})').join(', ')}. One press fires all of them. Tap the pad (again to pick the next one) and move one away.',
          sec: null,
          action: ApcIssueAction.none,
        ),
    for (final p in data.pads.where((p) => !p.sceneOk && note[p.sec]! >= 0))
      (
        level: 'error',
        title: '${p.title}: scene file missing',
        detail: "Plays ${p.scene}, which isn't in the show any more.",
        sec: null,
        action: ApcIssueAction.none,
      ),
    for (final p in data.pads.where((p) => !onGrid(p) && note[p.sec] != -1))
      (
        level: 'warn',
        title: '${p.title} (${p.pageName}) is mapped outside the pads',
        detail: '${p.type == 0 ? 'Note ' : 'MIDI type ${p.type}, number '}${note[p.sec]}, a round button or track button.',
        sec: p.sec,
        action: p.type == 0 ? ApcIssueAction.moveOrTakeOff : ApcIssueAction.takeOff,
      ),
    for (final p in data.pads.where((p) => note[p.sec] == -1))
      (level: 'info', title: '${p.title} (${p.pageName}) will be taken off the pads', detail: 'Not saved yet.', sec: p.sec, action: ApcIssueAction.putBack),
  ];
}

/// The buttons next to a pad problem.
enum ApcIssueAction { none, moveOrTakeOff, takeOff, putBack }
