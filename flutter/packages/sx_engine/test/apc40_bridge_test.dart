import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/src/apc40/bridge.dart';
import 'package:test/test.dart';

// The APC40 bridge's loop, stepped by hand with a fake APC40 and a fake
// ShowXpress that speaks the remote protocol. Port of `apc40.ps1 -Action Run`.

/// The APC40: what was sent to it, and what it sends.
class FakeMidi implements Apc40Midi {
  var plugged = true;

  /// What `open` answers when plugged in: 0, or a Windows error.
  var openError = 0;
  var opens = 0;
  final sysex_ = <List<int>>[];
  final sent = <(int, int, int)>[];
  final _in = <int>[];

  @override
  var isOpen = false;

  @override
  int open(String name) {
    expect(name, 'APC40');
    opens++;
    if (!plugged) return -1;
    if (openError != 0) return openError;
    isOpen = true;
    return 0;
  }

  @override
  void send(int status, int d1, int d2) => sent.add((status, d1, d2));

  @override
  int sysex(List<int> bytes) {
    sysex_.add(bytes);
    return 0;
  }

  @override
  bool present(String name) => plugged;

  @override
  List<int> take() {
    final l = [..._in];
    _in.clear();
    return l;
  }

  @override
  void close() {
    isOpen = false;
    _in.clear();
  }

  void note(int ch, int n, int vel) => _in.add(0x90 | ch | n << 8 | vel << 16);
  void noteOff(int ch, int n) => _in.add(0x80 | ch | n << 8);
  void cc(int ch, int n, int v) => _in.add(0xB0 | ch | n << 8 | v << 16);

  /// The light of each (status, note), as last sent.
  Map<(int, int), int> get leds => {for (final (s, n, v) in sent) (s, n): v};
  int pad(int n) => leds[(0x90, n)]!;
  int get connLight => leds[(0x90, 82)]!;
  List<int> get trackSelect => [for (var p = 0; p < 8; p++) leds[(0x90 + p, 51)]!];
}

class FakeButton {
  FakeButton(this.title, {this.flash = false, this.color = '#FF0000', this.pressed = false});

  final String title;
  final bool flash;
  final String color;
  bool pressed;
}

/// ShowXpress and its remote.
class FakeSx implements Apc40Sx {
  @override
  var running = true;
  var password = 'pw';
  var faderTypes = <int, String>{0: 'speed', 1: 'dimmer'};

  /// Nothing answers the connection.
  var deaf = false;

  /// Connects, but never says HELLO.
  var mute = false;
  var refuse = false;
  var connects = 0;
  var listXml = '';
  final buttons = <FakeButton>[];
  FakeLink? link;

  @override
  Apc40Remote setup() => (password: password, port: 7348, faderTypes: faderTypes);

  @override
  Future<Apc40SxLink?> connect(int port) async {
    connects++;
    if (deaf) return null;
    return link = FakeLink(this);
  }

  String xml() => listXml.isNotEmpty
      ? listXml
      : '<buttons><page name="P">${[for (final b in buttons) '<button flash="${b.flash ? 1 : 0}" pressed="${b.pressed ? 1 : 0}" color="${b.color}">${const HtmlEscape().convert(b.title)}</button>'].join()}</page></buttons>';
}

class FakeLink implements Apc40SxLink {
  FakeLink(this.sx);

  final FakeSx sx;
  var _inbox = '';
  var closed = false, gone = false;
  final lines = <String>[];

  /// ShowXpress sends [line].
  void say(String line) => _inbox += '$line\r\n';

  @override
  String? read() {
    if (gone) return null;
    final t = _inbox;
    _inbox = '';
    return t;
  }

  @override
  void write(String text) {
    if (closed || gone) throw const SocketException('closed');
    expect(text, endsWith('\r\n'));
    for (final l in text.substring(0, text.length - 2).split('\r\n')) {
      lines.add(l);
      if (l.startsWith('HELLO|')) {
        if (sx.refuse || l.split('|').last != sx.password) {
          say('ERROR|BAD_PASSWORD');
        } else if (!sx.mute) {
          say('HELLO');
        }
      } else if (l == 'BUTTON_LIST') {
        say('BUTTON_LIST|${sx.xml()}');
      } else if (l.startsWith('BUTTON_PRESS|') || l.startsWith('BUTTON_RELEASE|')) {
        for (final b in sx.buttons.where((b) => b.title == l.substring(l.indexOf('|') + 1))) {
          b.pressed = l.startsWith('BUTTON_PRESS|');
        }
      }
    }
  }

