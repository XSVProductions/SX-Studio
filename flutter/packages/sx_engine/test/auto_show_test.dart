import 'dart:convert';
import 'dart:math';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'sx_test_show.dart';

/// A player stand-in that records what the Auto Show sent.
class _FakePlayer implements AutoPlayerLink {
  @override
  var playing = true;
  var bpm = 128.0;
  final on = <String>{};
  final sent = <String>[];

  static const _slots = {'CIRCLE': 'page1_button1', 'FIGURE 8': 'page1_button2', 'RED': 'page2_button1', 'BLUE': 'page2_button2'};

  @override
  PlayerBeat? beat() => playing ? PlayerBeat(bpm: bpm, src: 'tap', onSlots: on) : null;

  @override
  void titleOn(String title) {
    sent.add('ton $title');
    on.add(_slots[title]!);
  }

  @override
  void titleOff(String title) {
    sent.add('toff $title');
    on.remove(_slots[title]);
  }

  @override
  void sync() => sent.add('sync');

  @override
  void setBpm(double bpm) => sent.add('bpm $bpm');
}

String _looks(List<Map<String, Object>> looks, {int bpm = 120, String order = 'order', String stop = 'keep', bool clean = false}) =>
    jsonEncode({'bpm': bpm, 'order': order, 'stop': stop, 'clean': clean, 'looks': looks});

Map<String, Object> _look(String id, String name, List<String> titles, {int bars = 1, bool on = true}) => {
  'id': id,
  'name': name,
  'bars': bars,
  'on': on,
  'titles': titles,
};

