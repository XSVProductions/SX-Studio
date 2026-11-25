import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/lab/lab_board.dart';

import 'lab_fixture.dart';

void main() {
  final board = LabBoard.fromJson(decode(boardJson));

  List<String> ids(PlayerLayout lay, {bool arranging = false}) => [for (final p in placedPages(board, lay, arranging: arranging)) p.page.id];

  test('pages the layout does not place follow, show pages by number, then player pages', () {
    const lay = PlayerLayout(
      pages: ['x2', '3'],
      custom: [
        PlayerPage(id: 'x1', name: 'A'),
        PlayerPage(id: 'x2', name: 'B'),
      ],
    );
    expect(ids(lay), ['x2', '3', '1', '2', 'x1']);
  });

  test('hidden pages only show while arranging; a show page without buttons never does', () {
    const lay = PlayerLayout(hidden: ['2']);
    expect(ids(lay), ['1', '3']);
    expect(ids(lay, arranging: true), ['1', '2', '3']);
  });

  test("buttons the order doesn't know go last, in the show's order", () {
    const lay = PlayerLayout(
      order: {
        '1': ['page1_button3', 'page1_button1'],
      },
    );
    final p = placedPages(board, lay, arranging: false).first;
    expect([for (final t in p.tiles) t.sec], ['page1_button3', 'page1_button1', 'page1_button2']);
  });

  test('fader speed text matches the old page', () {
    expect(faderText(.5), '×1.00 (normal)');
    expect(faderText(1), '×4.0');
    expect(faderText(0), '×0.25');
    expect(faderText(64 / 127), '×1.01 (normal)');
    expect(faderText(.75), '×2.0');
  });

  test('new ids count on from the highest', () {
    const lay = PlayerLayout(
      custom: [
        PlayerPage(
          id: 'x3',
          name: 'A',
          buttons: [
            PlayerButton(id: 'x3_b2', title: '', file: 'a.scex'),
            PlayerButton(id: 'x3_b7', title: '', file: 'b.scex'),
          ],
        ),
        PlayerPage(id: 'x1', name: 'B'),
      ],
    );
    expect(nextPageId(lay), 'x4');
    expect(nextPageId(const PlayerLayout()), 'x1');
    expect(nextButtonId(lay.custom.first), 'x3_b8');
    expect(nextButtonId(lay.custom.last), 'x1_b1');
  });

  test('a page holds 64 buttons', () {
    final lay = PlayerLayout(
      custom: [
        PlayerPage(
          id: 'x1',
          name: 'A',
          buttons: [for (var i = 1; i <= 63; i++) PlayerButton(id: 'x1_b$i', title: '', file: 'a.scex')],
        ),
      ],
    );
    final items = addItems(board);
    final (out, full) = addToPage(lay, 'x1', items.take(3).toList());
    expect(out.custom.single.buttons, hasLength(64));
    expect(full, isTrue);
  });

  test('the add list offers show buttons with files, then files no button plays', () {
    expect([for (final x in addItems(board)) x.title], ['RED', 'RAINBOW CHASE', 'CIRCLE', 'FIGURE 8', 'RIG ID', 'SPARE BLUE']);
    expect(addItems(board).last.sub, 'not on a button · scene');
    expect(addItems(board)[1].sub, 'COLORS · 8 steps · BPM flash');
  });

  test('names are cleaned like the old page', () {
    expect(cleanName('  a<b>|c\u0001  '), 'abc');
    expect(cleanName('x' * 50), 'x' * 40);
  });
}
