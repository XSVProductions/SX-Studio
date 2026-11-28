import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../player/win32.dart';
import 'dmx_output.dart';

// The Enttec DMX USB Pro, and boxes that speak its protocol (DMXking
// ultraDMX). It shows up as a serial port: a COM port on Windows (FTDI's
// driver, which Windows installs by itself), /dev/cu.usbserial-... on a Mac.
// The box has its own processor and keeps sending the last frame on the DMX
// line by itself, so SX Studio only writes when something changed, plus a
// refresh every second.
//
// Messages (Enttec's "DMX USB Pro Widget API"): 0x7E, a label, the data
// length (low byte, high byte), the data, 0xE7.
//   label 6  "Output Only Send DMX Packet": start code 0, then up to 512 channels.
//   label 10 "Get Widget Serial Number": no data. The box answers with label 10 and 4 bytes.
//
// New in the Flutter app: ShowXpress has no such output. Not run on a real
// interface yet.

const _som = 0x7E, _eom = 0xE7;
const _labelDmx = 6, _labelSerial = 10;

/// The message that sets the first [channels] channels (1 to 512) of
/// [frame] (byte 0 is channel 1): label 6, start code 0.
Uint8List enttecDmxPacket(Uint8List frame, {int channels = 512}) {
  final n = channels.clamp(1, 512).toInt();
  final len = n + 1; // the start code
  final out = Uint8List(len + 5);
  out[0] = _som;
  out[1] = _labelDmx;
  out[2] = len & 0xFF;
  out[3] = len >> 8;
  out[4] = 0; // start code
  for (var i = 0; i < n && i < frame.length; i++) {
    out[5 + i] = frame[i];
  }
  out[out.length - 1] = _eom;
  return out;
}

/// The "what is your serial number" question. A Pro answers it, other serial devices don't.
final enttecSerialRequest = Uint8List.fromList([_som, _labelSerial, 0, 0, _eom]);

/// True when [reply] holds a Pro's answer to [enttecSerialRequest].
bool isEnttecSerialReply(List<int> reply) {
  for (var i = 0; i + 4 < reply.length; i++) {
    if (reply[i] == _som && reply[i + 1] == _labelSerial && reply[i + 2] == 4 && reply[i + 3] == 0) return true;
  }
  return false;
}

/// The serial ports an Enttec Pro could be on, for the Settings card:
/// COM ports on Windows, /dev/cu.usbserial-... on a Mac, /dev/ttyUSB... on Linux.
List<String> serialPortNames() {
  try {
    if (Platform.isWindows) return _winComPorts();
    final dir = Directory('/dev');
    if (!dir.existsSync()) return const [];
    final pre = Platform.isMacOS ? ['cu.usbserial', 'cu.usbmodem'] : ['ttyUSB', 'ttyACM'];
    return [
      for (final f in dir.listSync())
        if (pre.any((x) => f.uri.pathSegments.last.startsWith(x))) f.path,
    ]..sort();
  } on Object {
    return const [];
  }
}

/// Finds the port a Pro is on. On Windows each COM port is asked for its
/// serial number (a quick question other devices ignore). On a Mac the
/// Enttec's own name is used (its serial number starts EN), else the only
/// USB serial port. Null when none is found.
String? findEnttecPort() {
  final p = pickEnttecPort(serialPortNames(), probe: Platform.isWindows ? _WinSerial.probe : null);
  if (p != null) _lastFound = p;
  return p;
}

/// The port the last search found, in this isolate. While it is gone (the Pro
/// was unplugged) [EnttecProDmx.open] waits for it instead of asking every
/// other port again, which can take seconds each on a Bluetooth port.
String? _lastFound;

/// The Pro's port among [ports]. With [probe] (Windows), the first port that
/// answers as a Pro. Without it, by name: an Enttec's own (`usbserial-EN`),
/// else the only one.
String? pickEnttecPort(List<String> ports, {bool Function(String port)? probe}) {
  if (probe != null) {
    for (final p in ports) {
      if (probe(p)) return p;
    }
    return null;
  }
  final en = ports.where((p) => p.contains('usbserial-EN')).toList();
  if (en.isNotEmpty) return en.first;
  return ports.length == 1 ? ports.single : null;
}

