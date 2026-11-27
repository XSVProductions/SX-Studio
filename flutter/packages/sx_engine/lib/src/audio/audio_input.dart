import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../player/win32.dart';

/// Somewhere the music comes from: a sound card input, or a recording played
/// at real speed (for trying the detector without the mixer).
abstract interface class AudioInput {
  /// Its name, as the music card shows it.
  String get name;

  /// Samples per second.
  int get fs;

  /// The mono samples (-1..1) that arrived since the last call. Empty when none did.
  Float64List read();

  void close();
}

/// Opens [device]. A name starting with `file:` plays that WAV file instead,
/// at real speed, as if it came from the mixer. Throws [AudioInputError].
AudioInput openAudioInput(String device) {
  if (device.toLowerCase().startsWith('file:')) return WavFileInput(device.substring(5).trim());
  if (Platform.isWindows) return WaveIn.open(device);
  throw AudioInputError('Listening to the mixer works on Windows for now. To try a recording, type file: and its path as the input.');
}

/// The audio inputs on this computer, for the music card.
List<String> audioInputNames() => Platform.isWindows ? WaveIn.names() : const [];

class AudioInputError implements Exception {
  AudioInputError(this.message);

  final String message;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------- Windows: winmm waveIn

final _num = winmm.lookupFunction<Uint32 Function(), int Function()>('waveInGetNumDevs');
final _caps = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('waveInGetDevCapsW');
final _open = winmm
    .lookupFunction<
      Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<Uint8>, IntPtr, IntPtr, Uint32),
      int Function(Pointer<IntPtr>, int, Pointer<Uint8>, int, int, int)
    >('waveInOpen');
final _prepare = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('waveInPrepareHeader');
final _unprepare = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('waveInUnprepareHeader');
final _addBuffer = winmm.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('waveInAddBuffer');
final _start = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStart');
final _stop = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStop');
final _reset = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInReset');
final _close = winmm.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInClose');

// WAVEINCAPSW: wMid, wPid (2 x WORD), vDriverVersion (UINT), szPname (32 WCHAR), dwFormats, wChannels, wReserved1.
const _capsSize = 2 + 2 + 4 + 64 + 4 + 2 + 2;
const _nameAt = 8;

// WAVEHDR on 64-bit Windows: lpData, dwBufferLength, dwBytesRecorded, dwUser, dwFlags, dwLoops, lpNext, reserved.
const _hdrSize = 48;
const _hdrLen = 8, _hdrRecorded = 12, _hdrFlags = 24;
const _whdrDone = 1;

/// A sound card input through winmm, 16-bit stereo, read by polling: a few
/// 10 ms buffers are queued, and [read] takes the ones Windows has filled and
/// queues them again. No callback, so nothing runs on the driver's thread.
///
/// The Yamaha DM3's USB inputs show up here once the Yamaha Steinberg USB
/// driver is installed. Not run on real hardware yet.
class WaveIn implements AudioInput {
  WaveIn._(this.name, this.fs, this._h, this._hdrs, this._data, this._bytes);

  /// The input names, in Windows' order.
  static List<String> names() {
    final caps = winAlloc<Uint8>(_capsSize);
    try {
      return [
        for (var i = 0; i < _num(); i++)
          if (_caps(i, caps, _capsSize) == 0) fromWide(Pointer<Uint16>.fromAddress(caps.address + _nameAt), max: 32) ?? 'Input ${i + 1}',
      ];
    } finally {
      winFree(caps);
    }
  }

  /// Opens the input whose name contains [want] (ignoring case). With '' the
  /// first one with DM3 or Yamaha in its name, else Windows' default input.
  factory WaveIn.open(String want) {
    final all = names();
    var id = -1; // WAVE_MAPPER: Windows' default
    if (want.trim().isNotEmpty) {
      id = all.indexWhere((n) => n.toLowerCase().contains(want.trim().toLowerCase()));
      if (id < 0) throw AudioInputError('No audio input called $want. Is the mixer plugged in by USB?');
    } else {
      id = all.indexWhere((n) => n.toLowerCase().contains('dm3'));
      if (id < 0) id = all.indexWhere((n) => n.toLowerCase().contains('yamaha'));
    }
    final name = id >= 0 ? all[id] : 'Windows default input';
    final h = winAlloc<IntPtr>(8), fmt = winAlloc<Uint8>(18);
    try {
      for (final fs in const [48000, 44100, 96000]) {
        // WAVEFORMATEX: PCM, 2 channels, 16 bits
        ByteData.sublistView(fmt.asTypedList(18))
          ..setUint16(0, 1, Endian.little)
          ..setUint16(2, 2, Endian.little)
          ..setUint32(4, fs, Endian.little)
          ..setUint32(8, fs * 4, Endian.little)
          ..setUint16(12, 4, Endian.little)
          ..setUint16(14, 16, Endian.little)
          ..setUint16(16, 0, Endian.little);
        if (_open(h, id < 0 ? 0xFFFFFFFF : id, fmt, 0, 0, 0) != 0) continue; // CALLBACK_NULL
        final hw = h.value;
        const count = 8;
        final bytes = fs ~/ 100 * 4; // 10 ms of 16-bit stereo
        final hdrs = winAlloc<Uint8>(_hdrSize * count), data = winAlloc<Uint8>(bytes * count);
        for (var k = 0; k < count; k++) {
          final hd = Pointer<Uint8>.fromAddress(hdrs.address + k * _hdrSize);
          ByteData.sublistView(hd.asTypedList(_hdrSize))
            ..setUint64(0, data.address + k * bytes, Endian.little)
            ..setUint32(_hdrLen, bytes, Endian.little);
          _prepare(hw, hd, _hdrSize);
          _addBuffer(hw, hd, _hdrSize);
        }
        _start(hw);
        return WaveIn._(name, fs, hw, hdrs, data, bytes);
      }
    } finally {
      winFree(h);
      winFree(fmt);
    }
    throw AudioInputError('$name would not open (it may be in use, or not 16-bit stereo at 48, 44.1 or 96 kHz).');
  }

