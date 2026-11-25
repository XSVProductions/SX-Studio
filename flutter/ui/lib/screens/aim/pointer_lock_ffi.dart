import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import 'pointer_lock.dart';

/// On Windows the cursor is held in place; elsewhere no lock.
PointerLock createPointerLock(LockedMove onMove, void Function() onLost) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? WarpLock(_Win32.cursor, _Win32.setCursor) : const NoPointerLock();

/// Holds the cursor where the drag started: each move is measured from there,
/// then the cursor goes back. The pad hides the cursor while dragging. The
/// move Windows reports for the jump back lands on the start, so it counts
/// as nothing. Stands in for the browser's pointer lock on the laptop.
class WarpLock implements PointerLock {
  /// A lock that reads the cursor with [getCursor] and puts it back with
  /// [setCursor], both in screen pixels.
  WarpLock(this.getCursor, this.setCursor);

  final ({int x, int y})? Function() getCursor;
  final void Function(int x, int y) setCursor;

  Offset? _at;
  ({int x, int y})? _screen;

  @override
  void start(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    _screen = getCursor();
    _at = _screen == null ? null : e.position;
  }

  @override
  Offset delta(PointerMoveEvent e) {
    final at = _at, s = _screen;
    if (at == null || s == null) return e.delta;
    final d = e.position - at;
    if (d != Offset.zero) setCursor(s.x, s.y);
    return d;
  }

  @override
  void stop() {
    _at = null;
    _screen = null;
  }
}

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

/// `GetCursorPos` and `SetCursorPos` from user32.
abstract final class _Win32 {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _get = _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
  static final _set = _user32.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('SetCursorPos');

  /// One POINT, kept for the life of the app.
  static final Pointer<_Point> _pt = () {
    final heap = _kernel32.lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
    final alloc = _kernel32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr), Pointer<Void> Function(int, int, int)>('HeapAlloc');
    return alloc(heap, 8, sizeOf<_Point>()).cast<_Point>();
  }();

  static ({int x, int y})? cursor() {
    try {
      if (_pt == nullptr || _get(_pt) == 0) return null;
      return (x: _pt.ref.x, y: _pt.ref.y);
    } on Object {
      return null;
    }
  }

  static void setCursor(int x, int y) {
    try {
      _set(x, y);
    } on Object {
      // the cursor just moves on
    }
  }
}
