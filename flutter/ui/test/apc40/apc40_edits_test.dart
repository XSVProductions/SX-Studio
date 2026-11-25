import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/apc40/apc40_edits.dart';

Apc40Button _b(String title, String page, {int on = 5, int off = 6, bool dup = false}) =>
    Apc40Button(title: title, page: 1, pageName: page, color: '#FF0000', on: on, off: off, dup: dup);

/// RED and BLUE on page 1 (RED top left with its own colours), GREEN on page 2's top left.
Apc40Edits _edits({Apc40Layout? layout}) => Apc40Edits(
  Apc40Info(
    show: 'Test',
    file: 'apc40.json',
    layout:
        layout ??
        Apc40Layout(
          pages: [
            Apc40Page(name: 'Dancefloor', pads: {32: 'RED', 33: 'BLUE'}, colors: {32: const Apc40Colors(on: 21, off: 22)}),
            Apc40Page(name: 'Dinner', pads: {32: 'GREEN'}),
          ],
          faders: {1: 0},
        ),
    buttons: [_b('RED', 'COLORS'), _b('BLUE', 'COLORS', on: 45, off: 46), _b('GREEN', 'COLORS'), _b('RED', 'MOVES', dup: true), _b('SPIN', 'MOVES')],
    faders: const [Apc40Fader(k: 0, caption: 'MOVEMENTS', type: 'speed')],
    windows: true,
    status: null,
  ),
);

