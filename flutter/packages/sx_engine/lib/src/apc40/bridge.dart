import 'dart:io' show File, pid;

import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../ps_compat.dart';
import '../tools/apc40.dart';

// APC40 BRIDGE: plays the user's pages of pads on ShowXpress. The APC40 is not
// in ShowXpress's MIDI settings at all. The bridge owns it and presses
// ShowXpress's buttons through its remote connection (TCP 7348, buttons by
// TITLE, the protocol `sx_remote.dart` uses).
//
// On the APC40 (as the owner verified on their unit):
//   - a sysex puts it in Ableton Live mode, so every button sends a note and
//     the computer drives the lights
//   - grid pads are notes 0 to 39 on channel 1, 0 bottom left, 39 top right
//   - Track Select 1 to 8 (note 51, channel = column) pick pages 1 to 8, and
//     the lit one is the page it is on
//   - a pad press toggles its button (PRESS turns it on, RELEASE off), and a
//     flash button is held while the pad is
//   - a pad shows its button's ShowXpress colour, bright while the button is
//     on, dim when off, dark with no button. A pad can have its own colours
//   - Scene Launch 1 is the connection light: green while ShowXpress is
//     connected, red when not
//   - faders (CC 7 on channels 1 to 8, master CC 14) move ShowXpress's
//     master faders: a speed fader's middle is normal speed (-100 to 100), a
//     dimmer fader goes 0 to 100
//
// This file is the old loop's logic with no I/O of its own: MIDI goes through
// [Apc40Midi], ShowXpress through [Apc40Sx], and time through a clock and a
// pause, so tests step it by hand. `runner.dart` runs it on its own isolate.
//
// Port of the `Run` action of `apc40.ps1`.

/// The APC40's MIDI ports, as the old C# class `Apc40Io` opened them.
abstract interface class Apc40Midi {
  /// Opens the first input and the first output whose names contain [name].
  /// 0 when both are open, -1 when the APC40 is not plugged in, else the
  /// Windows error (4: another program has it). `Open`.
  int open(String name);

  /// True while the input is open. `IsOpen`.
  bool get isOpen;

  /// A short message: status, then two data bytes. `Send`.
  void send(int status, int d1, int d2);

  /// A system exclusive message. Waits until it has gone out (at most half a
  /// second). 0 when it went, else the Windows error. `SysEx`.
  int sysex(List<int> bytes);

  /// True while an input whose name contains [name] is plugged in.
  /// `FindIn(name) >= 0`.
  bool present(String name);

  /// The short messages that came in since the last call, oldest first.
  /// Each is `status | d1 << 8 | d2 << 16`. Draining `Q`.
  List<int> take();

  /// Closes both ports and drops what came in. `Close`.
  void close();
}

/// One connection to ShowXpress's remote.
abstract interface class Apc40SxLink {
  /// The text that came in since the last call, '' when none. Null once
  /// ShowXpress has closed the connection.
  String? read();

  /// Sends [text]. Throws when the connection is gone.
  void write(String text);

  void close();
}

/// How to reach ShowXpress's remote: the show's password and port, and the
/// type of each master fader (`speed` or `dimmer`, by 0-based number).
typedef Apc40Remote = ({String password, int port, Map<int, String> faderTypes});

/// ShowXpress, as the bridge needs it.
abstract interface class Apc40Sx {
  /// Is ShowXpress open. `Test-SxRunning`.
  bool get running;

  /// Reads the show's remote settings. `Get-RemoteSetup`.
  Apc40Remote setup();

  /// Connects to the remote on this computer. Null when nothing answered
  /// within 1.5 seconds.
  Future<Apc40SxLink?> connect(int port);
}

/// The part of the device names Windows gives the APC40 mk2.
const apc40DeviceName = 'APC40';

/// Ableton Live mode: every button sends a note and the computer drives the lights.
const apc40LiveMode = [0xF0, 0x47, 0x7F, 0x29, 0x60, 0x00, 0x04, 0x41, 0x08, 0x02, 0x01, 0xF7];

final _early = DateTime.utc(1), _never = DateTime.utc(9999);

/// A ShowXpress button as the last list showed it.
class _Btn {
  _Btn(this.on, this.flash, this.color);

  bool on;
  final bool flash;
  final String color;
}