/// Where to open a Pro set to [port] ('' = find it): the set port, else the
/// one found last time while it is still there. Null means search, and
/// [gone] means the last one found is not plugged in, so don't search yet.
({String? port, bool gone}) enttecPortToOpen(String port, List<String> ports, String? lastFound) {
  if (port.trim().isNotEmpty) return (port: port.trim(), gone: false);
  if (lastFound == null) return (port: null, gone: false);
  return ports.contains(lastFound) ? (port: lastFound, gone: false) : (port: null, gone: true);
}

/// DMX through an Enttec DMX USB Pro on serial port [port] ('' = find it).
class EnttecProDmx implements DmxOutput {
  EnttecProDmx._(this.name, this._port);

  /// Opens the Pro. Throws [DmxError] with a message for the user.
  static EnttecProDmx open(String port) {
    final to = enttecPortToOpen(port, port.trim().isEmpty ? serialPortNames() : const [], _lastFound);
    if (to.gone) throw DmxError('The Enttec DMX USB Pro on $_lastFound is unplugged. Plug it back in.');
    final p = to.port ?? findEnttecPort();
    if (p == null) {
      throw DmxError(
        'The Enttec DMX USB Pro was not found. Check its USB cable, and on Windows that it shows up as a COM port in Device Manager. '
        'Then pick its port in Settings > DMX output.',
      );
    }
    final _SerialPort s;
    try {
      s = Platform.isWindows ? _WinSerial.open(p) : _FileSerial.open(p);
    } on Object catch (e) {
      throw DmxError('The Enttec DMX USB Pro on $p would not open: $e');
    }
    return EnttecProDmx._('Enttec DMX USB Pro ($p)', s);
  }

  @override
  final String name;
  final _SerialPort _port;
  final _sent = Uint8List(512);
  var _last = DateTime.utc(1);
  bool _alive = true;
  bool _closed = false;

  /// False once a write failed: the Pro was unplugged.
  bool get alive => _alive;

  @override
  void send(Uint8List frame) {
    if (_closed || !_alive) return;
    var changed = false;
    for (var i = 0; i < 512; i++) {
      if (frame[i] != _sent[i]) {
        changed = true;
        _sent[i] = frame[i];
      }
    }
    final now = DateTime.now();
    if (!changed && now.difference(_last) < const Duration(seconds: 1)) return;
    _last = now;
    try {
      _port.write(enttecDmxPacket(_sent));
    } on Object {
      _alive = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _port.close();
    } on Object {
      // already gone
    }
  }
}

abstract interface class _SerialPort {
  void write(Uint8List bytes);
  void close();
}

// ---------------------------------------------------------------- Mac and Linux: the device file

class _FileSerial implements _SerialPort {
  _FileSerial(this._f);

  /// Puts the port in raw mode first, so no byte is changed on the way (a
  /// 0x0A would otherwise go out as 0x0D 0x0A).
  static _FileSerial open(String path) {
    // opened first: a Mac puts a port's settings back when the last program
    // holding it lets go, so stty's change only sticks while this holds it
    final f = File(path).openSync(mode: FileMode.writeOnlyAppend);
    final r = Process.runSync('/bin/stty', [if (Platform.isMacOS) '-f' else '-F', path, 'raw', '-echo', '250000']);
    if (r.exitCode != 0) {
      // some drivers refuse that speed. The Pro ignores the speed anyway, raw is what matters.
      Process.runSync('/bin/stty', [if (Platform.isMacOS) '-f' else '-F', path, 'raw', '-echo']);
    }
    return _FileSerial(f);
  }

  final RandomAccessFile _f;

  @override
  void write(Uint8List bytes) => _f.writeFromSync(bytes);

  @override
  void close() => _f.closeSync();
}

