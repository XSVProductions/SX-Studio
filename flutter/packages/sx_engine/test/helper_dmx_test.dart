@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sx_engine/src/dmx/helper_dmx.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

// The Mac's DMX goes through the `sxh_dmx` helper. A shell script stands in
// for it here: it answers like the helper and keeps what it is sent.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sxh_dmx'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String helper(String script) {
    final f = File('${tmp.path}/sxh_dmx')..writeAsStringSync('#!/bin/sh\n$script\n');
    Process.runSync('chmod', ['+x', f.path]);
    return f.path;
  }

  test('sends only the channels that changed, then q', () async {
    final got = File('${tmp.path}/in.txt');
    final out = await HelperDmx.open(helper: helper('echo "OK D512S"\ncat > "${got.path}"'), driverDir: tmp.path);
    expect(out.name, 'D512S');
    final frame = Uint8List(dmxFrameSize)
      ..[0] = 255
      ..[9] = 7;
    out.send(frame);
    out.send(frame);
    frame[9] = 0;
    out.send(frame);
    out.close();
    for (var i = 0; i < 50 && !(got.existsSync() && got.readAsStringSync().contains('q')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(got.readAsLinesSync(), ['b:1:255 b:10:7', 'b:10:0', 'q']);
  });

  test('says when the helper has ended', () async {
    final out = await HelperDmx.open(helper: helper('echo "OK D512S"\nread line'), driverDir: tmp.path);
    expect(out.alive, isTrue);
    out.close();
    for (var i = 0; i < 50 && out.alive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(out.alive, isFalse);
  });

  test('no interface gives the old message', () async {
    await expectLater(
      HelperDmx.open(helper: helper('echo "ERR none"'), driverDir: tmp.path),
      throwsA(isA<DmxError>().having((e) => e.message, 'message', dmxNotFound)),
    );
  });

  test('tells an Intel-only driver from one with Apple Silicon code', () {
    File lib(List<int> bytes) => File('${tmp.path}/efk_hardware.dylib')..writeAsBytesSync(bytes);
    const intel = [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01];
    const arm = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01];
    List<int> both(List<List<int>> cpus) => [
      0xCA,
      0xFE,
      0xBA,
      0xBE,
      0,
      0,
      0,
      cpus.length,
      for (final c in cpus) ...[...c, ...List.filled(16, 0)],
    ];
    expect(intelOnly(lib(intel)), isTrue);
    expect(intelOnly(lib(arm)), isFalse);
    expect(
      intelOnly(
        lib(
          both([
            [1, 0, 0, 7],
          ]),
        ),
      ),
      isTrue,
    );
    expect(
      intelOnly(
        lib(
          both([
            [1, 0, 0, 7],
            [1, 0, 0, 0x0C],
          ]),
        ),
      ),
      isFalse,
    );
    expect(intelOnly(File('${tmp.path}/none.dylib')), isFalse);
  });
}