void main() {
  test('pads are numbered from the bottom left, and the next pad is in reading order', () {
    expect(a4Place(32), 'row 1, column 1');
    expect(a4Place(7), 'row 5, column 8');
    expect(a4Next(32), 33);
    expect(a4Next(39), 24);
    expect(a4Next(7), -1);
  });

  test('a button put on a pad moves on to the next pad, and drops the colours of the old button', () {
    final e = _edits()..tap(32);
    e.assign('RED');
    expect(e.pg.colors[32]?.on, 21, reason: 'the same button keeps its colours');
    expect(e.selected, 33);
    e.selected = 32;
    e.assign('SPIN');
    expect(e.pg.pads[32], 'SPIN');
    expect(e.pg.colors.containsKey(32), isFalse);
    expect(e.dirty, isTrue);
  });

  test('a pad dropped on another pad swaps the two, colours and all', () {
    final e = _edits()..selected = 32;
    e.drop(32, 33);
    expect(e.pg.pads, {32: 'BLUE', 33: 'RED'});
    expect(e.pg.colors.keys, [33]);
    expect(e.selected, 33, reason: 'the pick follows the pad');
    e.drop(33, 10);
    expect(e.pg.pads, {32: 'BLUE', 10: 'RED'});
    expect(e.pg.colors.keys, [10]);
  });

  test('a pad dropped on another page tab goes to the same spot there, and what was there comes back', () {
    final e = _edits()..selected = 32;
    final m = e.dropOnPage(32, 1);
    expect(m, 'RED moved to Dinner (same spot). GREEN came back here in its place.');
    expect(e.pg.pads[32], 'GREEN');
    expect(e.layout.pages[1].pads[32], 'RED');
    expect(e.layout.pages[1].colors[32]?.off, 22);
    expect(e.selected, -1);
    expect(e.dropOnPage(33, 1), 'BLUE moved to Dinner (same spot).');
  });

  test("own colours start from the button's colours, and go again with Use the ShowXpress button colour", () {
    final e = _edits()..setColour(33, true, 9);
    expect((e.pg.colors[33]!.on, e.pg.colors[33]!.off), (9, 46));
    expect(e.colourOpen, isTrue);
    e.useButtonColour(33);
    expect(e.colour(33, true), 45);
    expect(e.dirty, isFalse);
  });

  test('clearing from the menu lets go of the pad, clearing from the panel does not', () {
    final e = _edits()..selected = 33;
    e.clear(33);
    expect(e.selected, 33);
    e.selected = 32;
    e.clear(32, deselect: true);
    expect(e.selected, -1);
    expect(e.pg.pads, isEmpty);
    expect(e.pg.colors, isEmpty);
  });

  test('pages: add up to 8, an empty name becomes Page N, move and delete', () {
    final e = _edits();
    for (var i = 0; i < 10; i++) {
      e.addPage();
    }
    expect(e.layout.pages.length, 8);
    expect(e.layout.pages[2].name, 'Page 3');
    expect(e.page, 7);
    e.rename('  ');
    e.renameDone();
    expect(e.pg.name, 'Page 8');
    e.showPage(1);
    e.movePage(0);
    expect(e.layout.pages.map((p) => p.name).take(2), ['Dinner', 'Dancefloor']);
    expect(e.page, 0);
    e.deletePage();
    expect(e.layout.pages.first.name, 'Dancefloor');
    expect(e.page, 0);
  });

  test('fill puts the missing buttons of a ShowXpress page on the empty pads, in reading order', () {
    final e = _edits();
    expect(e.fill('COLORS'), '1 button(s) from COLORS put on the pads.');
    expect(e.pg.pads[34], 'GREEN');
    expect(e.fill('MOVES'), '1 button(s) from MOVES put on the pads.', reason: 'the duplicate RED is left out');
    final full = _edits(
      layout: Apc40Layout(
        pages: [
          Apc40Page(name: 'A', pads: {for (var n = 0; n < 40; n++) n: 'X$n'}),
        ],
      ),
    );
    expect(full.fill('COLORS'), "0 button(s) from COLORS put on the pads. 3 didn't fit.");
  });

  test('the layout as loaded is not a change, even with colours for an empty pad, and undo goes back', () {
    final e = _edits(
      layout: Apc40Layout(
        pages: [
          Apc40Page(name: 'A', pads: {1: 'RED'}, colors: {2: const Apc40Colors(on: 1, off: 1)}),
        ],
      ),
    );
    expect(e.dirty, isFalse);
    expect(e.layout.pages.single.colors, isEmpty);
    e.setFader(9, 0);
    expect(e.dirty, isTrue);
    e.setFader(9, null);
    expect(e.dirty, isFalse);
    e.addPage();
    e.undo();
    expect(e.layout.pages.length, 1);
    expect(e.page, 0);
    expect(_edits(layout: Apc40Layout()).layout.pages.single.name, 'Dancefloor');
  });

  test('the button list leaves out duplicates and searches titles and page names', () {
    final e = _edits();
    expect(e.listed('').map((g) => (g.$1, g.$2.length)), [('COLORS', 3), ('MOVES', 1)]);
    expect(e.listed('moves').single.$2.single.title, 'SPIN');
    expect(e.listed('nothing'), isEmpty);
  });

  test('the status line', () {
    Apc40Status s(String apc, String sx, {String error = '', String last = ''}) =>
        Apc40Status(running: true, pid: 1, apc: apc, sx: sx, page: 2, pageName: 'Dinner', pages: 2, last: last, error: error, at: '');
    expect(apc40StatusLine(false, null).text, startsWith('The APC40 works with SX Studio on Windows.'));
    expect(apc40StatusLine(true, null).text, 'Starting the APC40 part of SX Studio…');
    final ok = apc40StatusLine(true, s('ok', 'ok', last: 'RED'));
    expect((ok.dot, ok.bold, ok.text, ok.last), (Apc40Dot.green, 'APC40 connected', ' · on page 2 (Dinner) · ShowXpress connected', 'RED'));
    expect(apc40StatusLine(true, s('ok', 'refused', error: 'ShowXpress refused.')).text, endsWith(' · ShowXpress refused.'));
    expect(apc40StatusLine(true, s('busy', 'waiting')).dot, Apc40Dot.red);
    expect(apc40StatusLine(true, s('missing', 'waiting')).text, startsWith('APC40 not plugged in.'));
  });
}