// ---------------------------------------------------------------- Windows: kernel32

final _createFile = kernel32
    .lookupFunction<
      IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
      int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int)
    >('CreateFileW');
final _writeFile = kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('WriteFile');
final _readFile = kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
    >('ReadFile');
final _setCommTimeouts = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('SetCommTimeouts');
final _purgeComm = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('PurgeComm');
final _closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _queryDosDevice = kernel32.lookupFunction<Uint32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32), int Function(Pointer<Uint16>, Pointer<Uint16>, int)>(
  'QueryDosDeviceW',
);

/// COM1, COM2..., from the list of DOS device names.
List<String> _winComPorts() => _winComPortsIn(65536) ?? _winComPortsIn(1 << 21) ?? const [];

/// The COM ports, read with room for [chars] characters of names. Null when they didn't fit.
List<String>? _winComPortsIn(int chars) {
  final buf = winAlloc<Uint16>(chars * 2);
  try {
    final n = _queryDosDevice(nullptr, buf, chars);
    if (n == 0) return null;
    final all = buf.asTypedList(n);
    final names = <String>[];
    var start = 0;
    for (var i = 0; i < n; i++) {
      if (all[i] != 0) continue;
      if (i > start) names.add(String.fromCharCodes(all.sublist(start, i)));
      start = i + 1;
    }
    final com = names.where((s) => RegExp(r'^COM\d+$').hasMatch(s)).toList()..sort((a, b) => int.parse(a.substring(3)).compareTo(int.parse(b.substring(3))));
    return com;
  } finally {
    winFree(buf);
  }
}

class _WinSerial implements _SerialPort {
  _WinSerial(this._h);

  static const _genericRead = 0x80000000, _genericWrite = 0x40000000, _openExisting = 3;

  /// Opens COMn, with reads and writes that give up after [timeoutMs].
  static _WinSerial open(String port, {int timeoutMs = 200}) {
    final path = toWide(r'\\.\' + port);
    try {
      final h = _createFile(path, _genericRead | _genericWrite, 0, nullptr, _openExisting, 0, 0);
      if (h == -1 || h == 0) throw const FileSystemException('in use by another program, or not there');
      final t = winAlloc<Uint32>(20);
      try {
        t.asTypedList(5).setAll(0, [0, 0, timeoutMs, 0, timeoutMs]); // a read returns what came within timeoutMs
        _setCommTimeouts(h, t);
      } finally {
        winFree(t);
      }
      _purgeComm(h, 0x000F);
      return _WinSerial(h);
    } finally {
      winFree(path);
    }
  }

  /// True when an Enttec Pro answers on [port].
  static bool probe(String port) {
    _WinSerial s;
    try {
      s = open(port, timeoutMs: 150);
    } on Object {
      return false;
    }
    try {
      s.write(enttecSerialRequest);
      final got = <int>[];
      for (var i = 0; i < 3 && !isEnttecSerialReply(got); i++) {
        got.addAll(s.read(64));
      }
      return isEnttecSerialReply(got);
    } on Object {
      return false;
    } finally {
      s.close();
    }
  }

  int _h;

  @override
  void write(Uint8List bytes) {
    final buf = winAlloc<Uint8>(bytes.length), done = winAlloc<Uint32>(4);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      if (_writeFile(_h, buf, bytes.length, done, nullptr) == 0 || done.value != bytes.length) {
        throw const FileSystemException('the write did not go through');
      }
    } finally {
      winFree(buf);
      winFree(done);
    }
  }

  List<int> read(int max) {
    final buf = winAlloc<Uint8>(max), done = winAlloc<Uint32>(4);
    try {
      if (_readFile(_h, buf, max, done, nullptr) == 0) return const [];
      return List.of(buf.asTypedList(done.value));
    } finally {
      winFree(buf);
      winFree(done);
    }
  }

  @override
  void close() {
    if (_h == 0) return;
    _closeHandle(_h);
    _h = 0;
  }
}
