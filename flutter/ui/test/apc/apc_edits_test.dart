import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/apc/apc_edits.dart';

ApcPad _pad(String sec, String title, int note, {int type = 0}) => ApcPad(
  sec: sec,
  page: 1,
  pageName: 'COLORS',
  title: title,
  scene: '$title.scex',
  sceneOk: true,
  note: note,
  type: type,
  channel: 1,
  device: 0,
  outNote: note,
  on: 5,
  off: 6,
  color: -1,
  key: '',
);

/// RED on pad 0, BLUE on pad 1, GREEN and AMBER both on pad 2, WHITE on note 70 (a round button).
ApcEdits _edits() => ApcEdits(
  ApcPreview(
    show: 'C:/Shows/Test',
    pads: [_pad('p1', 'RED', 0), _pad('p2', 'BLUE', 1), _pad('p3', 'GREEN', 2), _pad('p4', 'AMBER', 2), _pad('p5', 'WHITE', 70)],
    faders: const [],
    buttons: 5,
  ),
);

Json _change(ApcChange c) => c.toJson();

void main() {
  test('tap a pad, then a free pad, moves it there', () {
    final e = _edits()..tap(0);
    expect(e.selected, 'p1');
    e.tap(12);
    expect(e.selected, isNull);
    expect(e.changes.map(_change), [
      {'sec': 'p1', 'title': 'RED', 'note': 12},
    ]);
  });

  test('moving onto a used pad swaps the two', () {
    final e = _edits()
      ..tap(0)
      ..tap(1);
    expect(e.note['p1'], 1);
    expect(e.note['p2'], 0);
  });

  test('a pad with two buttons takes nothing more, and tapping it again picks the next button', () {
    final e = _edits()
      ..tap(0)
      ..tap(2);
    expect(e.message, 'That pad already has 2 buttons on it. Move those apart first.');
    expect(e.dirty, isFalse);

    e
      ..selected = null
      ..tap(2);
    expect(e.selected, 'p3');
    e.tap(2);
    expect(e.selected, 'p4');
    expect(e.issues.map((i) => i.title), ['row 8, column 3 plays 2 buttons', 'WHITE (COLORS) is mapped outside the pads']);
  });

  test('a button outside the pads can go to a free pad but not a taken one', () {
    final e = _edits()..selected = 'p5';
    e.tap(0);
    expect(e.message, 'That pad is taken. Pick an empty pad.');
    e.tap(40);
    expect(e.note['p5'], 40);
  });

  test('colours are sent with the pad, and not for a button taken off the pads', () {
    final e = _edits();
    e.setColour(e.pad('p2'), true, 21);
    expect(e.changes.map(_change), [
      {'sec': 'p2', 'title': 'BLUE', 'note': 1, 'on': 21, 'off': 6},
    ]);
    e.takeOff('p2');
    expect(e.changes.map(_change), [
      {'sec': 'p2', 'title': 'BLUE', 'note': -1},
    ]);
    e.undo();
    expect(e.dirty, isFalse);
  });

  test('a drag carries the picked button on a pad, and drops like tap then tap', () {
    final e = _edits();
    expect(e.dragFrom(5), isNull, reason: 'a free pad');
    expect(e.dragFrom(2), 'p3');
    e.selected = 'p4';
    expect(e.dragFrom(2), 'p4');
    e.drop('p4', 2);
    expect(e.selected, 'p4', reason: 'dropped on its own pad, nothing happens');
    e.drop('p1', 1);
    expect((e.note['p1'], e.note['p2'], e.selected), (1, 0, null));
    e.drop('p1', 2);
    expect(e.message, 'That pad already has 2 buttons on it. Move those apart first.');
  });

  test('taking a button off from the pad menu lets go of it only when it was picked', () {
    final e = _edits()..selected = 'p1';
    e.takeOffFromMenu('p2');
    expect(e.selected, 'p1');
    e.takeOffFromMenu('p1');
    expect(e.selected, isNull);
    expect(e.at(0), isEmpty);
  });
}