/// The open connection to ShowXpress.
class _SxConn {
  _SxConn(this.link, this.since);

  final Apc40SxLink link;
  final DateTime since;
  final buf = StringBuffer();
  var hello = false;
}

/// The bridge's state and its loop, one [step] at a time.
class Apc40Bridge {
  Apc40Bridge({required this.midi, required this.sx, required this.layoutFile, DateTime Function()? now, void Function(Duration)? pause, this.onStatus})
    : now = now ?? DateTime.now,
      pause = pause ?? ((_) {});

  /// The APC40, or null to run without one (the old `-NoMidi`, for tests:
  /// drive it with [command]).
  final Apc40Midi? midi;
  final Apc40Sx sx;
  final File layoutFile;
  final DateTime Function() now;

  /// Waits, blocking. The real bridge sleeps on its own isolate as the old
  /// loop did. Tests move their clock on.
  final void Function(Duration) pause;

  /// Gets the status every half second and when the bridge stops. The old
  /// `-StatusFile`.
  final void Function(Apc40Status status)? onStatus;

  // ---- the state the old script kept
  var _running = true;
  var _apc = 'starting', _sxState = 'starting', _last = '', _error = '';
  Apc40Layout _lay = Apc40Layout();
  DateTime? _layoutT;
  var _page = 0;
  var _btns = psMap<_Btn>();
  var _faderTypes = <int, String>{};
  _SxConn? _sx;
  var _sxNextTry = _early, _listAt = _never, _pollAt = _early;
  var _apcNextTry = _early, _apcCheckAt = _early, _statusAt = _early;
  final _led = <String, int>{};
  var _held = <int, String>{};
  final _fadPend = <int, int>{}, _fadSent = <int, DateTime>{};
  final _commands = <String?>[];
  var _started = false;

  bool get _connected => _sx?.hello ?? false;

  /// The page the APC40 is on, 0-based.
  int get page => _page;

  /// The layout in use.
  Apc40Layout get layout => _lay;

  /// What the bridge is doing now. `Write-Status`'s record.
  Apc40Status get status => Apc40Status(
    running: _running,
    pid: pid,
    apc: _apc,
    sx: _sxState,
    page: _page + 1,
    pageName: _page < _lay.pages.length ? _lay.pages[_page].name : '',
    pages: _lay.pages.length,
    last: _last,
    error: _error,
    at: netRoundTrip(now()),
  );

  void _writeStatus() => onStatus?.call(status);

  /// A line from SX Studio, the old stdin: `q`, `reload`, and for tests
  /// `pad <n> [up]`, `sel <1..8>`, `fader <1..9> <0..127>`. Null means SX
  /// Studio is gone, as a closed stdin did. Acted on at the next [step].
  void command(String? line) => _commands.add(line);

  // ---------------------------------------------------------------- layout

  /// Port of `Read-Layout` (from the layout file).
  void _readLayout() {
    _layoutT = layoutFile.existsSync() ? layoutFile.lastModifiedSync() : null;
    _lay = readApc40Layout(layoutFile, onError: (e) => _error = e);
    if (_page >= _lay.pages.length) _page = 0;
  }

  // ---------------------------------------------------------------- ShowXpress

  /// Port of `Send-Sx`. False when there is no connection or it broke.
  bool _send(String line) {
    final c = _sx;
    if (c == null) return false;
    try {
      c.link.write('$line\r\n');
      return true;
    } catch (_) {
      _closeSx('lost');
      return false;
    }
  }

  /// Port of `Close-Sx`.
  void _closeSx(String why) {
    try {
      _sx?.link.close();
    } catch (_) {}
    _sx = null;
    _sxNextTry = now().add(const Duration(seconds: 2));
    _sxState = why;
    for (final b in _btns.values) {
      b.on = false;
    }
  }

  /// Port of `Open-Sx`.
  Future<void> _openSx() async {
    _sxNextTry = now().add(const Duration(seconds: 3));
    if (!sx.running) {
      _sxState = 'closed';
      return;
    }
    final rs = sx.setup();
    _faderTypes = rs.faderTypes;
    if (rs.password.isEmpty) {
      _sxState = 'off';
      _error = "ShowXpress's remote control is off - turn it on in SX Studio's Auto Show tab.";
      return;
    }
    final link = await sx.connect(rs.port);
    if (link == null) {
      _sxState = 'starting';
      return;
    }
    _sx = _SxConn(link, now());
    _send('HELLO|SX Studio APC40|${rs.password}');
  }