  @override
  void close() => closed = true;

  /// What the bridge sent, without the list requests.
  List<String> get acts => [
    for (final l in lines)
      if (l != 'BUTTON_LIST') l,
  ];
  int get lists => lines.where((l) => l == 'BUTTON_LIST').length;
}

/// A bridge with its fakes and a clock that only moves when told.
class Rig {
  Rig({Json? layout, bool noMidi = false}) {
    dir = Directory.systemTemp.createTempSync('apc40_bridge_');
    file = File('${dir.path}/apc40.json');
    if (layout != null) file.writeAsStringSync(jsonEncode(layout));
    bridge = Apc40Bridge(midi: noMidi ? null : midi, sx: sx, layoutFile: file, now: () => t, pause: (d) => t = t.add(d), onStatus: statuses.add);
  }

  late final Directory dir;
  late final File file;
  final midi = FakeMidi();
  final sx = FakeSx();
  late final Apc40Bridge bridge;
  var t = DateTime(2026, 11, 25, 20);
  final statuses = <Apc40Status>[];

  FakeLink get link => sx.link!;
  Apc40Status get status => bridge.status;

  /// Steps the loop every 10 ms, [ms] / 10 times (at least once). The
  /// 200 ms pause after opening the APC40 comes on top.
  Future<void> run(int ms) async {
    for (var i = 0; i < (ms ~/ 10).clamp(1, 1 << 30); i++) {
      await bridge.step();
      t = t.add(const Duration(milliseconds: 10));
    }
  }

  /// Runs until ShowXpress has said HELLO and the list came in.
  Future<void> connect() async {
    await run(50);
    expect(status.sx, 'ok');
  }

  void dispose() => dir.deleteSync(recursive: true);
}

Json page(String name, Map<int, String> pads, [Map<int, (int, int)> colors = const {}]) => {
  'name': name,
  'pads': {for (final e in pads.entries) '${e.key}': e.value},
  'colors': {
    for (final e in colors.entries) '${e.key}': {'on': e.value.$1, 'off': e.value.$2},
  },
};

