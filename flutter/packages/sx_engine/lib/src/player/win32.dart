/// The few Windows calls the player and the Chauvet driver need, through
/// `dart:ffi`. Every library here is opened on first use, so importing this
/// file on a Mac or Linux costs nothing as long as nothing is called.
///
/// None of this has run on Windows yet (the port was written on Linux).
library;

import 'dart:ffi';

final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary winmm = DynamicLibrary.open('winmm.dll');

final _localAlloc = kernel32.lookupFunction<Pointer<Void> Function(Uint32, IntPtr), Pointer<Void> Function(int, int)>('LocalAlloc');
final _localFree = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

/// [bytes] of zeroed native memory. Free it with [winFree].
Pointer<T> winAlloc<T extends NativeType>(int bytes) {
  final p = _localAlloc(0x40, bytes); // LPTR: fixed, zeroed
  if (p.address == 0) throw StateError('out of memory');
  return p.cast<T>();
}

void winFree(Pointer<NativeType> p) {
  if (p.address != 0) _localFree(p.cast<Void>());
}

/// [s] as a zero-terminated UTF-16 string. Free it with [winFree].
Pointer<Uint16> toWide(String s) {
  final units = s.codeUnits;
  final p = winAlloc<Uint16>((units.length + 1) * 2);
  p.asTypedList(units.length + 1).setAll(0, units);
  return p;
}

/// A zero-terminated UTF-16 string, like .NET's `Marshal.PtrToStringUni`.
/// Null for a null pointer.
String? fromWide(Pointer<Uint16> p, {int max = 65536}) {
  if (p.address == 0) return null;
  var n = 0;
  while (n < max && p[n] != 0) {
    n++;
  }
  return String.fromCharCodes(p.asTypedList(n));
}

final _setDllDirectory = kernel32.lookupFunction<Int32 Function(Pointer<Uint16>), int Function(Pointer<Uint16>)>('SetDllDirectoryW');

/// Where Windows looks for the DLLs a driver loads by bare name.
void setDllDirectory(String dir) {
  final w = toWide(dir);
  try {
    _setDllDirectory(w);
  } finally {
    winFree(w);
  }
}

final _setThreadExecutionState = kernel32.lookupFunction<Uint32 Function(Uint32), int Function(int)>('SetThreadExecutionState');

/// Keeps the laptop from sleeping and the screen on for a while longer.
/// Call it again well within the screen saver's time.
///
/// The old player set ES_CONTINUOUS once on its own thread. A Dart isolate
/// can move between threads, so this resets the idle timers each time instead.
void keepAwake() => _setThreadExecutionState(0x1 | 0x2); // ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED

final _timeBeginPeriod = winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>('timeBeginPeriod');
final _timeEndPeriod = winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>('timeEndPeriod');

/// 1 ms timers while the player runs, so 25 ms frames are 25 ms and not 31.
void fineTimers(bool on) => on ? _timeBeginPeriod(1) : _timeEndPeriod(1);
