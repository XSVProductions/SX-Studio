// The few Windows calls SX Studio needs to see and close ShowXpress, through
// dart:ffi straight to kernel32 and user32. Nothing here runs until a
// function is called, so the file compiles and loads on every platform.
//
// Untested on real Windows (the port was written on Linux). See the report.

import 'dart:ffi';

import 'sx_process.dart';

final _k32 = DynamicLibrary.open('kernel32.dll');
final _u32 = DynamicLibrary.open('user32.dll');

// ---- memory, from the process heap (package:ffi's calloc is not a dependency)
final _getProcessHeap = _k32.lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
final _heapAlloc = _k32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr), Pointer<Void> Function(int, int, int)>('HeapAlloc');
final _heapFree = _k32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>), int Function(int, int, Pointer<Void>)>('HeapFree');

final class _Heap implements Allocator {
  const _Heap();

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final p = _heapAlloc(_getProcessHeap(), 8 /* HEAP_ZERO_MEMORY */, byteCount);
    if (p.address == 0) throw StateError('Out of memory');
    return p.cast();
  }

  @override
  void free(Pointer pointer) => _heapFree(_getProcessHeap(), 0, pointer.cast());
}

const _heap = _Heap();

String _utf16(Pointer<Uint16> p, int max) {
  final units = <int>[];
  for (var i = 0; i < max && p[i] != 0; i++) {
    units.add(p[i]);
  }
  return String.fromCharCodes(units);
}

// ---- the process list (Toolhelp)
final class _ProcessEntry extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ProcessID;
  @IntPtr()
  external int th32DefaultHeapID;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int cntThreads;
  @Uint32()
  external int th32ParentProcessID;
  @Int32()
  external int pcPriClassBase;
  @Uint32()
  external int dwFlags;
  @Array(260)
  external Array<Uint16> szExeFile;
}

final _snapshot = _k32.lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>('CreateToolhelp32Snapshot');
final _first = _k32.lookupFunction<Int32 Function(IntPtr, Pointer<_ProcessEntry>), int Function(int, Pointer<_ProcessEntry>)>('Process32FirstW');
final _next = _k32.lookupFunction<Int32 Function(IntPtr, Pointer<_ProcessEntry>), int Function(int, Pointer<_ProcessEntry>)>('Process32NextW');
final _closeHandle = _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

/// Every running process: id and program file name (`TheLightingController.exe`).
List<({int pid, String exeFile})> windowsProcesses() {
  final snap = _snapshot(2 /* TH32CS_SNAPPROCESS */, 0);
  if (snap == -1 || snap == 0) return const [];
  final e = _heap<_ProcessEntry>();
  try {
    e.ref.dwSize = sizeOf<_ProcessEntry>();
    final out = <({int pid, String exeFile})>[];
    for (var ok = _first(snap, e); ok != 0; ok = _next(snap, e)) {
      final name = <int>[];
      for (var i = 0; i < 260 && e.ref.szExeFile[i] != 0; i++) {
        name.add(e.ref.szExeFile[i]);
      }
      out.add((pid: e.ref.th32ProcessID, exeFile: String.fromCharCodes(name)));
    }
    return out;
  } finally {
    _heap.free(e);
    _closeHandle(snap);
  }
}

// ---- windows
typedef _EnumProc = Int32 Function(IntPtr hwnd, IntPtr lParam);

final _enumWindows = _u32.lookupFunction<Int32 Function(Pointer<NativeFunction<_EnumProc>>, IntPtr), int Function(Pointer<NativeFunction<_EnumProc>>, int)>(
  'EnumWindows',
);
final _enumChildWindows = _u32
    .lookupFunction<Int32 Function(IntPtr, Pointer<NativeFunction<_EnumProc>>, IntPtr), int Function(int, Pointer<NativeFunction<_EnumProc>>, int)>(
      'EnumChildWindows',
    );
final _windowPid = _u32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _isVisible = _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
final _getWindow = _u32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetWindow');
final _getWindowLong = _u32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongW');
final _dlgCtrlId = _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GetDlgCtrlID');
final _className = _u32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>, Int32), int Function(int, Pointer<Uint16>, int)>('GetClassNameW');
final _sendMessage = _u32.lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('SendMessageW');
final _postMessage = _u32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('PostMessageW');

/// Calls [visit] for each window from [enumerate] until it returns false.
void _each(void Function(Pointer<NativeFunction<_EnumProc>> cb) enumerate, bool Function(int hwnd) visit) {
  final cb = NativeCallable<_EnumProc>.isolateLocal((int h, int _) => visit(h) ? 1 : 0, exceptionalReturn: 0);
  try {
    enumerate(cb.nativeFunction);
  } finally {
    cb.close();
  }
}

int _pidOf(int hwnd) {
  final p = _heap<Uint32>();
  try {
    _windowPid(hwnd, p);
    return p.value;
  } finally {
    _heap.free(p);
  }
}

String _cls(int hwnd) {
  final b = _heap<Uint16>(256);
  try {
    _className(hwnd, b, 256);
    return _utf16(b, 256);
  } finally {
    _heap.free(b);
  }
}

String _text(int hwnd) {
  final b = _heap<Uint16>(4096);
  try {
    _sendMessage(hwnd, 0x0D /* WM_GETTEXT */, 4096, b.address);
    return _utf16(b, 4096);
  } finally {
    _heap.free(b);
  }
}

/// Asks [pid] to close the way .NET's `Process.CloseMainWindow` does: posts
/// WM_CLOSE to its first visible, unowned top-level window, unless that
/// window is disabled (a dialog is open on it). False when there was none.
bool closeMainWindow(int pid) {
  var main = 0;
  _each((cb) => _enumWindows(cb, 0), (h) {
    if (_pidOf(h) == pid && _getWindow(h, 4 /* GW_OWNER */) == 0 && _isVisible(h) != 0) {
      main = h;
      return false;
    }
    return true;
  });
  if (main == 0) return false;
  if (_getWindowLong(main, -16 /* GWL_STYLE */) & 0x08000000 /* WS_DISABLED */ != 0) return false;
  _postMessage(main, 0x0010 /* WM_CLOSE */, 0, 0);
  return true;
}

/// Answers ShowXpress's "Do you really want to quit?" with Yes, if one of
/// [pids] shows it. Returns the question it answered, or '' when there was
/// none. Port of `SxQuit.Answer` in `sx_quit.ps1`.
String answerQuitDialog(List<int> pids, Set<String> quit) {
  var done = '';
  _each((cb) => _enumWindows(cb, 0), (h) {
    // only standard Windows message boxes
    if (!pids.contains(_pidOf(h)) || _isVisible(h) == 0 || _cls(h) != '#32770') return true;
    final controls = <DialogControl>[], handles = <int>[];
    _each((cb) => _enumChildWindows(h, cb, 0), (c) {
      controls.add((cls: _cls(c), text: _text(c), id: _dlgCtrlId(c)));
      handles.add(c);
      return true;
    });
    final yes = quitDialogYes(controls, quit);
    if (yes == null) return true;
    _postMessage(h, 0x0111 /* WM_COMMAND */, controls[yes].id, handles[yes]); // the same as clicking Yes
    done = controls.where((c) => c.cls == 'Static' && c.text.trim().isNotEmpty).map((c) => c.text).join(' ').trim();
    return false;
  });
  return done;
}
