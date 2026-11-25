import 'dart:js_interop';

import 'package:flutter/gestures.dart';

import 'pointer_lock.dart';

extension type _Doc._(JSObject _) implements JSObject {
  external _El? querySelector(String selector);
  external _El? get body;
  external JSObject? get pointerLockElement;
  external void exitPointerLock();
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _El._(JSObject _) implements JSObject {
  external JSAny? requestPointerLock();
}

extension type _Mouse._(JSObject _) implements JSObject {
  external double get movementX;
  external double get movementY;
  external bool get shiftKey;
  external bool get ctrlKey;
}

@JS('document')
external _Doc get _document;

/// The browser's lock.
PointerLock createPointerLock(LockedMove onMove, void Function() onLost) => _WebLock(onMove, onLost);

/// The Pointer Lock API, as the old page used it. While locked the pointer's
/// own position stands still (its deltas are 0), and the document's
/// `mousemove` carries `movementX` and `movementY`.
class _WebLock implements PointerLock {
  _WebLock(this.onMove, this.onLost);

  final LockedMove onMove;
  final void Function() onLost;
  JSFunction? _mouse, _change;

  @override
  void start(PointerDownEvent e) {
    stop();
    final move = (JSObject ev) {
      if (_document.pointerLockElement == null) return;
      final m = ev as _Mouse;
      onMove(m.movementX, m.movementY, shift: m.shiftKey, ctrl: m.ctrlKey);
    }.toJS;
    final change = (JSObject _) {
      if (_document.pointerLockElement == null && _mouse != null) {
        stop();
        onLost();
      }
    }.toJS;
    _mouse = move;
    _change = change;
    _document.addEventListener('mousemove', move);
    _document.addEventListener('pointerlockchange', change);
    try {
      // Flutter listens on its view, so the lock goes there and the button's release still reaches the pad
      final el = _document.querySelector('flutter-view') ?? _document.body;
      final p = el?.requestPointerLock();
      if (p != null && p.isA<JSPromise>()) (p as JSPromise).toDart.ignore();
    } on Object {
      // no lock: the drag still works, it just stops at the screen's edge
    }
  }

  @override
  Offset delta(PointerMoveEvent e) => e.delta;

  @override
  void stop() {
    final m = _mouse, c = _change;
    _mouse = null;
    _change = null;
    if (m != null) _document.removeEventListener('mousemove', m);
    if (c != null) _document.removeEventListener('pointerlockchange', c);
    try {
      if (_document.pointerLockElement != null) _document.exitPointerLock();
    } on Object {
      // already let go
    }
  }
}
