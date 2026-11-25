import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/home/home_screen.dart';

void main() {
  test('a phone orders the tiles inside each section as the old phone page did', () {
    expect(homeTileOrder(phone: false).last.take(5), ['rig', 'skip', 'apc', 'apc40', 'speed']);
    expect(homeTileOrder(phone: true), [
      ['rt', 'aim', 'color', 'pre'],
      ['lab', 'auto'],
      ['scene', 'move', 'look', 'rig', 'skip', 'apc', 'apc40', 'speed', 'health', 'settings'],
    ]);
  });
}
