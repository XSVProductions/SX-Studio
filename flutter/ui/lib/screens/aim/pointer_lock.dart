import 'package:flutter/gestures.dart';

import 'pointer_lock_web.dart' if (dart.library.ffi) 'pointer_lock_ffi.dart' as impl;

/// A mouse move while the pointer is locked: how far, and Shift and Ctrl.
typedef LockedMove = void Function(double dx, double dy, {required bool shift, required bool ctrl});

/// Keeps the mouse in place while the user drags in Live aim's pad, so the
/// drag never stops at the edge of the screen. The old page's
/// `pad.requestPointerLock()` (`lvOpen`).
///
/// In a browser it is the Pointer Lock API: moves come in through [LockedMove].
/// On Windows the cursor is hidden and put back where the drag started after
/// each move. Elsewhere moves are the plain pointer deltas.
abstract class PointerLock {
  /// The lock for this platform. [onMove] gets moves the pad's own pointer
  /// events don't see; [onLost] runs when the browser let go of the lock (Esc).
  factory PointerLock({required LockedMove onMove, required void Function() onLost}) => impl.createPointerLock(onMove, onLost);

  /// A mouse button went down in the pad at [e].
  void start(PointerDownEvent e);

  /// How far the pad should move for [e].
  Offset delta(PointerMoveEvent e);

  /// The drag ended.
  void stop();
}

/// No lock: moves are the pointer's own deltas.
class NoPointerLock implements PointerLock {
  /// A lock that does nothing.
  const NoPointerLock();

  @override
  void start(PointerDownEvent e) {}

  @override
  Offset delta(PointerMoveEvent e) => e.delta;

  @override
  void stop() {}
}
