import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/src/dmx/artnet.dart';
import 'package:sx_engine/src/dmx/dmx_output.dart';
import 'package:sx_engine/src/dmx/enttec_pro.dart';
import 'package:sx_engine/src/dmx/output_settings.dart';
import 'package:test/test.dart';

Uint8List frameWith(Map<int, int> ch) {
  final f = Uint8List(dmxFrameSize);
  ch.forEach((c, v) => f[c - 1] = v);
  return f;
}

void main() {
  group('Enttec DMX USB Pro', () {
    test('the DMX message: 0x7E, label 6, length 513, start code 0, 512 channels, 0xE7', () {
      final m = enttecDmxPacket(frameWith({1: 255, 2: 10, 512: 7}));
      expect(m.length, 518);
      expect(m.sublist(0, 5), [0x7E, 6, 0x01, 0x02, 0]);
      expect(m[5], 255);
      expect(m[6], 10);
      expect(m[5 + 511], 7);
      expect(m.last, 0xE7);
    });

    test('fewer channels make a shorter message', () {
      final m = enttecDmxPacket(frameWith({1: 1}), channels: 24);
      expect(m.length, 24 + 6);
      expect(m.sublist(0, 4), [0x7E, 6, 25, 0]);
      expect(m.last, 0xE7);
    });

    test("a Pro's answer to the serial number question is recognized, other bytes are not", () {
      expect(enttecSerialRequest, [0x7E, 10, 0, 0, 0xE7]);
      expect(isEnttecSerialReply([0x7E, 10, 4, 0, 1, 2, 3, 4, 0xE7]), isTrue);
      expect(isEnttecSerialReply([0, 0, 0x7E, 10, 4, 0, 1, 2, 3, 4, 0xE7]), isTrue);
      expect(isEnttecSerialReply([0x7E, 10, 0, 0, 0xE7]), isFalse); // our own question echoed back
      expect(isEnttecSerialReply(const []), isFalse);
    });
  });

  group('finding the Enttec', () {
    test('on Windows the first port that answers as a Pro', () {
      final asked = <String>[];
      final p = pickEnttecPort(['COM3', 'COM5', 'COM7'], probe: (x) => (asked..add(x)).last == 'COM5');
      expect(p, 'COM5');
      expect(asked, ['COM3', 'COM5']); // stops at the Pro
      expect(pickEnttecPort(['COM3'], probe: (_) => false), isNull);
    });

    test('on a Mac by its name, else the only USB serial port', () {
      expect(pickEnttecPort(['/dev/cu.usbmodem1', '/dev/cu.usbserial-EN123456']), '/dev/cu.usbserial-EN123456');
      expect(pickEnttecPort(['/dev/cu.usbserial-A1']), '/dev/cu.usbserial-A1');
      expect(pickEnttecPort(['/dev/cu.usbserial-A1', '/dev/cu.usbmodem1']), isNull);
    });

    test('a set port is used as it is', () {
      expect(enttecPortToOpen(' COM9 ', const [], 'COM5'), (port: 'COM9', gone: false));
    });

    test('found once, it is opened again without asking the other ports', () {
      expect(enttecPortToOpen('', ['COM3', 'COM5'], 'COM5'), (port: 'COM5', gone: false));
      expect(enttecPortToOpen('', ['COM3', 'COM5'], null), (port: null, gone: false)); // never found: search
    });

    test('unplugged after it was found: wait for its port, no search', () {
      expect(enttecPortToOpen('', ['COM3'], 'COM5'), (port: null, gone: true));
    });
  });

  group('Art-Net', () {
    test('an ArtDmx packet', () {
      final data = Uint8List(512)
        ..[0] = 255
        ..[511] = 9;
      final m = artDmxPacket(data, universe: 0x1234, sequence: 7);
      expect(String.fromCharCodes(m.sublist(0, 7)), 'Art-Net');
      expect(m.sublist(7, 18), [0, 0x00, 0x50, 0, 14, 7, 0, 0x34, 0x12, 0x02, 0x00]);
      expect(m.length, 18 + 512);
      expect(m[18], 255);
      expect(m.last, 9);
    });

    test('an odd channel count is padded to even', () {
      expect(artDmxPacket(Uint8List(3), universe: 0).length, 18 + 4);
    });

    test('sends each universe that changed, and nothing again until it changes or a second passes', () async {
      final rx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final got = <Uint8List>[];
      rx.listen((ev) {
        if (ev == RawSocketEvent.read) {
          final d = rx.receive();
          if (d != null) got.add(d.data);
        }
      });
      final out = await ArtNetDmx.open(host: '127.0.0.1', first: 3, count: 2, port: rx.port);
      expect(out.name, 'Art-Net to 127.0.0.1, universe 3 to 4');
      final f = frameWith({1: 200, 513: 50});
      out.send(f);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, hasLength(2));
      expect(got[0][14], 3); // universe 3
      expect(got[0][18], 200);
      expect(got[1][14], 4);
      expect(got[1][18], 50);
      expect(got[1][12], greaterThan(got[0][12])); // sequence counts up
      out.send(f);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, hasLength(2));
      out.send(frameWith({1: 200, 513: 51}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, hasLength(3));
      expect(got[2][14], 4);
      await out.close();
      rx.close();
    });

    test('a host that is not an IP address is refused with a message', () async {
      expect(() => ArtNetDmx.open(host: 'my node', first: 0, count: 1), throwsA(isA<DmxError>()));
    });
  });

  group('several outputs at once', () {
    test('every frame goes to each, and the name names both', () async {
      final dir = Directory.systemTemp.createTempSync('sx_multi');
      final a = '${dir.path}/a.txt', b = '${dir.path}/b.txt';
      final out = await openDmx(MultiDmxSpec([FakeDmxSpec(a), FakeDmxSpec(b)]));
      expect(out.name, 'test interface + test interface');
      out.send(frameWith({5: 99}));
      expect(File(a).readAsStringSync(), contains('5=99'));
      expect(File(b).readAsStringSync(), contains('5=99'));
      expect(dmxEnded(out), isFalse);
      await out.close();
      dir.deleteSync(recursive: true);
    });

    test('the Chauvet part is found inside a combination', () {
      const efk = EfkDmxSpec('C:/ShowXpress');
      expect(efkPart(const MultiDmxSpec([efk, ArtNetSpec()])), same(efk));
      expect(efkPart(const ArtNetSpec()), isNull);
      expect(isRealDmx(const MultiDmxSpec([FakeDmxSpec(), ArtNetSpec()])), isTrue);
      expect(isRealDmx(const FakeDmxSpec()), isFalse);
    });
  });

  group('the setting', () {
    const chauvet = EfkDmxSpec('C:/ShowXpress');

    test('the default is the Chauvet box, as before', () {
      final dir = Directory.systemTemp.createTempSync('sx_out');
      final f = dmxOutputFile(dir.path);
      expect(readDmxOutput(f).kind, DmxOutputKind.chauvet);
      f.writeAsStringSync('not json');
      expect(readDmxOutput(f).kind, DmxOutputKind.chauvet);
      expect(dmxSpecFor(readDmxOutput(f), chauvet), same(chauvet));
      dir.deleteSync(recursive: true);
    });

    test('saved and read back, and each kind gives its outputs', () {
      final dir = Directory.systemTemp.createTempSync('sx_out');
      final f = dmxOutputFile(dir.path);
      const s = DmxOutputSettings(kind: DmxOutputKind.chauvetArtnet, artnetHost: '2.0.0.10', artnetFirst: 1, artnetCount: 2);
      writeDmxOutput(f, s);
      expect(readDmxOutput(f), s);
      final spec = dmxSpecFor(s, chauvet) as MultiDmxSpec;
      expect(spec.parts.first, same(chauvet));
      final art = spec.parts.last as ArtNetSpec;
      expect((art.host, art.first, art.count), ('2.0.0.10', 1, 2));
      expect(
        dmxSpecFor(const DmxOutputSettings(kind: DmxOutputKind.enttec, enttecPort: 'COM5'), chauvet),
        isA<EnttecProSpec>().having((e) => e.port, 'port', 'COM5'),
      );
      expect(dmxSpecFor(const DmxOutputSettings(kind: DmxOutputKind.enttecArtnet), chauvet), isA<MultiDmxSpec>());
      dir.deleteSync(recursive: true);
    });

    test('out-of-range numbers from a hand-edited file are brought back in range', () {
      final s = DmxOutputSettings.fromJson({'kind': 'artnet', 'artnetFirst': -5, 'artnetCount': 99});
      expect((s.artnetFirst, s.artnetCount), (0, 16));
      expect(DmxOutputSettings.fromJson({'kind': 'nonsense'}).kind, DmxOutputKind.chauvet);
    });
  });
}
