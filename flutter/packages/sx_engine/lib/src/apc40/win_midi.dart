import 'dart:ffi';
import 'dart:io' show sleep;

import '../player/win32.dart';
import 'bridge.dart';

// The APC40's MIDI ports on Windows, through winmm.dll. Nothing here is
// looked up until it is first used, so importing this file elsewhere costs
// nothing. Written from the Win32 headers on Linux and not yet run on Windows.
//
// Port of the C# class `Apc40Io` in `apc40.ps1`.

/// `MidiInProc(HMIDIIN, UINT wMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2)`.
typedef _MidiInProc = Void Function(IntPtr h, Uint32 msg, IntPtr inst, IntPtr p1, IntPtr p2);

/// `MIDIHDR`. Dart lays it out as C does: 120 bytes on 64-bit Windows, 64 on 32-bit.
final class _MidiHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  external Pointer<_MidiHdr> lpNext;
  @IntPtr()
  external int reserved;
  @Uint32()
  external int dwOffset;
  @Array(8)
  external Array<IntPtr> dwReserved;
}

typedef _Handle = Uint32 Function(IntPtr);
typedef _HandleDart = int Function(int);
typedef _Open = Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32);
typedef _OpenDart = int Function(Pointer<IntPtr>, int, int, int, int);
typedef _Hdr = Uint32 Function(IntPtr, Pointer<_MidiHdr>, Uint32);
typedef _HdrDart = int Function(int, Pointer<_MidiHdr>, int);
typedef _Caps = Uint32 Function(IntPtr, Pointer<Uint8>, Uint32);
typedef _CapsDart = int Function(int, Pointer<Uint8>, int);

final _inNum = winmm.lookupFunction<Uint32 Function(), int Function()>('midiInGetNumDevs');
final _outNum = winmm.lookupFunction<Uint32 Function(), int Function()>('midiOutGetNumDevs');
final _inCaps = winmm.lookupFunction<_Caps, _CapsDart>('midiInGetDevCapsW');
final _outCaps = winmm.lookupFunction<_Caps, _CapsDart>('midiOutGetDevCapsW');
final _inOpen = winmm.lookupFunction<_Open, _OpenDart>('midiInOpen');
final _inStart = winmm.lookupFunction<_Handle, _HandleDart>('midiInStart');
final _inStop = winmm.lookupFunction<_Handle, _HandleDart>('midiInStop');
final _inReset = winmm.lookupFunction<_Handle, _HandleDart>('midiInReset');
final _inClose = winmm.lookupFunction<_Handle, _HandleDart>('midiInClose');
final _outOpen = winmm.lookupFunction<_Open, _OpenDart>('midiOutOpen');
final _outShort = winmm.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('midiOutShortMsg');
final _outPrepare = winmm.lookupFunction<_Hdr, _HdrDart>('midiOutPrepareHeader');
final _outUnprepare = winmm.lookupFunction<_Hdr, _HdrDart>('midiOutUnprepareHeader');
final _outLong = winmm.lookupFunction<_Hdr, _HdrDart>('midiOutLongMsg');
final _outReset = winmm.lookupFunction<_Handle, _HandleDart>('midiOutReset');
final _outClose = winmm.lookupFunction<_Handle, _HandleDart>('midiOutClose');

// MIDIINCAPSW: wMid, wPid (WORD), vDriverVersion (UINT), szPname (32 WCHAR), dwSupport (DWORD).
// MIDIOUTCAPSW: the same, with wTechnology, wVoices, wNotes, wChannelMask (WORD) before dwSupport.
const _inCapsSize = 2 + 2 + 4 + 64 + 4;
const _outCapsSize = 2 + 2 + 4 + 64 + 8 + 4;
const _nameAt = 8;

const _mimData = 0x3C3;
const _callbackFunction = 0x30000;
const _mhdrDone = 1;