void main() {
  late SxTestShow t;
  late AutoShow auto;
  var now = 0.0;
  _FakePlayer? player;

  setUp(() async {
    t = await SxTestShow.create();
    now = 0;
    player = null;
    auto = AutoShow(show: t.env, sxOpen: () => t.open, player: () => player, clock: () => now, random: Random(7), timer: false);
  });

  tearDown(() async {
    await auto.stop();
    await t.dispose();
  });

  /// Moves the clock on and runs one pass of the loop.
  Future<void> at(double ms) async {
    now = ms;
    await auto.tick();
  }

  final presses = <String>['BUTTON_PRESS|', 'BUTTON_RELEASE|'];
  List<String> cmds() => [
    for (final l in t.sx.log)
      if (presses.any(l.startsWith)) l,
  ];

  // At 120 BPM a bar is 2000 ms.
  final two = [
    _look('aaaaaaaa', 'Circle red', ['CIRCLE', 'RED']),
    _look('bbbbbbbb', 'Eight red', ['FIGURE 8', 'RED'], bars: 2),
  ];

  test('presses the first look, then the next one when its bars are up', () async {
    t.writeLooks(_looks(two));
    final r = await auto.start();
    expect(r.ok, isTrue, reason: r.error);
    expect(r.status!.name, 'Circle red');
    expect(r.status!.next, 'Eight red');
    expect(t.sx.pressed, ['CIRCLE', 'RED']);

    await at(1999);
    expect(auto.status()!.lookId, 'aaaaaaaa');
    expect(auto.status()!.beat, 4);
    t.sx.log.clear();
    await at(2000);
    expect(auto.status()!.lookId, 'bbbbbbbb');
    expect(cmds(), ['BUTTON_RELEASE|CIRCLE', 'BUTTON_PRESS|FIGURE 8'], reason: 'RED stays on, it is in both looks');
    expect(auto.status()!.bars, 2);
  });

  test('a late tick keeps counting on the beat', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    await at(2300);
    // the second look started at 2000, not 2300
    expect(auto.status()!.msLeft, 4000 - 300);
  });

  test('a swap page plays one button at a time, so only the last is pressed', () async {
    t.writeLooks(
      _looks([
        _look('aaaaaaaa', 'Both', ['CIRCLE', 'FIGURE 8', 'BLUE']),
      ]),
    );
    await auto.start();
    expect(t.sx.pressed, ['FIGURE 8', 'BLUE']);
  });

  test('hold stays on the look, resume starts it again from bar 1', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    auto.command(AutoCmd.hold);
    await at(5000);
    expect(auto.status()!.lookId, 'aaaaaaaa');
    expect(auto.status()!.msLeft, -1);
    auto.command(AutoCmd.resume);
    await at(6000);
    expect(auto.status()!.lookId, 'aaaaaaaa');
    expect(auto.status()!.msLeft, 1000);
  });

  test('a new BPM keeps the place in the look', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    await at(1000); // half way through one bar at 120
    auto.command(AutoCmd.bpm, '60');
    await auto.tick();
    // half a bar at 60 BPM is 2000 ms
    expect(auto.status()!.msLeft, 2000);
    expect(auto.status()!.bpm, 60);
  });

  test('next, go and back', () async {
    t.writeLooks(
      _looks([
        ...two,
        _look('cccccccc', 'Blue', ['BLUE']),
      ]),
    );
    await auto.start();
    auto.command(AutoCmd.next);
    await auto.tick();
    expect(auto.status()!.lookId, 'bbbbbbbb');
    auto.command(AutoCmd.go, 'cccccccc');
    await auto.tick();
    expect(auto.status()!.lookId, 'cccccccc');
    expect(t.sx.pressed, ['BLUE']);
    auto.command(AutoCmd.prev);
    await auto.tick();
    expect(auto.status()!.lookId, 'bbbbbbbb');
  });

  test('a Next while a press is under way is not lost', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    auto.command(AutoCmd.next); // starts pressing look 2
    auto.command(AutoCmd.next); // back to look 1 before that press is done
    await auto.tick();
    await at(1);
    expect(auto.status()!.lookId, 'aaaaaaaa');
    expect(t.sx.pressed, ['CIRCLE', 'RED']);
  });

  test('shuffle plays every look once per round and never one twice in a row', () async {
    final four = [
      for (final (i, x) in ['CIRCLE', 'FIGURE 8', 'RED', 'BLUE'].indexed) _look('0000000$i', x, [x]),
    ];
    t.writeLooks(_looks(four, order: 'shuffle'));
    await auto.start();
    final played = [auto.status()!.lookId];
    for (var k = 1; k <= 8; k++) {
      await at(k * 2000.0);
      played.add(auto.status()!.lookId);
    }
    for (var i = 1; i < played.length; i++) {
      expect(played[i], isNot(played[i - 1]));
    }
    expect(played.sublist(1, 4).toSet().length, 3, reason: 'the rest of the first round, each once');
  });

  test('waits while ShowXpress is closed and presses again when it opens', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    t.open = false;
    await at(2500);
    expect(auto.status()!.error, 'ShowXpress is closed - waiting for it (the looks keep counting).');
    expect(auto.status()!.applied, isFalse);
    // a fresh ShowXpress has nothing pressed
    for (final b in t.sx.buttons) {
      b.pressed = false;
    }
    t.open = true;
    await at(5000);
    expect(auto.status()!.applied, isTrue);
    expect(auto.status()!.error, '');
    expect(t.sx.pressed, ['FIGURE 8', 'RED']);
  });

  test('"turn the look off" releases its buttons on stop, "clean" clears the rest at start', () async {
    t.sx.buttons.firstWhere((b) => b.title == 'BLUE').pressed = true;
    t.sx.buttons.firstWhere((b) => b.title == 'RIG ID').pressed = true;
    t.writeLooks(_looks(two, stop: 'off', clean: true));
    await auto.start();
    expect(t.sx.pressed, ['CIRCLE', 'RED', 'RIG ID'], reason: 'BLUE off, the SETUP page is left alone');
    final s = await auto.stop();
    expect(s!.running, isFalse);
    expect(t.sx.pressed, ['RIG ID']);
  });

  test('refuses to start without the remote or without a look', () async {
    t.writeLooks(_looks([_look('aaaaaaaa', 'Empty', [])]));
    var r = await auto.start();
    expect(r.ok, isFalse);
    expect(r.error, 'No look to play - add a look with at least one button and switch it on.');
    expect(auto.status()!.running, isFalse);

    t.writeLooks(_looks(two));
    ShowEnv(t.root)
        .file('Live/live.ini')
        .writeAsStringSync(ShowEnv(t.root).file('Live/live.ini').readAsStringSync().replaceFirst('allow_live_mobile = yes', 'allow_live_mobile = no'));
    r = await auto.start();
    expect(r.error, 'The ShowXpress remote is off - turn it on first.');
  });

  test('on the SX Player: presses by title over its link and follows its tempo', () async {
    final pl = player = _FakePlayer();
    t.writeLooks(_looks(two));
    final r = await auto.start();
    expect(r.status!.target, 'player');
    expect(r.status!.bpm, 128);
    expect(pl.sent, ['ton CIRCLE', 'ton RED']);
    expect(t.sx.log, isEmpty, reason: 'ShowXpress is not used');
    pl.bpm = 64;
    await at(600);
    expect(auto.status()!.bpm, 64);
    auto.command(AutoCmd.sync);
    expect(pl.sent.last, 'sync');
  });

  test('saved settings are picked up while playing', () async {
    t.writeLooks(_looks(two));
    await auto.start();
    t.writeLooks(
      _looks([
        _look('cccccccc', 'Blue', ['BLUE']),
      ]),
    );
    auto.reload();
    await at(1);
    expect(auto.status()!.name, 'Blue');
    expect(t.sx.pressed, ['BLUE']);
  });

  group('pending presses', () {
    late PendingPresses pend;
    var clock = DateTime(2026);
    var live = false;

    setUp(() {
      live = false;
      pend = PendingPresses(
        press: (titles) => remoteAction(t.env(), RemoteAction.press, titles: titles, solo: true, idle: true),
        sxOpen: () => t.open,
        live: () => live,
        autoRunning: () => auto.running,
        now: () => clock,
        timer: false,
      );
    });

    test('presses once ShowXpress opens', () async {
      t.open = false;
      pend.pressWhenOpen(['FIGURE 8'], 'FIGURE 8');
      await pend.step();
      expect(pend.pending, isTrue);
      t.open = true;
      clock = clock.add(const Duration(seconds: 4));
      await pend.step();
      expect(pend.pending, isFalse);
      expect(pend.last!.ok, isTrue);
      expect(t.sx.pressed, ['FIGURE 8']);
    });

    test('leaves a playing show alone and says so', () async {
      t.sx.buttons.firstWhere((b) => b.title == 'RED').pressed = true;
      pend.pressWhenOpen(['FIGURE 8'], 'CHECK');
      clock = clock.add(const Duration(seconds: 4));
      await pend.step();
      expect(pend.last!.skipped, isTrue);
      expect(pend.last!.playing, ['RED']);
      expect(t.sx.pressed, ['RED']);
    });

    test('waits for live aim, and gives up after its time', () async {
      live = true;
      pend.pressWhenOpen(['FIGURE 8'], 'CHECK', within: const Duration(seconds: 10));
      clock = clock.add(const Duration(seconds: 4));
      await pend.step();
      expect(t.sx.log, isEmpty);
      clock = clock.add(const Duration(seconds: 20));
      await pend.step();
      expect(pend.pending, isFalse);
      expect(pend.last, isNull);
    });
  });
}
