import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../dmx/dmx_output.dart';
import 'cs_compat.dart';
import 'player_commands.dart';
import 'player_files.dart';

/// One button the player can play: a live.ini button, or one on the SX
/// Player's own pages.
class _Btn {
  _Btn(this.sec, this.path, this.title);

  final String sec, path, title;
  int page = 0, fader = 0, inCh = 1, note = -1, outSt = -1, outNote = -1, onV = 0, offV = 0;
  bool swap = false;
  String key = '';
  bool bpm = false, flash = false;

  /// Beats per step (live.ini `beats`).
  double bps = 1;
}

/// One button playing.
class _Play {
  _Play(this.slot, this.t0) : last = t0;

  final String slot;
  Scene? sc;
  Move? mv;
  final double t0;
  double el = 0, last;
  int fader = -1;
  Uint8List from = Uint8List(0);
  int step = 0;
  bool bp = false, fl = false;
  double bps = 1, eb = 0, x0 = 0;
  int g0 = 0, lastG = 0;
}

/// The SX Player's state and frame maths, with no clock and no hardware of
/// its own. Every method that depends on time takes `now`, in ms on one
/// steady clock, so a test can feed chosen times and compare frames.
///
/// Port of the `SxPlayer` C# class in `player.ps1`, minus its threads, the
/// driver, MIDI and the OS2L socket (see `player_host.dart`). The locks are
/// gone because all of this runs on the player's own isolate.
class PlayerCore {
  PlayerCore(this.files);

  final PlayerFiles files;

  // ---------------------------------------------------------------- the live board
  final _btns = <String, _Btn>{};

  /// Title to the first button with it (like ShowXpress).
  final _byTitle = <String, _Btn>{};

  /// (channel << 8) | note to the button (first one wins, like ShowXpress).
  final _byNote = <int, _Btn>{};

  /// (channel << 8) | cc to speed fader index.
  final _faderCc = <int, int>{};

  /// Fader positions 0..1.
  final fv = List<double>.filled(16, 0);
  final _isSpeed = List<bool>.filled(16, false);

  /// Port of `ClearBoard`.
  void clearBoard() {
    _btns.clear();
    _byTitle.clear();
    _byNote.clear();
    _faderCc.clear();
    for (var i = 0; i < fv.length; i++) {
      fv[i] = 0.5;
      _isSpeed[i] = false;
    }
  }

  /// Port of `AddButton`.
  void addButton(
    String sec,
    String? path,
    String title,
    int page,
    bool swap,
    int fader,
    String? key,
    int inCh,
    int note,
    int outCh,
    int outNote,
    int onV,
    int offV,
  ) {
    final b = _Btn(sec, path ?? '', title)
      ..page = page
      ..swap = swap
      ..fader = fader
      ..key = key ?? ''
      ..inCh = inCh
      ..note = note
      ..outNote = outNote
      ..onV = onV
      ..offV = offV
      ..outSt = outNote >= 0 ? 0x90 | ((math.max(1, outCh) - 1) & 15) : -1;
    _btns[sec] = b;
    if (title.isNotEmpty && !_byTitle.containsKey(title)) _byTitle[title] = b;
    if (note >= 0) _byNote.putIfAbsent((math.max(1, inCh) << 8) | note, () => b);
  }

  /// Port of `AddFader`.
  void addFader(int k, bool speed, int ch, int cc) {
    if (k < 0 || k >= fv.length) return;
    _isSpeed[k] = speed;
    if (cc >= 0) _faderCc[(math.max(1, ch) << 8) | cc] = k;
  }

  /// Takes one of the player's own buttons away (live.ini ones stay for the
  /// whole run). Port of `RemoveButton`.
  void removeButton(String sec) {
    final b = _btns.remove(sec);
    if (b == null) return;
    _plays.removeWhere((p) => p.slot == sec);
    if (b.title.isNotEmpty && identical(_byTitle[b.title], b)) _byTitle.remove(b.title);
  }