  @override
  final String name;
  @override
  final int fs;
  int _h;
  final Pointer<Uint8> _hdrs, _data;
  final int _bytes;
  int _next = 0; // the buffer Windows fills next

  ByteData _hdr(int k) => ByteData.sublistView(Pointer<Uint8>.fromAddress(_hdrs.address + k * _hdrSize).asTypedList(_hdrSize));

  @override
  Float64List read() {
    if (_h == 0) return Float64List(0);
    final out = <double>[];
    for (var guard = 0; guard < 8; guard++) {
      final hd = _hdr(_next);
      if (hd.getUint32(_hdrFlags, Endian.little) & _whdrDone == 0) break;
      final got = hd.getUint32(_hdrRecorded, Endian.little);
      final bd = ByteData.sublistView(Pointer<Uint8>.fromAddress(_data.address + _next * _bytes).asTypedList(got));
      for (var i = 0; i + 3 < got; i += 4) {
        out.add((bd.getInt16(i, Endian.little) + bd.getInt16(i + 2, Endian.little)) / 65536.0);
      }
      hd.setUint32(_hdrFlags, hd.getUint32(_hdrFlags, Endian.little) & ~_whdrDone, Endian.little);
      _addBuffer(_h, Pointer<Uint8>.fromAddress(_hdrs.address + _next * _hdrSize), _hdrSize);
      _next = (_next + 1) % 8;
    }
    return Float64List.fromList(out);
  }

  @override
  void close() {
    if (_h == 0) return;
    _stop(_h);
    _reset(_h);
    for (var k = 0; k < 8; k++) {
      _unprepare(_h, Pointer<Uint8>.fromAddress(_hdrs.address + k * _hdrSize), _hdrSize);
    }
    _close(_h);
    _h = 0;
    winFree(_hdrs);
    winFree(_data);
  }
}

// ---------------------------------------------------------------- a recording, at real speed

/// Plays a WAV file (16-bit or 32-bit float, any number of channels) into
/// the detector at real speed, as if it came from the mixer. For trying the
/// detector with a recording of a set. Reads the file as it goes, so an
/// hour-long recording is fine.
class WavFileInput implements AudioInput {
  WavFileInput._(this.name, this.fs, this._f, this._from, this._frames, this._ch, this._float);

  factory WavFileInput(String path) {
    final file = File(path);
    if (!file.existsSync()) throw AudioInputError('There is no recording at $path.');
    final f = file.openSync();
    try {
      final head = f.readSync(12);
      if (head.length < 12 || String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' || String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
        throw AudioInputError('$path is not a WAV file. Save the recording as WAV first.');
      }
      var at = 12, fmt = 0, ch = 0, bits = 0, rate = 0;
      final len = f.lengthSync();
      while (at + 8 <= len) {
        f.setPositionSync(at);
        final ck = f.readSync(8);
        final id = String.fromCharCodes(ck.sublist(0, 4));
        final size = ByteData.sublistView(ck).getUint32(4, Endian.little);
        final body = at + 8;
        if (id == 'fmt ') {
          final d = ByteData.sublistView(f.readSync(math.min(size, 40)));
          fmt = d.getUint16(0, Endian.little);
          ch = d.getUint16(2, Endian.little);
          rate = d.getUint32(4, Endian.little);
          bits = d.getUint16(14, Endian.little);
          if (fmt == 0xFFFE && size >= 26) fmt = d.getUint16(24, Endian.little); // WAVE_FORMAT_EXTENSIBLE: the sub-format
        } else if (id == 'data') {
          final ok = ch > 0 && rate > 0 && ((fmt == 1 && bits == 16) || (fmt == 3 && bits == 32));
          if (!ok) throw AudioInputError("$path is a kind of WAV this can't read. Save it as 16-bit WAV.");
          final frames = math.min(size, len - body) ~/ (ch * bits ~/ 8);
          return WavFileInput._(path, rate, f, body, frames, ch, fmt == 3);
        }
        at = body + size + (size & 1);
      }
      throw AudioInputError('$path has no sound in it.');
    } on Object {
      f.closeSync();
      rethrow;
    }
  }

  @override
  final String name;
  @override
  final int fs;
  final RandomAccessFile _f;
  final int _from, _frames, _ch;
  final bool _float;
  final _clock = Stopwatch()..start();
  int _at = 0; // frames read
  bool _closed = false;

  @override
  Float64List read() {
    if (_closed) return Float64List(0);
    final want = math.min(_frames, _clock.elapsedMicroseconds * fs ~/ 1000000);
    if (want <= _at) return Float64List(0);
    final n = want - _at, size = _float ? 4 : 2, frame = _ch * size;
    _f.setPositionSync(_from + _at * frame);
    final d = ByteData.sublistView(_f.readSync(n * frame));
    final out = Float64List(d.lengthInBytes ~/ frame);
    for (var i = 0; i < out.length; i++) {
      var s = 0.0;
      for (var c = 0; c < _ch; c++) {
        final o = i * frame + c * size;
        s += _float ? d.getFloat32(o, Endian.little) : d.getInt16(o, Endian.little) / 32768.0;
      }
      out[i] = s / _ch;
    }
    _at = want;
    return out;
  }

  /// True once the whole recording has been read.
  bool get finished => _at >= _frames;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _f.closeSync();
  }
}
