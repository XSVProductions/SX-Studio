import 'dart:ffi';
import 'dart:io';

// The old PowerShell app showed its page in an Edge or Chrome app window. After
// an update that window stayed open, saying it can be closed, with nothing
// behind it any more. The app closes such windows when it starts, before its
// own window is used. The Flutter window has another class, so it is never hit.
//
// Port of `Close-OldWindows` in `df_aim_gui.ps1`. Windows only. It uses
// user32.dll through dart:ffi, and kernel32.dll for the text buffer, so the
// app needs no ffi package.

typedef _EnumProcC = Int32 Function(IntPtr hwnd, IntPtr lParam);

// BOOL EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam)
typedef _EnumWindowsC = Int32 Function(Pointer<NativeFunction<_EnumProcC>> proc, IntPtr lParam);
typedef _EnumWindowsD = int Function(Pointer<NativeFunction<_EnumProcC>> proc, int lParam);
// BOOL IsWindowVisible(HWND hWnd), BOOL IsWindow(HWND hWnd)
typedef _HwndBoolC = Int32 Function(IntPtr hwnd);
typedef _HwndBoolD = int Function(int hwnd);
// BOOL PostMessageW(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam)
typedef _PostMessageC = Int32 Function(IntPtr hwnd, Uint32 msg, UintPtr wParam, IntPtr lParam);
typedef _PostMessageD = int Function(int hwnd, int msg, int wParam, int lParam);
// int GetClassNameW(HWND hWnd, LPWSTR lpClassName, int nMaxCount), and GetWindowTextW the same
typedef _GetTextC = Int32 Function(IntPtr hwnd, Pointer<Uint16> buf, Int32 max);
typedef _GetTextD = int Function(int hwnd, Pointer<Uint16> buf, int max);
// HGLOBAL GlobalAlloc(UINT uFlags, SIZE_T dwBytes), HGLOBAL GlobalFree(HGLOBAL hMem)
typedef _GlobalAllocC = Pointer<Uint16> Function(Uint32 flags, UintPtr bytes);
typedef _GlobalAllocD = Pointer<Uint16> Function(int flags, int bytes);
typedef _GlobalFreeC = Pointer<Void> Function(Pointer<Uint16> mem);
typedef _GlobalFreeD = Pointer<Void> Function(Pointer<Uint16> mem);

const _wmClose = 0x0010;
const _gptr = 0x0040; // GMEM_FIXED | GMEM_ZEROINIT
const _bufChars = 256;

/// The old app's window: an Edge or Chrome app window titled exactly this. A
/// normal browser window has " - Microsoft Edge" or similar after the title.
const _oldClass = 'Chrome_WidgetWin_1';
const _oldTitle = 'SX Studio';

// EnumWindows calls back on this thread, before it returns, so the callback
// works on these.
final List<int> _found = [];
Pointer<Uint16> _buf = nullptr;
late _HwndBoolD _isWindowVisible;
late _GetTextD _getClassName, _getWindowText;

/// The text a Win32 call wrote into [_buf], [n] characters long.
String _text(int n) => n <= 0 ? '' : String.fromCharCodes(_buf.asTypedList(n));

int _onWindow(int hwnd, int lParam) {
  if (_isWindowVisible(hwnd) == 0) return 1;
  if (_text(_getClassName(hwnd, _buf, _bufChars)) != _oldClass) return 1;
  if (_text(_getWindowText(hwnd, _buf, _bufChars)) == _oldTitle) _found.add(hwnd);
  return 1;
}

/// Asks every visible window of the old app to close, then waits up to
/// [wait] for them to go. Returns how many it found. Does nothing and
/// returns 0 off Windows, or when user32.dll can't be used.
///
/// Checked on Windows 11 with Edge app windows: only the one titled exactly
/// "SX Studio" closes.
Future<int> closeOldWindows({Duration wait = const Duration(milliseconds: 1500)}) async {
  if (!Platform.isWindows) return 0;
  try {
    final user32 = DynamicLibrary.open('user32.dll'), kernel32 = DynamicLibrary.open('kernel32.dll');
    final enumWindows = user32.lookupFunction<_EnumWindowsC, _EnumWindowsD>('EnumWindows');
    final isWindow = user32.lookupFunction<_HwndBoolC, _HwndBoolD>('IsWindow');
    final postMessage = user32.lookupFunction<_PostMessageC, _PostMessageD>('PostMessageW');
    _isWindowVisible = user32.lookupFunction<_HwndBoolC, _HwndBoolD>('IsWindowVisible');
    _getClassName = user32.lookupFunction<_GetTextC, _GetTextD>('GetClassNameW');
    _getWindowText = user32.lookupFunction<_GetTextC, _GetTextD>('GetWindowTextW');
    final globalAlloc = kernel32.lookupFunction<_GlobalAllocC, _GlobalAllocD>('GlobalAlloc');
    final globalFree = kernel32.lookupFunction<_GlobalFreeC, _GlobalFreeD>('GlobalFree');

    _found.clear();
    _buf = globalAlloc(_gptr, _bufChars * 2);
    if (_buf == nullptr) return 0;
    try {
      enumWindows(Pointer.fromFunction<_EnumProcC>(_onWindow, 0), 0);
    } finally {
      globalFree(_buf);
      _buf = nullptr;
    }
    final found = [..._found];
    for (final h in found) {
      postMessage(h, _wmClose, 0, 0);
    }
    final end = DateTime.now().add(wait);
    while (found.any((h) => isWindow(h) != 0) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return found.length;
  } on Object {
    // like the old app: a window that can't be closed is left alone
    return 0;
  }
}