  /// Port of `SetFader`.
  void setFader(int k, double v) {
    if (k >= 0 && k < fv.length) fv[k] = v.clamp(0.0, 1.0);
  }

  /// A speed fader's clock factor. GUESS: middle 1x, top 4x, bottom 1/4x.
  static double speed(double v) => math.pow(2, (v - 0.5) * 4).toDouble();

  int get buttons => _btns.length;

  /// Makes a button a BPM button (speed = auto_bpm). Port of `SetBeat`.
  void setBeat(String sec, bool flash, double beats) {
    final b = _btns[sec];
    if (b == null) return;
    b
      ..bpm = true
      ..flash = flash
      ..bps = beats > 0.01 && beats <= 64 ? beats : 1;
  }

  bool isOn(String sec) => _plays.any((p) => p.slot == sec);

  /// On, not toggle. Port of `SetOn`.
  void setOn(String sec, double now) {
    if (!isOn(sec)) press(sec, now);
  }

  /// The button called [title]. Port of `SecOf`.
  String secOf(String title) {
    final b = _byTitle[title.trim()];
    if (b == null) throw PlayerError('there is no button called ${title.trim()}');
    return b.sec;
  }

  // ---------------------------------------------------------------- the beat
  double _bpm = 120, _lastTick = 0, _extAt = -1e9, _lastB = 0;
  int _beatN = 0;
  String _bpmSrc = 'manual';
  final _taps = <double>[];

  double get bpm => _bpm;
  String get bpmSrc => _bpmSrc;

  double _per() => 60000.0 / _bpm;

  /// The clock's own beats (not while VirtualDJ is sending them).
  void _clock(double now) {
    final per = _per();
    if (now - _extAt < 2 * per + 1000) return;
    if (now - _lastTick >= per) {
      final n = csFloor((now - _lastTick) / per);
      _beatN += n;
      _lastTick += n * per;
    }
  }

  double _beatAt(double now) {
    _clock(now);
    return _beatN + math.min(0.999, math.max(0.0, (now - _lastTick) / _per()));
  }

  double beat(double now) => _beatAt(now);

  /// A beat is now: to the nearest whole beat.
  void _tickAt(double now) {
    final b = _beatAt(now), fl = b.floorToDouble();
    _beatN = fl.toInt() + (b - fl >= 0.5 ? 1 : 0);
    _lastTick = now;
  }

  /// Port of `SetBpm`.
  void setBpm(double v, double now, String src) {
    if (v < 40 || v > 250) return;
    final b = _beatAt(now);
    _bpm = csRound(v, 2);
    _beatN = csFloor(b);
    _lastTick = now - (b - b.floorToDouble()) * _per();
    _bpmSrc = src;
    _taps.clear();
  }

