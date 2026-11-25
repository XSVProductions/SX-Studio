import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sx_studio/screens/aim/pointer_lock_ffi.dart';

void main() {
  test('on the laptop the cursor is held where the drag started, so a drag never stops at the screen edge', () {
    final warps = <(int, int)>[];
    final lock = WarpLock(() => (x: 500, y: 300), (x, y) => warps.add((x, y)));
    lock.start(const PointerDownEvent(kind: PointerDeviceKind.mouse, position: Offset(100, 80)));

    // a move counts from the start, then the cursor goes back there
    expect(lock.delta(const PointerMoveEvent(kind: PointerDeviceKind.mouse, position: Offset(112, 75))), const Offset(12, -5));
    expect(warps, [(500, 300)]);

    // the move Windows reports for the jump back is nothing
    expect(lock.delta(const PointerMoveEvent(kind: PointerDeviceKind.mouse, position: Offset(100, 80), delta: Offset(-12, 5))), Offset.zero);
    expect(warps, hasLength(1));

    // the same way again keeps going: no edge
    expect(lock.delta(const PointerMoveEvent(kind: PointerDeviceKind.mouse, position: Offset(112, 80))), const Offset(12, 0));

    lock.stop();
    expect(lock.delta(const PointerMoveEvent(kind: PointerDeviceKind.mouse, position: Offset(130, 80), delta: Offset(18, 0))), const Offset(18, 0));
  });

  test('a finger is never held', () {
    final lock = WarpLock(() => (x: 1, y: 1), (x, y) => fail('no warp for touch'));
    lock.start(const PointerDownEvent(kind: PointerDeviceKind.touch, position: Offset(10, 10)));
    expect(lock.delta(const PointerMoveEvent(kind: PointerDeviceKind.touch, position: Offset(14, 10), delta: Offset(4, 0))), const Offset(4, 0));
  });
}
