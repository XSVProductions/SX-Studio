import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

/// Stands in for Windows. Records the fixes asked for.
class FakeLaptop implements Laptop {
  FakeLaptop([this.f = const LaptopFacts()]);

  LaptopFacts f;
  final fixed = <LaptopFix>[];

  @override
  bool get windows => true;

  @override
  LaptopFacts facts() => f;

  @override
  String fix(LaptopFix x) {
    fixed.add(x);
    return '  CHANGED  ${x.name}';
  }
}

const _m140 = 'Intimidator Hybrid 140SR (19ch)';

/// A show in `<tmp>/LightShows/Show`, so `param.ini` can sit two folders up.
ShowEnv _show({DateTime? now, bool sxOpen = false, String dmxOn = 'yes'}) {
  final top = Directory.systemTemp.createTempSync('sx_pre_');
  addTearDown(() => top.deleteSync(recursive: true));
  final root = p.join(top.path, 'LightShows', 'Show');
  Directory(p.join(root, 'Live')).createSync(recursive: true);
  Directory(p.join(root, 'scenes')).createSync();
  File(p.join(root, 'Live', 'live.ini')).writeAsStringSync('[live]\r\ndmx_on = $dmxOn\r\n');
  File(p.join(root, 'scenes', 'CENTER SPOT.scex')).writeAsStringSync(
    '<Scene><Fixtures>'
    '<Fixture id="11" name="$_m140" model="$_m140"/><Fixture id="12" name="$_m140 #2" model="$_m140"/><Fixture id="13" name="$_m140 #3" model="$_m140"/>'
    '</Fixtures><Steps/></Scene>',
  );
  return ShowEnv(root, now: () => now ?? DateTime(2026, 11, 25, 18, 30), sxRunning: () => sxOpen);
}

PreItem _item(PreReport r, String title) =>
    r.items.firstWhere((i) => i.title.startsWith(title), orElse: () => throw StateError('no item "$title" in ${r.items.map((i) => i.title)}'));

