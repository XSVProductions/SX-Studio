import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'preshow_test.dart' show FakeLaptop;

class _FakeSx implements SxApp {
  @override
  bool running = false;

  @override
  Future<ToolResult> launch() async => const ToolResult(ok: true);

  @override
  Future<ToolResult> close({bool force = false}) async => const ToolResult(ok: true);
}

const _liveIni =
    '[live]\r\nmaster_faders = 1\r\n\r\n[master_faders]\r\ncaption_fader0 = MOVEMENTS\r\ntype_fader0 = 1\r\n\r\n'
    '[page1]\r\nname = CHASES\r\nnb_buttons = 1\r\n\r\n[page1_button1]\r\nline = 1\r\ncolumn = 1\r\nname = CHASE.scex\r\ntitle = CHASE\r\nmasterspeedfader = 7\r\n'
    'trigger_midi_device = 0\r\ntrigger_midi_channel = 1\r\ntrigger_midi_type = 0\r\ntrigger_midi_note = 5\r\n';

void main() {
  late Directory show;
  late _FakeSx sx;
  late FakeLaptop laptop;
  late Engine engine;
  late SxClient client, phone;

  setUp(() async {
    show = Directory.systemTemp.createTempSync('sx_hroutes_');
    Directory('${show.path}/Live').createSync();
    Directory('${show.path}/scenes').createSync();
    File('${show.path}/Live/live.ini').writeAsStringSync(_liveIni);
    File('${show.path}/fixtures.ini').writeAsStringSync('');
    File('${show.path}/scenes/CENTER SPOT.scex').writeAsStringSync('<Scene><Fixtures/><Steps/></Scene>');
    File('${show.path}/scenes/CHASE.scex').writeAsStringSync('<Scene><Fixtures/><Steps/></Scene>');
    sx = _FakeSx();
    laptop = FakeLaptop();
    engine = Engine(
      EngineConfig(port: 0, phonePort: 0, token: 'secret', showPath: show.path),
      sx: sx,
    )..provide<Laptop>(laptop);
    await engine.start();
    client = SxClient(Uri.parse('http://127.0.0.1:${engine.port}'), token: 'secret');
    // a paired phone, on the network port
    engine.phones.newPin();
    final key = engine.phones.pair(engine.phones.pin);
    await engine.setPhoneListener(true);
    phone = SxClient(Uri.parse('http://127.0.0.1:${engine.phonePort}'), token: key);
  });

  tearDown(() async {
    client.close();
    phone.close();
    await engine.stop();
    show.deleteSync(recursive: true);
  });

  group('pre-show fixes', () {
    test('a phone can restart the laptop, as the old server let it', () async {
      expect((await phone.preshowFix('restart')).ok, isTrue);
      expect((await phone.preshowFix('RESTART')).ok, isTrue);
      expect(laptop.fixed, [LaptopFix.restart, LaptopFix.restart]);
    });

    test('the laptop can, and a phone can do the power settings', () async {
      expect((await client.preshowFix('restart')).ok, isTrue);
      expect((await phone.preshowFix('sleep')).ok, isTrue);
      expect(laptop.fixed, [LaptopFix.restart, LaptopFix.sleep]);
    });

    test('anything else is refused before it reaches the laptop', () async {
      expect((await client.preshowFix('shutdown')).error, 'Unknown fix.');
      expect(laptop.fixed, isEmpty);
    });
  });

  group('health', () {
    test('check, fix, conflict, revert anyway', () async {
      final report = await client.health();
      final fix = report.issues.singleWhere((i) => i.kind == 'speed').fix!;
      expect((await client.healthFix(fix.key)).ok, isTrue);
      final id = (await client.health()).applied.single.id;

      // Change the key again: the revert is refused with what changed.
      final ini = File('${show.path}/Live/live.ini');
      ini.writeAsStringSync(ini.readAsStringSync().replaceFirst('masterspeedfader = 0', 'masterspeedfader = 3'));
      final refused = await client.healthRevert(id);
      expect(refused.result.ok, isTrue);
      expect(refused.conflict, ["masterspeedfader of 'CHASE' was changed again"]);

      final forced = await client.healthRevert(id, force: true);
      expect(forced.conflict, isEmpty);
      expect(forced.result.out, contains('reverted'));
      expect(ini.readAsStringSync(), _liveIni);
    });

    test('the 251 colour fix reaches the tool (the old server refused its key)', () async {
      expect((await client.healthFix('color251|page1_button1')).error, isNot('Unknown fix.'));
    });

    test('ids that are not 8 hex digits are refused', () async {
      expect((await client.healthRevert('../../x')).result.error, 'Unknown fix.');
      expect((await client.healthKeep('abc')).error, 'Unknown fix.');
    });

    test('a fix made while ShowXpress is open waits in the queue under its own key', () async {
      sx.running = true;
      await client.status();
      final r = await client.healthFix('speed|page1_button1');
      expect(r.extra['queued'], isTrue);
      expect((await client.status()).queue.items.single.key, 'fix-speed|page1_button1');
    });
  });

  group('apc', () {
    test('preview and a move', () async {
      final p = await client.apc();
      expect(p.pads.single.note, 5);
      final r = await client.apcApply([const ApcChange(sec: 'page1_button1', title: 'CHASE', note: 9)]);
      expect(r.out, contains('moved: CHASE (CHASES) -> row 7, column 2  (note 5 -> 9)'));
    });

    test('the old server checks', () async {
      Future<String> send(Object changes) async => (await client.run('/api/apc/apply', {'changes': changes})).error;
      expect(await send([]), 'Nothing valid to save.');
      expect(
        await send([
          {'sec': 'page1_button1', 'title': 'CHASE', 'note': 64},
        ]),
        'Nothing valid to save.',
      );
      expect(
        await send([
          {'sec': 'page1_button1', 'title': 'CHASE', 'note': 5, 'on': 3},
        ]),
        'Nothing valid to save.',
      );
      expect(
        await send([
          {'sec': 'live', 'title': 'CHASE', 'note': 5},
        ]),
        'Nothing valid to save.',
      );
    });
  });
}