void main() {
  late Rig r;
  Rig? made;
  tearDown(() {
    made?.dispose();
    made = null;
  });

  Rig rig({Json? layout, bool noMidi = false, List<FakeButton> buttons = const []}) {
    made = r = Rig(layout: layout, noMidi: noMidi);
    r.sx.buttons.addAll(buttons);
    return r;
  }

  final twoPages = {
    'pages': [
      page('One', {0: 'RED', 1: 'FLASH', 2: 'GONE', 3: 'OWN'}, {3: (45, 46)}),
      page('Two', {0: 'GREEN'}),
    ],
  };
  List<FakeButton> buttons() => [
    FakeButton('RED'),
    FakeButton('FLASH', flash: true, color: '#0000FF'),
    FakeButton('OWN'),
    FakeButton('GREEN', color: '#00FF00', pressed: true),
  ];

  group('the APC40', () {
    test('opens in Live mode, waits for it, and lights the page before ShowXpress answers', () async {
      rig(layout: twoPages, buttons: buttons());
      r.sx.deaf = true;
      final t0 = r.t;
      await r.bridge.step();
      expect(r.midi.sysex_, [apc40LiveMode]);
      expect(r.t.difference(t0), const Duration(milliseconds: 200));
      expect(r.status.apc, 'ok');
      expect(r.status.sx, 'starting');
      // assigned pads dim grey, the others dark, page 1 lit, the connection light red
      expect([for (var n = 0; n < 5; n++) r.midi.pad(n)], [1, 1, 1, 1, 0]);
      expect(r.midi.pad(39), 0);
      expect(r.midi.trackSelect, [1, 0, 0, 0, 0, 0, 0, 0]);
      expect(r.midi.connLight, 5);
    });

    test('a light is only sent when it changes', () async {
      rig(layout: twoPages);
      r.sx.deaf = true;
      await r.run(10);
      final n = r.midi.sent.length;
      expect(n, 40 + 8 + 1);
      await r.run(100);
      expect(r.midi.sent.length, n);
    });

    test('not plugged in: missing, tried again every 2 s, and ShowXpress left alone', () async {
      rig(layout: twoPages);
      r.midi.plugged = false;
      await r.run(10);
      expect(r.status.apc, 'missing');
      expect(r.status.sx, 'waiting');
      expect(r.midi.opens, 1);
      await r.run(1980);
      expect(r.midi.opens, 1);
      await r.run(20);
      expect(r.midi.opens, 2);
      expect(r.sx.connects, 0);
      expect(r.midi.sent, isEmpty);
      r.midi.plugged = true;
      await r.run(2000);
      expect(r.status.apc, 'ok');
    });

    test('another program has it: busy, with the old messages, until it is free', () async {
      rig(layout: twoPages);
      r.midi.openError = 4;
      await r.run(10);
      expect(r.status.apc, 'busy');
      expect(r.status.error, "Another program has the APC40 - take it out of ShowXpress's MIDI settings.");
      r.midi.openError = 2;
      await r.run(2000);
      expect(r.status.error, "The APC40 can't be opened (error 2).");
      expect(r.midi.opens, 2);
      r.midi.openError = 0;
      await r.run(2000);
      expect(r.status.apc, 'ok');
      expect(r.status.error, '');
    });

    test('unplugged: noticed within 2 s, ShowXpress let go, and set up again when it is back', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.midi.plugged = false;
      await r.run(2000);
      expect(r.status.apc, 'missing');
      expect(r.midi.isOpen, false);
      expect(r.status.sx, 'waiting');
      expect(r.link.closed, true);
      r.midi.plugged = true;
      r.midi.sent.clear();
      await r.run(2100);
      expect(r.status.apc, 'ok');
      expect(r.midi.sysex_.length, 2);
      // every light sent again
      expect(r.midi.sent.length, greaterThanOrEqualTo(49));
    });
  });

  group('ShowXpress', () {
    test('says hello with the password, reads the list, and lights the pads in their colours', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      expect(r.link.lines.first, 'HELLO|SX Studio APC40|pw');
      expect(r.link.lists, greaterThanOrEqualTo(1));
      expect(r.midi.connLight, 21);
      // RED off: #FF0000 dim 6. FLASH off: #0000FF (hue 240) dim 46. GONE: no button, dark. OWN: its own dim 46.
      expect([for (var n = 0; n < 4; n++) r.midi.pad(n)], [6, 46, 0, 46]);
      r.sx.buttons[0].pressed = true;
      await r.run(2000);
      expect(r.midi.pad(0), 5);
    });

    test('closed: tried again every 3 s', () async {
      rig(layout: twoPages);
      r.sx.running = false;
      await r.run(10);
      expect(r.status.sx, 'closed');
      r.sx.running = true;
      await r.run(2980);
      expect(r.sx.connects, 0);
      await r.run(20);
      expect(r.sx.connects, 1);
    });

    test('no answer to the connection: starting, tried again every 3 s', () async {
      rig(layout: twoPages);
      r.sx.deaf = true;
      await r.run(10);
      expect(r.status.sx, 'starting');
      expect(r.sx.connects, 1);
      await r.run(2990);
      expect(r.sx.connects, 1);
      await r.run(10);
      expect(r.sx.connects, 2);
    });

    test('remote off: no password, the old message', () async {
      rig(layout: twoPages);
      r.sx.password = '';
      await r.run(10);
      expect(r.status.sx, 'off');
      expect(r.status.error, "ShowXpress's remote control is off - turn it on in SX Studio's Auto Show tab.");
      expect(r.sx.connects, 0);
    });

    test('no HELLO within 4 s: closed, tried again 2 s later', () async {
      rig(layout: twoPages);
      r.sx.mute = true;
      await r.run(4000);
      expect(r.status.sx, 'starting');
      expect(r.sx.connects, 1);
      expect(r.link.closed, false);
      await r.run(20);
      expect(r.link.closed, true);
      await r.run(1990);
      expect(r.sx.connects, 1);
      await r.run(10);
      expect(r.sx.connects, 2);
    });

    test('refused: the old message, tried again after 10 s', () async {
      rig(layout: twoPages);
      r.sx.refuse = true;
      await r.run(20);
      expect(r.status.sx, 'refused');
      expect(r.status.error, 'ShowXpress refused the APC40 (ERROR|BAD_PASSWORD). Turn the remote on again from SX Studio.');
      expect(r.link.closed, true);
      await r.run(9980);
      expect(r.sx.connects, 1);
      await r.run(20);
      expect(r.sx.connects, 2);
    });

    test('connection lost: every button off, the pads dim, tried again after 2 s', () async {
      rig(layout: twoPages, buttons: buttons());
      r.sx.buttons[0].pressed = true;
      await r.connect();
      expect(r.midi.pad(0), 5);
      r.link.gone = true;
      await r.run(10);
      expect(r.status.sx, 'lost');
      // the list is kept: pads show their idle colour, and only a title ShowXpress lacks is grey
      expect([for (var n = 0; n < 4; n++) r.midi.pad(n)], [6, 46, 1, 46]);
      expect(r.midi.connLight, 5);
      await r.run(1990);
      expect(r.sx.connects, 1);
      await r.run(10);
      expect(r.sx.connects, 2);
    });

    test('a send that fails loses the connection', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.link.closed = true;
      r.midi.note(0, 0, 127);
      await r.run(10);
      expect(r.status.sx, 'lost');
    });

    test('asks for the list every 2 s, 350 ms after a pad, 400 ms after a press elsewhere, 300 ms after a change', () async {
      rig(layout: twoPages, buttons: buttons());
      // connect (after the APC40's 200 ms), then HELLO: the list at once, and the first poll
      await r.run(20);
      expect(r.link.lists, 2);
      await r.run(1990);
      expect(r.link.lists, 2);
      await r.run(10);
      expect(r.link.lists, 3);
      r.midi.note(0, 0, 127);
      await r.run(350);
      expect(r.link.lists, 3);
      await r.run(10);
      expect(r.link.lists, 4);
      r.link.say('BUTTON_PRESS|GREEN');
      await r.run(400);
      expect(r.link.lists, 4);
      await r.run(10);
      expect(r.link.lists, 5);
      r.link.say('INTERFACE_CHANGE');
      await r.run(300);
      expect(r.link.lists, 5);
      await r.run(10);
      expect(r.link.lists, 6);
    });

    test('presses and releases from elsewhere light the pads at once', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.link.say('BUTTON_PRESS|red');
      await r.run(10);
      expect(r.midi.pad(0), 5);
      r.link.say('BUTTON_RELEASE|RED');
      r.link.say('BEAT_ON');
      await r.run(10);
      expect(r.midi.pad(0), 6);
    });

    test('the list: first of each title (ignoring case), elements without attributes skipped, bad XML ignored', () async {
      rig(
        layout: {
          'pages': [
            page('A', {0: 'dup', 1: 'plain', 2: 'X'}),
          ],
        },
      );
      r.sx.listXml =
          '<buttons><page name="p"><button pressed="1" color="#00FF00">DUP</button><button pressed="0" color="#FF0000">dup</button>'
          '<button>plain</button><button pressed="0"> X </button></page><page>ignored</page></buttons>';
      await r.connect();
      // DUP is the green pressed one, plain is no button, X (padded) is white and idle
      expect([r.midi.pad(0), r.midi.pad(1), r.midi.pad(2)], [21, 0, 1]);
      r.sx.listXml = '<buttons><page';
      r.link.say('BUTTON_LIST|<buttons><page');
      await r.run(10);
      expect(r.midi.pad(0), 21);
    });
  });

  group('pads', () {
    test('a pad toggles its button, and letting go does nothing', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.midi.note(0, 0, 127);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_PRESS|RED');
      expect(r.status.last, 'RED on');
      expect(r.midi.pad(0), 5);
      r.midi.noteOff(0, 0);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_PRESS|RED');
      r.midi.note(0, 0, 100);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_RELEASE|RED');
      expect(r.status.last, 'RED off');
      expect(r.midi.pad(0), 6);
    });

    test('a flash button is held while the pad is (note off, or note on at 0)', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.midi.note(0, 1, 127);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_PRESS|FLASH');
      expect(r.status.last, 'FLASH (held)');
      expect(r.midi.pad(1), 45);
      r.midi.note(0, 1, 0);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_RELEASE|FLASH');
      expect(r.midi.pad(1), 46);
      r.midi.note(0, 1, 127);
      r.midi.noteOff(0, 1);
      await r.run(10);
      expect(r.link.acts.sublist(r.link.acts.length - 2), ['BUTTON_PRESS|FLASH', 'BUTTON_RELEASE|FLASH']);
    });

    test('a title ShowXpress does not have, ShowXpress not connected, and an empty pad', () async {
      rig(layout: twoPages, buttons: buttons());
      r.sx.deaf = true;
      r.midi.note(0, 0, 127);
      await r.run(10);
      expect(r.status.last, "RED - ShowXpress isn't connected");
      r.sx.deaf = false;
      await r.run(3020);
      expect(r.status.sx, 'ok');
      r.midi.note(0, 2, 127);
      await r.run(10);
      expect(r.status.last, 'GONE - not in ShowXpress (renamed or removed?)');
      r.midi.note(0, 30, 127);
      r.midi.note(1, 0, 127); // a pad on another channel is not a pad
      await r.run(10);
      expect(r.status.last, 'GONE - not in ShowXpress (renamed or removed?)');
      expect(r.link.acts.where((l) => l.startsWith('BUTTON_')), isEmpty);
    });

    test('Track Select changes page, lights it, and forgets a held pad without letting it go', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.midi.note(0, 1, 127);
      await r.run(10);
      r.midi.note(1, 51, 127);
      await r.run(10);
      expect(r.bridge.page, 1);
      expect(r.status.page, 2);
      expect(r.status.pageName, 'Two');
      expect(r.midi.trackSelect, [0, 1, 0, 0, 0, 0, 0, 0]);
      expect(r.midi.pad(0), 21); // GREEN, pressed
      expect(r.midi.pad(1), 0);
      r.midi.noteOff(0, 1);
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_PRESS|FLASH');
      // a page that isn't there, and the button's release, change nothing
      r.midi.note(5, 51, 127);
      r.midi.noteOff(2, 51);
      await r.run(10);
      expect(r.bridge.page, 1);
    });
  });

  group('faders', () {
    final faders = {
      'pages': [page('A', {})],
      'faders': {'1': 0, '2': 1, '9': 1},
    };

    test('a speed fader centres on 0, a dimmer goes 0 to 100, the master fader is CC 14', () async {
      rig(layout: faders);
      await r.connect();
      Future<String> move(int ch, int cc, int v) async {
        r.midi.cc(ch, cc, v);
        await r.run(50);
        return r.link.acts.last;
      }

      expect(await move(0, 7, 127), 'FADER_CHANGE|0|99');
      expect(await move(0, 7, 64), 'FADER_CHANGE|0|0');
      expect(await move(0, 7, 0), 'FADER_CHANGE|0|-100');
      expect(await move(0, 7, 32), 'FADER_CHANGE|0|-50');
      expect(await move(1, 7, 127), 'FADER_CHANGE|1|100');
      expect(await move(1, 7, 64), 'FADER_CHANGE|1|50');
      expect(await move(0, 14, 0), 'FADER_CHANGE|1|0');
      final n = r.link.acts.length;
      r.midi.cc(2, 7, 10); // fader 3 is not in the layout
      r.midi.cc(1, 14, 10); // CC 14 only counts on channel 1
      r.midi.cc(0, 8, 10);
      await r.run(50);
      expect(r.link.acts.length, n);
    });

    test('a fader type ShowXpress does not list is a speed fader', () async {
      rig(layout: faders);
      r.sx.faderTypes = {};
      await r.connect();
      r.midi.cc(1, 7, 127);
      await r.run(10);
      expect(r.link.acts.last, 'FADER_CHANGE|1|99');
    });

    test('at most one move per fader every 40 ms, the newest value', () async {
      rig(layout: faders);
      await r.connect();
      r.midi.cc(0, 7, 10);
      await r.run(10);
      r.midi.cc(0, 7, 20);
      r.midi.cc(1, 7, 127);
      await r.run(10);
      r.midi.cc(0, 7, 30);
      await r.run(10);
      expect(r.link.acts.where((l) => l.startsWith('FADER')), ['FADER_CHANGE|0|-85', 'FADER_CHANGE|1|100']);
      await r.run(20);
      expect(r.link.acts.last, 'FADER_CHANGE|0|-54');
    });

    test('moves made before ShowXpress answers are sent once it does', () async {
      rig(layout: faders);
      r.sx.deaf = true;
      r.midi.cc(0, 7, 127);
      await r.run(10);
      r.sx.deaf = false;
      await r.run(3020);
      expect(r.link.acts.last, 'FADER_CHANGE|0|99');
    });

    test('the default faders 1 to 4 move master faders 1 to 4', () async {
      rig();
      await r.connect();
      r.midi.cc(3, 7, 64);
      await r.run(10);
      expect(r.link.acts.last, 'FADER_CHANGE|3|0');
      expect(r.status.pageName, 'Dancefloor');
    });
  });

  group('the layout', () {
    test('read again when the file changes, back to page 1 when the page is gone', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.midi.note(1, 51, 127);
      await r.run(10);
      expect(r.status.page, 2);
      r.file.writeAsStringSync(
        jsonEncode({
          'pages': [
            page('New', {5: 'RED'}),
          ],
        }),
      );
      r.file.setLastModifiedSync(DateTime(2030));
      await r.run(2000);
      expect(r.status.pageName, 'New');
      expect(r.status.page, 1);
      expect(r.midi.pad(5), 6);
      expect(r.midi.pad(0), 0);
    });

    test('reload reads it at once, and a broken file keeps the defaults with the old message', () async {
      rig(layout: twoPages);
      r.sx.deaf = true;
      await r.run(10);
      r.file.writeAsStringSync('{"pages":');
      r.bridge.command('RELOAD');
      await r.run(10);
      expect(r.status.pageName, 'Dancefloor');
      expect(r.status.error, startsWith("The APC40 layout file can't be read: "));
    });
  });

  group('status and stopping', () {
    test('a status every half second, with the old keys', () async {
      rig(layout: twoPages, buttons: buttons());
      // steps at 0, then from 210 (after the APC40's pause) to 1200
      await r.run(1000);
      expect(r.statuses.length, 3);
      final s = r.statuses.last.toJson();
      expect(s.keys, ['running', 'pid', 'apc', 'sx', 'page', 'pageName', 'pages', 'last', 'error', 'at']);
      expect(s['running'], true);
      expect(s['pid'], pid);
      expect(s['pages'], 2);
      expect(s['pageName'], 'One');
      expect(s['at'], matches(RegExp(r'^2026-11-25T20:00:01\.0000000[+-]\d\d:\d\d$')));
    });

    test('q stops the loop, and finishing turns the lights off and lets everything go', () async {
      rig(layout: twoPages, buttons: buttons());
      await r.connect();
      r.bridge.command('q');
      expect(await r.bridge.step(), false);
      r.midi.sent.clear();
      r.bridge.finish();
      expect(r.midi.sent.length, 49);
      expect(r.midi.sent.every((m) => m.$3 == 0), true);
      expect(r.midi.isOpen, false);
      expect(r.link.closed, true);
      expect(r.statuses.last.running, false);
      expect(r.statuses.last.apc, 'stopped');
    });

    test('SX Studio gone ends the loop too', () async {
      rig(layout: twoPages);
      r.bridge.command(null);
      expect(await r.bridge.step(), false);
    });

    test('without an APC40 (tests): sim, and the pad, sel and fader commands act like it', () async {
      rig(
        layout: {
          ...twoPages,
          'faders': {'1': 1},
        },
        noMidi: true,
        buttons: buttons(),
      );
      await r.connect();
      expect(r.status.apc, 'sim');
      r.bridge.command('pad 0');
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_PRESS|RED');
      r.bridge.command('pad 1');
      r.bridge.command('pad 1 up');
      await r.run(10);
      expect(r.link.acts.last, 'BUTTON_RELEASE|FLASH');
      r.bridge.command('sel 2');
      r.bridge.command('fader 1 127');
      await r.run(10);
      expect(r.status.page, 2);
      expect(r.link.acts.last, 'FADER_CHANGE|1|100');
      r.bridge.finish();
      expect(r.midi.sent, isEmpty);
    });
  });

  test('time in .NET round-trip form', () {
    expect(netRoundTrip(DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7)), '2026-01-02T03:04:05.0060070Z');
    expect(netRoundTrip(DateTime(2026, 1, 2, 3, 4, 5)), matches(RegExp(r'^2026-01-02T03:04:05\.0000000[+-]\d\d:\d\d$')));
  });
}