void main() {
  test('time words', () {
    final now = DateTime(2026, 11, 25, 18, 30);
    expect(preAgo(DateTime(2026, 11, 25, 9, 5), now), 'today at 9:05 AM');
    expect(preAgo(DateTime(2026, 11, 25, 0, 15), now), 'today at 12:15 AM');
    expect(preAgo(DateTime(2026, 11, 24, 23, 0), now), 'yesterday');
    expect(preAgo(DateTime(2026, 11, 2, 12), now), '23 days ago (Nov 2)');
  });

  group('show', () {
    test('ShowXpress closed, DMX on, nothing saved yet', () {
      final r = preshowCheck(_show(), const OtherLaptop());
      expect(r.items.map((i) => (i.level, i.title, i.fix?.key)), [
        ('warn', 'ShowXpress is not open yet', 'launch'),
        ('ok', 'DMX output is on in Live', null),
        ('warn', 'Rig Test not done yet', 'tab:rt'),
        ('warn', 'Movers not aimed yet', 'tab:aim'),
        ('info', 'Controller, DMX interface and laptop checks only run on Windows', null),
      ]);
    });

    test('DMX switched off is an error, and an open ShowXpress gets no fix button', () {
      final r = preshowCheck(_show(sxOpen: true, dmxOn: 'NO'), const OtherLaptop());
      expect(_item(r, 'ShowXpress is open').fix, isNull);
      expect(_item(r, 'DMX output is switched OFF').level, 'error');
    });

    test('Rig Test today that matches Tonight\'s Rig, movers aimed today', () {
      final env = _show();
      env.file('rig_test.json').writeAsStringSync('{"saved":"2026-11-25T14:05:00","hung":["11","12"]}');
      env.file('rig_state.json').writeAsStringSync('{"hung":["11","12"]}');
      env.file('df_aim_state.json').writeAsStringSync('{}');
      env.file('df_aim_state.json').setLastModifiedSync(DateTime(2026, 11, 25, 17, 0));
      final r = preshowCheck(env, const OtherLaptop());
      expect(_item(r, 'Rig Test saved').title, 'Rig Test saved today at 2:05 PM');
      expect(_item(r, 'Rig Test saved').detail, '2 movers placed on the trusses.');
      expect(_item(r, "Tonight's Rig matches").detail, '2 of 3 140s hung.');
      expect(_item(r, 'Movers aimed').title, 'Movers aimed today at 5:00 PM');
    });

    test('an old Rig Test and a rig that differs are warnings with a tab to open', () {
      final env = _show();
      env.file('rig_test.json').writeAsStringSync('{"saved":"2026-11-20T14:05:00","hung":["11","12"]}');
      env.file('rig_state.json').writeAsStringSync('{"hung":["11","13"]}');
      final r = preshowCheck(env, const OtherLaptop());
      expect(_item(r, 'Rig Test last saved').title, 'Rig Test last saved 5 days ago (Nov 20)');
      final rig = _item(r, "Tonight's Rig doesn't match");
      expect(rig.detail, 'Different: 140 #2, 140 #3.');
      expect(rig.fix!.key, 'tab:rig');
    });

    test('no rig saved means every 140 is hung', () {
      final env = _show();
      env.file('rig_test.json').writeAsStringSync('{"saved":"2026-11-25T14:05:00","hung":["11"]}');
      final r = preshowCheck(env, const OtherLaptop());
      expect(_item(r, "Tonight's Rig doesn't match").detail, 'Different: 140 #2, 140 #3.');
    });
  });

  group('gear and laptop', () {
    LaptopFacts facts({List<PnpDevice> devices = const [], List<int> tcp = const [], bool vdj = false}) => LaptopFacts(
      devices: devices,
      tcpPorts: tcp,
      virtualDj: vdj,
      power: (line: 'Offline', percent: 64, hasBattery: true),
      sleepAc: 900,
      usbSuspendAc: 1,
      rebootPending: true,
    );

    test('everything missing or wrong', () {
      final r = preshowCheck(_show(), FakeLaptop(facts()));
      expect(_item(r, 'APC mini not found').level, 'error');
      expect(_item(r, 'No DMX interface found').level, 'error');
      expect(_item(r, 'VirtualDJ beat link is off').level, 'info');
      expect(_item(r, 'Running on battery (64%)').level, 'error');
      expect(_item(r, 'Goes to sleep after 15 min on the charger').fix!.key, 'sleep');
      expect(_item(r, 'USB power saving is on').fix!.key, 'usb');
      expect(_item(r, 'Windows wants to restart').fix!.key, 'restart');
    });

    test('devices found by name, maker or USB id', () {
      final devices = <PnpDevice>[
        (name: 'APC mini mk2', instanceId: r'USB\VID_09E8', manufacturer: 'AKAI'),
        (name: 'Some interface', instanceId: r'USB\VID_1069&PID_1040', manufacturer: ''),
        (name: 'USB Serial Converter', instanceId: '', manufacturer: 'FTDI'),
      ];
      final r = preshowCheck(_show(), FakeLaptop(facts(devices: devices)));
      expect(_item(r, 'APC mini is plugged in').level, 'ok');
      expect(_item(r, 'DMX interface is plugged in').detail, 'Some interface, USB Serial Converter');
    });

    test('the beat link follows param.ini two folders above the show', () {
      final env = _show();
      File(p.join(p.dirname(p.dirname(env.root)), 'param.ini')).writeAsStringSync('OS2LENABLE = yes\r\nOS2LPORT = 7400\r\n');
      expect(_item(preshowCheck(env, FakeLaptop(facts(tcp: [7400]))), 'VirtualDJ is connected').level, 'ok');
      expect(_item(preshowCheck(env, FakeLaptop(facts(tcp: [7350], vdj: true))), 'VirtualDJ is running but not connected').level, 'warn');
      expect(_item(preshowCheck(env, FakeLaptop(facts())), 'VirtualDJ is not connected').level, 'info');
    });

    test('all good', () {
      final good = LaptopFacts(power: (line: 'Online', percent: 100, hasBattery: false), sleepAc: 0, usbSuspendAc: 0);
      final r = preshowCheck(_show(), FakeLaptop(good));
      expect(_item(r, 'On the charger').detail, '');
      expect(_item(r, 'Never sleeps on the charger').level, 'ok');
      expect(_item(r, 'USB power saving is off').level, 'ok');
      expect(_item(r, 'No Windows restart waiting').level, 'ok');
    });
  });

  group('fixes', () {
    test('only on Windows', () {
      expect(
        () => preshowFix(const OtherLaptop(), 'sleep'),
        throwsA(isA<ToolError>().having((e) => e.message, 'message', 'Only on Windows. NOTHING was changed.')),
      );
    });

    test('runs the one asked for', () {
      final l = FakeLaptop();
      expect(preshowFix(l, 'usb'), '  CHANGED  usb');
      expect(l.fixed, [LaptopFix.usb]);
      expect(() => preshowFix(l, 'reboot'), throwsA(isA<ToolError>()));
    });
  });
}
