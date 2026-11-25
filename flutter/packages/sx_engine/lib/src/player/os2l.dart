import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'win32.dart';

/// VirtualDJ's OS2L: it connects over TCP and sends JSON objects one after
/// another, with or without anything between them. Every complete object
/// goes to [onMessage].
///
/// Port of `StartOs2l`, `Os2lAccept`, `Os2lRead` and `StopOs2l`. The
/// listener runs on the player's isolate, so a beat lands between two frames.
class Os2lListener {
  Os2lListener._(this.onMessage);

  /// Listens on [port]. With [announce], tells the network about it through
  /// Bonjour as `_os2l._tcp`, like ShowXpress does, so VirtualDJ finds it.
  /// Never throws: a problem ends up in [err].
  static Future<Os2lListener> start(int port, {required bool announce, required void Function(String json) onMessage}) async {
    final l = Os2lListener._(onMessage);
    try {
      l._server = await _bind(port);
    } on SocketException {
      l.err = 'port $port is in use';
      return l;
    }
    l.port = port;
    if (announce) l.err = _Bonjour.register(port, (sd) => l._mdns = sd);
    l._server!.listen(l._serve);
    return l;
  }

  static Future<ServerSocket> _bind(int port) async {
    try {
      return await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false);
    } on SocketException {
      return ServerSocket.bind(InternetAddress.anyIPv4, port);
    }
  }

  final void Function(String json) onMessage;
  ServerSocket? _server;
  int _mdns = 0;
  final _clients = <Socket>{};

  /// The port while listening, else 0.
  int port = 0;

  /// What went wrong, '' when nothing did.
  String err = '';

  /// VirtualDJ's address while it is connected, else ''.
  String peer = '';

  void _serve(Socket c) {
    final who = c.remoteAddress.address.replaceAll('::ffff:', '');
    _clients.add(c);
    peer = who;
    final acc = StringBuffer();
    c
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (chunk) {
            acc.write(chunk);
            final rest = splitJsonObjects(acc.toString(), onMessage);
            acc.clear();
            if (rest != null) acc.write(rest);
          },
          onDone: () => _gone(c),
          onError: (Object _) => _gone(c),
          cancelOnError: true,
        );
  }

  void _gone(Socket c) {
    if (!_clients.remove(c)) return;
    c.destroy();
    if (_clients.isEmpty) peer = '';
  }

  Future<void> stop() async {
    await _server?.close();
    for (final c in _clients.toList()) {
      _gone(c);
    }
    if (_mdns != 0) _Bonjour.deallocate(_mdns);
    _mdns = 0;
  }
}

/// Finds the complete JSON objects in [txt] and hands each to [onObject].
/// Returns the start of an unfinished object to keep for the next read, or
/// null. Port of the scanner in `Os2lRead`.
String? splitJsonObjects(String txt, void Function(String json) onObject) {
  var depth = 0, st = -1;
  var q = false, esc = false;
  for (var i = 0; i < txt.length; i++) {
    final ch = txt[i];
    if (q) {
      if (esc) {
        esc = false;
      } else if (ch == r'\') {
        esc = true;
      } else if (ch == '"') {
        q = false;
      }
      continue;
    }
    if (ch == '"' && depth > 0) {
      q = true;
      continue;
    }
    if (ch == '{') {
      if (depth == 0) st = i;
      depth++;
    } else if (ch == '}' && depth > 0) {
      depth--;
      if (depth == 0) {
        onObject(txt.substring(st, i + 1));
        st = -1;
      }
    }
  }
  return depth > 0 && st >= 0 && txt.length - st < 65536 ? txt.substring(st) : null;
}

/// Bonjour's `dnssd.dll` on Windows. Not run on real hardware.
abstract final class _Bonjour {
  /// Announces [port]. Returns '' or what went wrong, as the old player put it.
  static String register(int port, void Function(int sd) keep) {
    if (!Platform.isWindows) return 'Bonjour is not installed';
    try {
      final lib = DynamicLibrary.open('dnssd.dll');
      final reg = lib
          .lookupFunction<
            Int32 Function(
              Pointer<IntPtr>,
              Uint32,
              Uint32,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Void>,
              Pointer<Void>,
              Uint16,
              Uint16,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
            ),
            int Function(
              Pointer<IntPtr>,
              int,
              int,
              Pointer<Uint8>,
              Pointer<Uint8>,
              Pointer<Void>,
              Pointer<Void>,
              int,
              int,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
            )
          >('DNSServiceRegister');
      final sd = winAlloc<IntPtr>(8), name = _ascii('SX Studio'), type = _ascii('_os2l._tcp');
      try {
        // the port in network byte order
        final netPort = ((port & 0xFF) << 8) | ((port >> 8) & 0xFF);
        if (reg(sd, 0, 0, name, type, nullptr, nullptr, netPort, 0, nullptr, nullptr, nullptr) != 0) return 'Bonjour said no';
        keep(sd.value);
        return '';
      } finally {
        winFree(sd);
        winFree(name);
        winFree(type);
      }
    } on ArgumentError {
      return 'Bonjour is not installed';
    }
  }

  static void deallocate(int sd) {
    try {
      DynamicLibrary.open('dnssd.dll').lookupFunction<Void Function(IntPtr), void Function(int)>('DNSServiceRefDeallocate')(sd);
    } on Object {
      // nothing to tidy
    }
  }

  static Pointer<Uint8> _ascii(String s) {
    final b = ascii.encode(s);
    final p = winAlloc<Uint8>(b.length + 1);
    p.asTypedList(b.length + 1).setAll(0, b);
    return p;
  }
}