  /// Port of `Tap`. The average of the last taps; one tap after a pause only
  /// moves the beat.
  void tap(double now) {
    if (_taps.isNotEmpty && now - _taps.last > 2000) _taps.clear();
    _tickAt(now);
    _extAt = -1e9;
    _bpmSrc = 'tap';
    _taps.add(now);
    if (_taps.length > 8) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final v = 60000.0 * (_taps.length - 1) / (now - _taps[0]);
      if (v >= 40 && v <= 250) _bpm = csRound(v, 1);
    }
  }

  /// VirtualDJ (OS2L): a beat now, at [v] BPM. Port of `ExtBeat`.
  void extBeat(double now, double v) {
    _tickAt(now);
    if (v >= 40 && v <= 250) _bpm = csRound(v, 2);
    _extAt = now;
    _bpmSrc = 'VirtualDJ';
  }

  /// Now is beat 1: BPM chases start again from their first step.
  /// Port of `SyncBeat`.
  void syncBeat(double now) {
    final b = _beatAt(now);
    final n = csRound0(b).toInt();
    _beatN = ((n + 3) ~/ 4) * 4;
    _lastTick = now;
    for (final p in _plays) {
      if (!p.bp) continue;
      p
        ..eb = 0
        ..el = 0;
      final sc = p.sc!;
      for (var k = 0; k < sc.chans.length; k++) {
        p.from[k] = _outF[sc.chans[k]];
      }
    }
  }

  /// GUESS: on a BPM button the speed fader picks /4 /2 x1 x2 x4.
  static double beatMul(double v) => math.pow(2, csRound0((v - 0.5) * 4)).toDouble();

  /// One frame of a BPM scene. Port of `BeatScene`.
  void _beatScene(_Play p, double b, Uint8List f) {
    final s = p.sc!;
    final ns = s.len.length;
    final eb = p.bps / (p.fader >= 0 ? beatMul(fv[p.fader]) : 1); // beats per step
    final x = b / eb;
    var g = csFloor(x);
    if (p.eb == 0) {
      p
        ..g0 = g
        ..lastG = g
        ..x0 = x
        ..eb = eb;
    } else if (eb != p.eb) {
      // fader moved: keep the step
      final s0 = p.lastG - p.g0;
      p
        ..eb = eb
        ..g0 = g - s0
        ..lastG = g
        ..x0 = g.toDouble();
    }
    if (g < p.lastG) g = p.lastG; // a tap / VirtualDJ beat can pull the clock back a little: never step backwards
    final fresh = g > p.lastG;
    p.lastG = g;
    int i;
    double fr;
    Uint8List prev;
    if (p.fl) {
      // flash mode: every beat the scene runs once from step 1 at its own step lengths, then holds its last step
      if (fresh) {
        p.el = 0;
        for (var k = 0; k < s.chans.length; k++) {
          p.from[k] = _outF[s.chans[k]];
        }
      }
      final pos = p.el;
      var at = 0.0;
      i = 0;
      while (i < ns - 1 && pos >= at + s.len[i]) {
        at += s.len[i];
        i++;
      }
      fr = math.min(1.0, (pos - at) / s.len[i]);
      prev = i > 0 ? s.val[i - 1] : p.from;
    } else {
      // step mode: one step per beat-step, fades over the whole step
      final si = g - p.g0;
      i = si.remainder(ns);
      final x0 = p.x0 - p.x0.floorToDouble();
      fr = si == 0 && csFloor(p.x0) == g ? (x - p.x0) / math.max(1e-6, 1 - x0) : x - g;
      fr = fr.clamp(0.0, 1.0);
      prev = si == 0 ? p.from : s.val[(i - 1 + ns) % ns];
    }
    p.step = i;
    _blend(s, i, prev, fr, f);
  }

  static void _blend(Scene s, int i, Uint8List prev, double fr, Uint8List f) {
    final v = s.val[i];
    final fd = s.fade[i];
    for (var k = 0; k < s.chans.length; k++) {
      f[s.chans[k]] = fd[k] ? csRound0(prev[k] + (v[k] - prev[k]) * fr).toInt() : v[k];
    }
  }

  // ---------------------------------------------------------------- pressing
  /// Toggles a button. On a swap page, pressing one releases the others on
  /// that page. Port of `Press`.
  void press(String sec, double now) {
    final b = _btns[sec];
    if (b == null) throw PlayerError('that button is not in the show');
    if (isOn(sec)) {
      off(sec);
      return;
    }
    if (b.path.isEmpty) throw PlayerError('${b.title}: its file is missing');
    try {
      _isMove(b.path) ? files.move(b.path) : files.scene(b.path);
    } on PlayerError catch (e) {
      throw PlayerError('${b.title}: ${e.message}');
    } on FileSystemException catch (e) {
      throw PlayerError('${b.title}: ${e.message}');
    }
    if (b.swap) {
      _plays.removeWhere((p) {
        final o = _btns[p.slot];
        return o != null && o.swap && o.page == b.page;
      });
    }
    on(sec, b.path, now);
  }

  /// A keyboard trigger. Port of `KeyPress`.
  void keyPress(String k, double now) {
    for (final b in _btns.values) {
      if (b.key.isNotEmpty && b.key.toLowerCase() == k.toLowerCase()) {
        press(b.sec, now);
        return;
      }
    }
  }

  /// A MIDI message (status | d1 << 8 | d2 << 16). Port of `Midi`.
  void midi(int m, double now) {
    final st = m & 0xF0, ch = (m & 0x0F) + 1, d1 = (m >> 8) & 0x7F, d2 = (m >> 16) & 0x7F;
    if (st == 0x90 && d2 > 0) {
      final b = _byNote[(ch << 8) | d1];
      if (b != null) press(b.sec, now);
    } else if (st == 0xB0) {
      final k = _faderCc[(ch << 8) | d1];
      if (k != null) setFader(k, d2 / 127.0);
    }
  }

  /// (status << 8) | note to the value last sent to that pad.
  final _ledSent = <int, int>{};

  /// Pad lights: what each pad should show now. Sends only changes through
  /// [send] (a MIDI short message). Port of `SyncLeds`.
  void syncLeds(bool allOff, void Function(int msg)? send) {
    final want = <int, int>{};
    final on = {for (final p in _plays) p.slot};
    for (final b in _btns.values) {
      if (b.outSt < 0) continue;
      final k = (b.outSt << 8) | b.outNote;
      final lit = !allOff && on.contains(b.sec);
      final cur = want[k];
      if (cur != null && cur == b.onV && !lit) continue; // a shared pad: lit wins
      want[k] = lit ? b.onV : b.offV;
    }
    for (final MapEntry(:key, :value) in want.entries) {
      if (_ledSent[key] == value) continue;
      _ledSent[key] = value;
      send?.call((key >> 8) | ((key & 0x7F) << 8) | ((value & 0x7F) << 16));
    }
  }

  // ---------------------------------------------------------------- playback
  /// Oldest press first: the last one wins.
  final _plays = <_Play>[];
  var _outF = Uint8List(dmxFrameSize);
  bool _blackout = false;
  String lastError = '';

  static bool _isMove(String path) => path.toLowerCase().endsWith('.gpj');

  /// Starts (or restarts) a scene or movement in [slot]. Port of `On`.
  void on(String slot, String path, double now) {
    if (_isMove(path)) {
      final mv = files.move(path);
      _plays.removeWhere((p) => p.slot == slot);
      _plays.add(
        _Play(slot, now)
          ..mv = mv
          ..fader = _faderOf(slot),
      );
      return;
    }
    final sc = files.scene(path);
    _plays.removeWhere((p) => p.slot == slot);
    final q = _Play(slot, now)
      ..sc = sc
      ..fader = _faderOf(slot)
      ..from = Uint8List(sc.chans.length);
    for (var k = 0; k < sc.chans.length; k++) {
      q.from[k] = _outF[sc.chans[k]];
    }
    final bb = _btns[slot];
    if (bb != null && bb.bpm) {
      q
        ..bp = true
        ..fl = bb.flash
        ..bps = bb.bps;
    }
    _plays.add(q);
  }

  int _faderOf(String slot) {
    final b = _btns[slot];
    return b != null && b.fader >= 0 && b.fader < fv.length && _isSpeed[b.fader] ? b.fader : -1;
  }

  void off(String slot) => _plays.removeWhere((p) => p.slot == slot);

  void allOff() => _plays.clear();

  void blackout(bool on) => _blackout = on;

  /// The frame at [now]: every playing button, the last pressed winning.
  /// Port of `Frame`.
  Uint8List frame(double now) {
    final f = Uint8List(dmxFrameSize);
    final b = _beatAt(now);
    _lastB = b;
    for (final p in _plays) {
      p.el += math.max(0.0, now - p.last) * (p.fader >= 0 && !p.bp ? speed(fv[p.fader]) : 1);
      p.last = now;
      final mv = p.mv;
      if (mv != null) {
        p.step = evalMove(mv, p.el, f);
        continue;
      }
      if (p.bp) {
        _beatScene(p, b, f);
        continue;
      }
      final s = p.sc!;
      final ns = s.len.length;
      final el = p.el;
      final pass = csFloor(el / s.total);
      var pos = el - pass * s.total.toDouble();
      var i = 0;
      var at = 0.0;
      while (i < ns - 1 && pos >= at + s.len[i]) {
        at += s.len[i];
        i++;
      }
      if (ns == 1 && pass > 0) {
        // one step: after its first pass it just holds
        i = 0;
        pos = s.len[0].toDouble();
        at = 0;
      }
      p.step = i;
      final prev = i > 0 ? s.val[i - 1] : (pass == 0 ? p.from : s.val[ns - 1]);
      final fr = math.min(1.0, (pos - at) / s.len[i]);
      _blend(s, i, prev, fr, f);
    }
    _outF = f;
    return _blackout ? Uint8List(dmxFrameSize) : f;
  }

  // ---------------------------------------------------------------- gig safety
  final _warns = <String>[];

  void warn(String w) {
    if (_warns.length < 40) _warns.add(w);
  }

  /// Loads every button's file once: problems become warnings, and the first
  /// press of each is instant. Returns the number of problems. Port of `CheckShow`.
  int checkShow() {
    final seen = <String>{};
    var n = 0;
    for (final b in _btns.values.toList()) {
      if (b.path.isEmpty) {
        warn('${b.title}: its file is missing');
        n++;
        continue;
      }
      if (!seen.add(b.path.toLowerCase())) continue;
      try {
        final u = _isMove(b.path) ? files.move(b.path).unpatched : files.scene(b.path).unpatched;
        if (u > 0) {
          warn("${b.title}: $u light(s) in it are not in the show's fixture list");
          n++;
        }
      } on PlayerError catch (e) {
        warn('${b.title}: ${e.message}');
        n++;
      } on FileSystemException catch (e) {
        warn('${b.title}: ${e.message}');
        n++;
      }
    }
    return n;
  }

  // ---------------------------------------------------------------- what the host fills in for the status
  String midiName = '';
  String os2lPeer = '', os2lErr = '';

  /// The OS2L port while listening, else 0.
  int os2lPort = 0;
  int os2lBeats = 0;
  bool lost = false;
  int reconnects = 0;

  /// What the player is doing, key for key the old status file. Port of `Status`.
  Map<String, Object?> status() => {
    'ok': true,
    'bo': _blackout,
    'on': [
      for (final q in _plays)
        {
          'slot': q.slot,
          'step': q.step + 1,
          'of': q.mv != null ? math.max(1, q.mv!.points) : q.sc!.len.length,
          if (q.mv != null) 'mv': true,
          if (q.bp) 'bpm': true,
        },
    ],
    'err': lastError,
    'fd': [for (final v in fv) csFixed(v, 3)],
    'midi': midiName,
    'led': {for (final MapEntry(:key, :value) in _ledSent.entries) '${key & 0x7F}': value},
    'bpm': csFixed(_bpm, 2),
    'beat': csFixed(_lastB, 3),
    'src': _bpmSrc,
    'os2l': os2lPeer,
    'os2lPort': os2lPort,
    'os2lErr': os2lErr,
    'os2lBeats': os2lBeats,
    'iface': lost ? 'lost' : 'ok',
    'reconn': reconnects,
    'warn': [..._warns],
  };

  // ---------------------------------------------------------------- commands
  /// Applies one command at [now]. A refusal goes into [lastError], like the
  /// old player did with a bad stdin line. Port of `Apply`.
  void apply(PlayerCommand c, double now) {
    try {
      switch (c) {
        case PlayOn(:final slot, :final path):
          lastError = '';
          try {
            on(slot, path, now);
          } on PlayerError catch (e) {
            throw PlayerError('${p.basenameWithoutExtension(path)}: ${e.message}');
          }
        case PlayOff(:final slot):
          off(slot);
        case AllOffCommand():
          allOff();
        case BlackoutCommand(:final on):
          blackout(on);
        case PressCommand(:final sec):
          lastError = '';
          press(sec, now);
        case KeyCommand(:final key):
          lastError = '';
          keyPress(key, now);
        case FaderCommand(:final k, :final v):
          setFader(k, v);
        case MidiCommand(:final msg):
          midi(msg, now);
        case BpmCommand(:final bpm):
          setBpm(bpm, now, 'manual');
        case TapCommand():
          tap(now);
        case SyncCommand():
          syncBeat(now);
        case SetOnCommand(:final sec):
          lastError = '';
          setOn(sec, now);
        case SetOffCommand(:final sec):
          off(sec);
        case TitleOnCommand(:final title):
          lastError = '';
          setOn(secOf(title), now);
        case TitleOffCommand(:final title):
          off(secOf(title));
        case AddButtonCommand(:final b):
          if (!b.sec.startsWith('x')) return;
          final was = isOn(b.sec);
          final o = _btns[b.sec];
          if (o != null && identical(_byTitle[o.title], o)) _byTitle.remove(o.title);
          addButton(b.sec, b.path, b.title, b.group, b.swap, b.fader, '', 1, -1, 1, -1, 0, 0);
          if (b.bpm) setBeat(b.sec, b.flash, b.beats);
          if (was && b.path.isNotEmpty) on(b.sec, b.path, now); // edited while playing: carries on with the new settings
        case RemoveButtonCommand(:final sec):
          if (sec.startsWith('x')) removeButton(sec);
      }
    } on Exception catch (e) {
      lastError = errorText(e);
    }
  }

  /// One OS2L message from VirtualDJ: a beat, or a button by title.
  /// Port of `Os2lMsg`.
  void os2lMessage(String j, double now) {
    final evt = jsonStr(j, 'evt');
    if (evt == 'beat') {
      final bs = jsonStr(j, 'bpm');
      extBeat(now, (bs == null ? null : csDouble(bs)) ?? 0);
      os2lBeats++;
    } else if (evt == 'btn') {
      final name = jsonStr(j, 'name'), state = jsonStr(j, 'state');
      if (name == null || name.isEmpty) return;
      final b = _byTitle[name.trim()];
      if (b == null) return;
      if (state == 'off') {
        off(b.sec);
      } else {
        setOn(b.sec, now);
      }
    }
  }
}