  /// Port of `Read-SxLines`: the whole lines that came in.
  List<String> _readLines() {
    final c = _sx;
    if (c == null) return const [];
    String? got;
    try {
      got = c.link.read();
    } catch (_) {
      // a read that fails is a lost connection
    }
    if (got == null) {
      _closeSx('lost');
      return const [];
    }
    c.buf.write(got);
    final t = c.buf.toString(), k = t.lastIndexOf('\r\n');
    if (k < 0) return const [];
    c.buf
      ..clear()
      ..write(t.substring(k + 2));
    return [
      for (final l in t.substring(0, k).split('\r\n'))
        if (l.isNotEmpty) l,
    ];
  }

  /// Port of `Read-List`: the buttons in ShowXpress's `BUTTON_LIST` XML, the
  /// first of each title (ShowXpress presses that one). A list that can't
  /// be read changes nothing.
  void _readList(String xml) {
    final XmlDocument d;
    try {
      d = XmlDocument.parse(xml);
    } on XmlException {
      return;
    }
    // PowerShell's XML adapter makes an element with no attributes and only
    // text a plain string, which has no InnerText
    bool plain(XmlElement e) => e.attributes.isEmpty && e.childElements.isEmpty;
    Iterable<XmlElement> kids(XmlElement e, String name) => e.childElements.where((c) => psEq(c.name.local, name));
    String attr(XmlElement e, String name) => e.attributes.where((a) => psEq(a.name.local, name)).firstOrNull?.value ?? '';
    final nb = psMap<_Btn>();
    final root = d.rootElement;
    if (psEq(root.name.local, 'buttons')) {
      for (final pg in kids(root, 'page')) {
        if (plain(pg)) continue;
        for (final b in kids(pg, 'button')) {
          if (plain(b)) continue;
          final t = netTrim(b.innerText);
          if (t.isEmpty || nb.containsKey(t)) continue;
          nb[t] = _Btn(attr(b, 'pressed') == '1', attr(b, 'flash') == '1', attr(b, 'color'));
        }
      }
    }
    _btns = nb;
  }

  /// Port of `Step-Sx`.
  Future<void> _stepSx() async {
    final t0 = now();
    if (_sx == null) {
      if (!t0.isBefore(_sxNextTry)) await _openSx();
      return;
    }
    for (final l in _readLines()) {
      if (psEq(l, 'HELLO')) {
        // a send that failed may have closed it (the old loop failed here)
        final c = _sx;
        if (c == null) continue;
        c.hello = true;
        _sxState = 'ok';
        _error = '';
        _send('BUTTON_LIST');
        continue;
      }
      if (psLike(l, 'ERROR*')) {
        _error = 'ShowXpress refused the APC40 ($l). Turn the remote on again from SX Studio.';
        _closeSx('refused');
        _sxNextTry = now().add(const Duration(seconds: 10));
        return;
      }
      if (l.startsWith('BUTTON_LIST|')) {
        _readList(l.substring(12));
        continue;
      }
      if (l.startsWith('BUTTON_PRESS|')) {
        _btns[l.substring(13)]?.on = true;
        _listAt = now().add(const Duration(milliseconds: 400));
        continue;
      }
      if (l.startsWith('BUTTON_RELEASE|')) {
        _btns[l.substring(15)]?.on = false;
        continue;
      }
      if (psEq(l, 'INTERFACE_CHANGE')) {
        _listAt = now().add(const Duration(milliseconds: 300));
        continue;
      }
      // BEAT_ON / BEAT_OFF / BPM: ShowXpress offering to take beats. There are none to give.
    }
    final c = _sx;
    if (c == null) return;
    if (!c.hello && now().difference(c.since) > const Duration(seconds: 4)) {
      _closeSx('starting');
      return;
    }
    if (c.hello) {
      // the list again a moment after a press (a solo page releases the others) and every 2 s (anything pressed elsewhere)
      if (!t0.isBefore(_listAt) || !t0.isBefore(_pollAt)) {
        _listAt = _never;
        _pollAt = t0.add(const Duration(seconds: 2));
        _send('BUTTON_LIST');
      }
    }
  }

