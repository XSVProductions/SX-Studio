import 'dart:io';
import 'dart:typed_data';

import 'dmx_output.dart';

// Art-Net: DMX in UDP packets on the network, to an Art-Net node (a box that
// turns it into DMX, like a DMXking eDMX) or to lights that take Art-Net
// themselves. One ArtDmx packet per universe, sent when the universe changed
// and at least once a second (the standard asks for one every 4 seconds at
// most, and many nodes go dark without it).
//
// New in the Flutter app: ShowXpress has no such output from SX Studio. Not
// run with a real node yet.

/// Art-Net's UDP port.
const artNetPort = 6454;

/// One ArtDmx packet: [data] (2 to 512 channels, an even count) for the
/// 15-bit port-address [universe] (0 is the first, often shown as 0:0:0).
/// [sequence] is 1 to 255, counting up, or 0 for none.
Uint8List artDmxPacket(Uint8List data, {required int universe, int sequence = 0}) {
  var n = data.length.clamp(2, 512).toInt();
  if (n.isOdd) n++;
  final out = Uint8List(18 + n);
  out.setAll(0, 'Art-Net'.codeUnits); // out[7] stays 0
  out[8] = 0x00; // OpDmx 0x5000, low byte first
  out[9] = 0x50;
  out[10] = 0; // protocol version 14, high byte first
  out[11] = 14;
  out[12] = sequence & 0xFF;
  out[13] = 0; // physical port
  out[14] = universe & 0xFF; // SubUni: sub-net and universe
  out[15] = (universe >> 8) & 0x7F; // Net
  out[16] = n >> 8; // length, high byte first
  out[17] = n & 0xFF;
  for (var i = 0; i < n && i < data.length; i++) {
    out[18 + i] = data[i];
  }
  return out;
}

/// DMX to Art-Net. SX Studio's universes 1 to [count] go to port-addresses
/// [first] to [first] + [count] - 1, sent to [host] ('' = everyone on the
/// network, by broadcast).
class ArtNetDmx implements DmxOutput {
  ArtNetDmx._(this.name, this._sock, this._to, this._port, this.first, this.count);

  /// Opens a UDP socket. Throws [DmxError] when [host] isn't an address or
  /// the network can't be used.
  static Future<ArtNetDmx> open({required String host, required int first, required int count, int port = artNetPort}) async {
    final h = host.trim();
    final InternetAddress to;
    if (h.isEmpty) {
      to = InternetAddress('255.255.255.255');
    } else {
      final a = InternetAddress.tryParse(h);
      if (a == null || a.type != InternetAddressType.IPv4) throw DmxError('$h is not an IP address like 2.0.0.10. Fix it in Settings > DMX output.');
      to = a;
    }
    final RawDatagramSocket s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      throw DmxError('Art-Net could not use the network: ${e.message}');
    }
    s.broadcastEnabled = true;
    final c = count.clamp(1, 16).toInt();
    final f = first.clamp(0, 0x7FFF - c + 1).toInt();
    final where = h.isEmpty ? 'the whole network' : h;
    return ArtNetDmx._('Art-Net to $where, universe $f${c > 1 ? ' to ${f + c - 1}' : ''}', s, to, port, f, c);
  }

  @override
  final String name;
  final RawDatagramSocket _sock;
  final InternetAddress _to;
  final int _port;

  /// The port-address SX Studio's universe 1 goes to, and how many universes are sent.
  final int first, count;

  final _sent = Uint8List(dmxFrameSize);
  final _lastAt = <int, DateTime>{};
  var _seq = 0;
  bool _closed = false;

  @override
  void send(Uint8List frame) {
    if (_closed) return;
    final now = DateTime.now();
    for (var u = 0; u < count; u++) {
      final from = u * 512;
      var changed = false;
      for (var i = from; i < from + 512; i++) {
        if (frame[i] != _sent[i]) {
          changed = true;
          _sent[i] = frame[i];
        }
      }
      final last = _lastAt[u];
      if (!changed && last != null && now.difference(last) < const Duration(seconds: 1)) continue;
      _lastAt[u] = now;
      _seq = _seq % 255 + 1;
      try {
        _sock.send(artDmxPacket(Uint8List.sublistView(_sent, from, from + 512), universe: first + u, sequence: _seq), _to, _port);
      } on SocketException {
        // no network right now: the next frame tries again
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _sock.close();
  }
}