/// A `"key":"value"` string from a small JSON object, read the forgiving way
/// the old player did. A bare value (a number) comes back as its text.
/// Port of `JStr`.
String? jsonStr(String j, String key) {
  var i = j.indexOf('"$key"');
  if (i < 0) return null;
  i = j.indexOf(':', i + key.length + 2);
  if (i < 0) return null;
  i++;
  while (i < j.length && _isWhite(j.codeUnitAt(i))) {
    i++;
  }
  if (i >= j.length) return null;
  if (j[i] != '"') {
    var e = i;
    while (e < j.length && j[e] != ',' && j[e] != '}') {
      e++;
    }
    return j.substring(i, e).trim();
  }
  final b = StringBuffer();
  for (i++; i < j.length && j[i] != '"'; i++) {
    if (j[i] == r'\' && i + 1 < j.length) {
      i++;
      final e = j[i];
      if (e == 'u' && i + 4 < j.length) {
        b.writeCharCode(int.parse(j.substring(i + 1, i + 5), radix: 16));
        i += 4;
      } else {
        b.write(e == 'n' ? '\n' : (e == 't' ? '\t' : e));
      }
    } else {
      b.write(j[i]);
    }
  }
  return b.toString();
}

/// The message of an exception, the way the old player put it in its status.
String errorText(Exception e) => switch (e) {
  PlayerError(:final message) => message,
  FileSystemException(:final message, :final path) => path == null ? message : "$message: '$path'",
  FormatException(:final message) => message,
  _ => '$e',
};

bool _isWhite(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x85;