/// The APC40 through winmm. Messages from it arrive on a system thread and
/// come to this isolate through a [NativeCallable.listener], so the isolate
/// must keep its event loop turning (the bridge's loop awaits between steps).
class WinApc40Midi implements Apc40Midi {
  int _in = 0, _out = 0;
  NativeCallable<_MidiInProc>? _cb;
  final _q = <int>[];

  /// Goes up on every open and close, so a message still on its way from a
  /// closed port is dropped as the old `Close` emptied the queue.
  var _gen = 0;

  /// The first device whose name contains [name], case sensitive as .NET's
  /// `Contains`, or -1. `FindIn` and `FindOut`.
  int _find(String name, {required bool input}) {
    final size = input ? _inCapsSize : _outCapsSize;
    final caps = winAlloc<Uint8>(size);
    try {
      final n = input ? _inNum() : _outNum();
      for (var i = 0; i < n; i++) {
        caps.asTypedList(size).fillRange(0, size, 0);
        if ((input ? _inCaps(i, caps, size) : _outCaps(i, caps, size)) != 0) continue;
        if ((fromWide(Pointer<Uint16>.fromAddress(caps.address + _nameAt), max: 32) ?? '').contains(name)) return i;
      }
      return -1;
    } finally {
      winFree(caps);
    }
  }

  @override
  bool get isOpen => _in != 0;

  @override
  bool present(String name) => _find(name, input: true) >= 0;

  @override
  int open(String name) {
    close();
    final i = _find(name, input: true), o = _find(name, input: false);
    if (i < 0 || o < 0) return -1;
    final gen = _gen;
    final cb = NativeCallable<_MidiInProc>.listener((int _, int msg, int _, int p1, int _) {
      if (msg == _mimData && gen == _gen) _q.add(p1);
    });
    final h = winAlloc<IntPtr>(sizeOf<IntPtr>());
    try {
      var r = _inOpen(h, i, cb.nativeFunction.address, 0, _callbackFunction);
      if (r != 0) {
        cb.close();
        return r;
      }
      _in = h.value;
      _cb = cb;
      r = _outOpen(h, o, 0, 0, 0);
      if (r != 0) {
        _inClose(_in);
        _in = 0;
        cb.close();
        _cb = null;
        return r;
      }
      _out = h.value;
      _inStart(_in);
      return 0;
    } finally {
      winFree(h);
    }
  }

  @override
  void send(int status, int d1, int d2) {
    if (_out != 0) _outShort(_out, status | (d1 << 8) | (d2 << 16));
  }

  @override
  int sysex(List<int> bytes) {
    if (_out == 0) return 1;
    final buf = winAlloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final size = sizeOf<_MidiHdr>();
    final hdr = winAlloc<_MidiHdr>(size); // zeroed
    hdr.ref
      ..lpData = buf
      ..dwBufferLength = bytes.length
      ..dwBytesRecorded = bytes.length;
    var r = _outPrepare(_out, hdr, size);
    if (r == 0) r = _outLong(_out, hdr, size);
    // the driver sets MHDR_DONE when the message has gone out
    for (var w = 0; w < 100; w++) {
      if (hdr.ref.dwFlags & _mhdrDone != 0) break;
      sleep(const Duration(milliseconds: 5));
    }
    _outUnprepare(_out, hdr, size);
    winFree(hdr);
    winFree(buf);
    return r;
  }

  @override
  List<int> take() {
    final l = [..._q];
    _q.clear();
    return l;
  }

  @override
  void close() {
    if (_in != 0) {
      _inStop(_in);
      _inReset(_in);
      _inClose(_in);
      _in = 0;
    }
    // only now: winmm calls it up to midiInClose, and calling a closed one is undefined
    _cb?.close();
    _cb = null;
    if (_out != 0) {
      _outReset(_out);
      _outClose(_out);
      _out = 0;
    }
    _gen++;
    _q.clear();
  }
}
