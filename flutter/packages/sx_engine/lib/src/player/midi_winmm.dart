import 'dart:ffi';

import 'win32.dart';

typedef _MidiProc = Void Function(IntPtr h, Uint32 msg, IntPtr inst, IntPtr p1, IntPtr p2);

final _inNum = winmm.lookupFunction<Uint32 Function(), int Function()>('midiInGetNumDevs');
final _outNum = winmm.lookupFunction<Uint32 Function(), int Function()>('midiOutGetNumDevs');
final _inCaps = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('midiInGetDevCapsW');
final _outCaps = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('midiOutGetDevCapsW');
final _inOpen = winmm.lookupFunction<Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32), int Function(Pointer<IntPtr>, int, int, int, int)>(
  'midiInOpen',
);
final _inStart = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStart');
final _inStop = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStop');
final _inReset = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInReset');
final _inClose = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInClose');
final _outOpen = winmm.lookupFunction<Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32), int Function(Pointer<IntPtr>, int, int, int, int)>(
  'midiOutOpen',
);
final _outShort = winmm.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('midiOutShortMsg');
final _outClose = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiOutClose');

// MIDIINCAPSW: wMid, wPid (2 x WORD), vDriverVersion (UINT), szPname (32 WCHAR), dwSupport.
// MIDIOUTCAPSW: the same, then 4 WORDs before dwSupport.
const _inCapsSize = 2 + 2 + 4 + 64 + 4;
const _outCapsSize = 2 + 2 + 4 + 64 + 8 + 4;
const _nameAt = 8;

/// ShowXpress's MIDI device names match when they are equal or one is in the
/// other, ignoring case. Port of `NameIs`.
bool midiNameIs(String? have, String want) {
  if (have == null || want.isEmpty) return false;
  final h = have.trim().toLowerCase(), w = want.trim().toLowerCase();
  return h == w || have.toLowerCase().contains(w);
}

/// The APC mini (or whatever MIDI device ShowXpress uses) through winmm.
/// Notes and fader moves arrive through [onMessage] on the isolate that
/// opened it, and pad lights go out through [send].
///
/// Port of `OpenMidi` and `CloseMidi`. Not run on real hardware.
class WinMidi {
  WinMidi._(this._in, this._out, this._cb, this.name, this.why);

  /// Opens the devices whose names match [inName] and [outName] ('' = none).
  /// [why] says what went wrong with the input, '' when nothing did.
  factory WinMidi.open(String inName, String outName, void Function(int msg) onMessage) {
    var why = '', name = '';
    var hIn = 0, hOut = 0;
    NativeCallable<_MidiProc>? cb;
    final caps = winAlloc<Uint8>(_outCapsSize), h = winAlloc<IntPtr>(8);
    try {
      if (inName.isNotEmpty) {
        final n = _inNum();
        for (var i = 0; i < n; i++) {
          if (_inCaps(i, caps, _inCapsSize) != 0) continue;
          final have = fromWide(Pointer<Uint16>.fromAddress(caps.address + _nameAt), max: 32);
          if (!midiNameIs(have, inName)) continue;
          // the driver calls back on its own thread: a listener posts the message to this isolate
          cb = NativeCallable<_MidiProc>.listener((int _, int msg, int _, int p1, int _) {
            if (msg == 0x3C3) onMessage(p1 & 0xFFFFFF); // MIM_DATA
          });
          if (_inOpen(h, i, cb.nativeFunction.address, 0, 0x30000) == 0) {
            // CALLBACK_FUNCTION
            hIn = h.value;
            _inStart(hIn);
            name = have!.trim();
          } else {
            why = '$have is busy';
            cb.close();
            cb = null;
          }
          break;
        }
        if (hIn == 0 && why.isEmpty) why = '$inName is not plugged in';
      }
      if (outName.isNotEmpty) {
        final n = _outNum();
        for (var i = 0; i < n; i++) {
          if (_outCaps(i, caps, _outCapsSize) != 0) continue;
          if (!midiNameIs(fromWide(Pointer<Uint16>.fromAddress(caps.address + _nameAt), max: 32), outName)) continue;
          if (_outOpen(h, i, 0, 0, 0) == 0) hOut = h.value;
          break;
        }
      }
    } finally {
      winFree(caps);
      winFree(h);
    }
    return WinMidi._(hIn, hOut, cb, name, why);
  }

  int _in, _out;
  NativeCallable<_MidiProc>? _cb;

  /// The input's name, '' when none is open.
  final String name;
  final String why;

  /// A short message (status | d1 << 8 | d2 << 16) to the pads.
  void send(int msg) {
    if (_out != 0) _outShort(_out, msg);
  }

  void close() {
    if (_in != 0) {
      _inStop(_in);
      _inReset(_in);
      _inClose(_in);
      _in = 0;
    }
    _cb?.close();
    _cb = null;
    if (_out != 0) {
      _outClose(_out);
      _out = 0;
    }
  }
}