  // ---------------------------------------------------------------- APC40

  /// Port of `Open-Apc`.
  void _openApc() {
    _apcNextTry = now().add(const Duration(seconds: 2));
    final m = midi;
    if (m == null) {
      _apc = 'sim';
      return;
    }
    final r = m.open(apc40DeviceName);
    if (r == -1) {
      _apc = 'missing';
      return;
    }
    if (r != 0) {
      _apc = 'busy';
      _error = r == 4 ? "Another program has the APC40 - take it out of ShowXpress's MIDI settings." : "The APC40 can't be opened (error $r).";
      return;
    }
    m.sysex(apc40LiveMode);
    pause(const Duration(milliseconds: 200));
    _led.clear();
    _apc = 'ok';
    if (psLike(_error, '*APC40*')) _error = '';
  }

  /// Port of `Set-Led`: sends only what changed.
  void _setLed(int status, int note, int v) {
    final k = '$status/$note';
    if (_led[k] == v) return;
    _led[k] = v;
    midi?.send(status, note, v);
  }

  /// Port of `Update-Leds`.
  void _updateLeds() {
    if (_apc != 'ok' && _apc != 'sim') return;
    final pg = _lay.pages[_page], conn = _connected;
    for (var n = 0; n < 40; n++) {
      var v = 0;
      final t = pg.pads[n];
      if (t != null) {
        final b = _btns[t];
        if (b != null) {
          final c = pg.colors[n] ?? apc40PadColor(b.color);
          v = conn && b.on ? c.on : c.off;
        } else if (!conn) {
          v = 1; // not connected yet: assigned pads dim grey
        }
      }
      _setLed(0x90, n, v);
    }
    for (var p = 0; p < 8; p++) {
      _setLed(0x90 + p, 51, p == _page ? 1 : 0);
    }
    _setLed(0x90, 82, conn ? 21 : 5);
  }

  /// Port of `Clear-Leds`: every light off.
  void _clearLeds() {
    final m = midi;
    if (m == null || !m.isOpen) return;
    for (var n = 0; n < 40; n++) {
      m.send(0x90, n, 0);
    }
    for (var p = 0; p < 8; p++) {
      m.send(0x90 + p, 51, 0);
    }
    m.send(0x90, 82, 0);
  }

  /// A pad pressed ([down]) or let go. Port of `Invoke-Pad`.
  void _pad(int n, bool down) {
    final pg = _lay.pages[_page];
    if (!down) {
      final t = _held.remove(n);
      if (t != null) {
        _send('BUTTON_RELEASE|$t');
        _btns[t]?.on = false;
      }
      return;
    }
    final t = pg.pads[n];
    if (t == null) return;
    if (!_connected) {
      _last = "$t - ShowXpress isn't connected";
      return;
    }
    final b = _btns[t];
    if (b == null) {
      _last = '$t - not in ShowXpress (renamed or removed?)';
      return;
    }
    if (b.flash) {
      _send('BUTTON_PRESS|$t');
      b.on = true;
      _held[n] = t;
      _last = '$t (held)';
    } else if (b.on) {
      _send('BUTTON_RELEASE|$t');
      b.on = false;
      _last = '$t off';
    } else {
      _send('BUTTON_PRESS|$t');
      b.on = true;
      _last = '$t on';
    }
    _listAt = now().add(const Duration(milliseconds: 350));
  }

  /// Port of `Set-Page`. A pad held on the old page is forgotten, not let go.
  void _setPage(int p) {
    if (p >= 0 && p < _lay.pages.length) {
      _page = p;
      _held = {};
    }
  }

  /// Port of `Invoke-Fader`: kept until [_stepFaders] may send it.
  void _fader(int f, int v) {
    if (_lay.faders.containsKey(f)) _fadPend[f] = v;
  }

  /// Port of `Step-Faders`: at most one move per fader every 40 ms.
  void _stepFaders() {
    if (!_connected) return;
    for (final f in [..._fadPend.keys]) {
      final sent = _fadSent[f];
      if (sent != null && now().difference(sent) < const Duration(milliseconds: 40)) continue;
      final v = _fadPend.remove(f)!;
      _fadSent[f] = now();
      // the layout was reloaded without this fader (the old loop failed here)
      final k = _lay.faders[f];
      if (k == null) continue;
      final x = (_faderTypes[k] == 'dimmer' ? psRound(v * 100 / 127) : psRound((v - 64) * 100 / 63.5)).clamp(-100, 100);
      _send('FADER_CHANGE|$k|$x');
    }
  }

  /// Port of `Step-Midi`: what the APC40 sent.
  void _stepMidi() {
    for (final m in midi?.take() ?? const <int>[]) {
      final s = m & 0xF0, ch = m & 0x0F, d1 = (m >> 8) & 0x7F, d2 = (m >> 16) & 0x7F;
      final on = s == 0x90 && d2 > 0, off = s == 0x80 || (s == 0x90 && d2 == 0);
      if (on || off) {
        if (ch == 0 && d1 <= 39) {
          _pad(d1, on);
        } else if (d1 == 51 && on) {
          _setPage(ch);
        }
      } else if (s == 0xB0) {
        if (d1 == 7) {
          _fader(ch + 1, d2);
        } else if (d1 == 14 && ch == 0) {
          _fader(9, d2);
        }
      }
    }
  }

  // ---------------------------------------------------------------- the loop

  /// One pass of the old loop, which ran every 10 ms. False once SX Studio
  /// said `q` or went away: then call [finish].
  Future<bool> step() async {
    if (!_started) {
      _started = true;
      _readLayout();
    }
    final t = now();
    while (_commands.isNotEmpty) {
      final cmd = _commands.removeAt(0);
      if (cmd == null) return false;
      final a = cmd.trim().toLowerCase().split(RegExp(r'\s+'));
      int? n(int i) => a.length > i ? int.tryParse(a[i]) : null;
      switch (a[0]) {
        case 'q':
          return false;
        case 'reload':
          _readLayout();
        case 'pad' when n(1) != null:
          _pad(n(1)!, !(a.length >= 3 && a[2] == 'up'));
        case 'sel' when n(1) != null:
          _setPage(n(1)! - 1);
        case 'fader' when n(1) != null && n(2) != null:
          _fader(n(1)!, n(2)!);
      }
    }
    if (!t.isBefore(_apcCheckAt)) {
      _apcCheckAt = t.add(const Duration(seconds: 2));
      if (layoutFile.existsSync() && layoutFile.lastModifiedSync() != _layoutT) _readLayout();
      final m = midi;
      if (m != null && _apc == 'ok' && !m.present(apc40DeviceName)) {
        // unplugged
        m.close();
        _apc = 'missing';
      }
    }
    if (_apc != 'ok' && _apc != 'sim' && !t.isBefore(_apcNextTry)) {
      _openApc();
    } else if (_apc == 'starting') {
      _openApc();
    }
    if (_apc == 'ok') _stepMidi();
    // ShowXpress only while this bridge has the APC40 (no long connection to ShowXpress for nothing)
    if (_apc == 'ok' || _apc == 'sim') {
      await _stepSx();
    } else if (_sx != null) {
      _closeSx('waiting');
    } else {
      _sxState = 'waiting';
    }
    _stepFaders();
    _updateLeds();
    if (!t.isBefore(_statusAt)) {
      _statusAt = t.add(const Duration(milliseconds: 500));
      _writeStatus();
    }
    return true;
  }

  /// Lights off, the APC40 and ShowXpress let go, and a last status that
  /// says stopped. The old loop's `finally`.
  void finish() {
    try {
      _clearLeds();
    } catch (_) {}
    try {
      midi?.close();
    } catch (_) {}
    try {
      _sx?.link.close();
    } catch (_) {}
    _running = false;
    _apc = 'stopped';
    _writeStatus();
  }
}

/// .NET's `ToString('o')`: `2026-11-25T21:04:05.1234567+01:00` for a local
/// time, with `Z` for a UTC one.
String netRoundTrip(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final frac = (t.millisecond * 10000 + t.microsecond * 10).toString().padLeft(7, '0');
  final base = '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$frac';
  if (t.isUtc) return '${base}Z';
  final o = t.timeZoneOffset, m = o.inMinutes.abs();
  return '$base${o.isNegative ? '-' : '+'}${two(m ~/ 60)}:${two(m % 60)}';
}
