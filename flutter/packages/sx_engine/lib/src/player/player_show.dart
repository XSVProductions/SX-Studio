import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import 'cs_compat.dart';
import 'player_core.dart';

// What the SX Player reads from the show before it plays: the live board,
// ShowXpress's MIDI and OS2L settings, the start tempo, and the list the
// SX Player screen draws its buttons from.

final _intRx = RegExp(r'^-?\d+$');
final _digitsRx = RegExp(r'^\d+$');
final _extRx = RegExp(r'\.(scex|gpj)$', caseSensitive: false);

int _int(String? v, int d) => _intRx.hasMatch(v ?? '') ? int.parse(v!) : d;

/// A button's title, or its file name without the extension when it has none.
String _title(LiveButton b) => b.title.isNotEmpty ? b.title : b.name.replaceFirst(_extRx, '');

/// `[double]::TryParse` of live.ini `beats`: 0 when it isn't a number (the
/// failed parse writes 0 over the default of 1).
double _beats(String? v) => csDouble(v ?? '') ?? 0;

/// Loads live.ini's buttons and master faders into [core]. Returns the
/// number of buttons. Port of `Set-PlayerBoard`.
int loadPlayerBoard(PlayerCore core, ShowEnv env) {
  final info = LiveInfo.read(env);
  core.clearBoard();
  for (final f in info.faders) {
    final n = f.k + 1;
    // A fader on another controller gets no CC: the player only listens to the APC mini (MIDI device 0).
    final ty = _int(info.live['fader${n}_midi_device'], 0) != 0 ? -1 : _int(info.live['fader${n}_midi_type'], -1);
    core.addFader(f.k, f.type == '1', _int(info.live['fader${n}_midi_channel'], 1), ty == 1 ? _int(info.live['fader${n}_midi_note'], -1) : -1);
  }
  final swap = <int>{};
  final pageRx = RegExp(r'^page(\d+)$', caseSensitive: false);
  for (final (name, keys) in info.sections) {
    final m = pageRx.firstMatch(name);
    if (m != null && psEq(keys['swap'] ?? '', 'yes')) swap.add(int.parse(m[1]!));
  }
  for (final b in info.buttons) {
    final k = b.keys;
    final path = scenePath(env, b.name) ?? '';
    // Only the APC mini's pads (MIDI device 0). A button on another controller (the APC40) isn't on a pad here.
    final note = _int(k['trigger_midi_type'], -1) == 0 && _int(k['trigger_midi_device'], 0) == 0 ? _int(k['trigger_midi_note'], -1) : -1;
    final onote = _int(k['trigger_midiout_type'], -1) == 0 && _int(k['trigger_midiout_device'], 0) == 0 ? _int(k['trigger_midiout_note'], -1) : -1;
    core.addButton(
      b.sec,
      path,
      _title(b),
      b.page,
      swap.contains(b.page),
      _int(k['masterspeedfader'], 0),
      k['trigger_keyboard'] ?? '',
      _int(k['trigger_midi_channel'], 1),
      note,
      _int(k['trigger_midiout_channel'], 1),
      onote,
      _int(k['trigger_midiout_data'], 0),
      _int(k['trigger_midiout_data_off'], 0),
    );
    if (psEq(k['speed'] ?? '', 'auto_bpm')) core.setBeat(b.sec, psEq(k['bpm_trigger'] ?? '', 'flash_mode'), _beats(k['beats']));
  }
  return core.buttons;
}

/// ShowXpress's own MIDI and OS2L choices, from `param.ini` two folders above
/// the show. Port of `Get-MidiNames`.
class PlayerDevices {
  const PlayerDevices({this.midiIn = '', this.midiOut = '', this.os2lPort = 7350});

  /// Read from the show at [root].
  factory PlayerDevices.read(String root) {
    final f = File(p.join(p.dirname(p.dirname(root)), 'param.ini'));
    var midiIn = '', midiOut = '', os2l = 0;
    var inOff = false, outOff = false, os2lOff = false;
    if (f.existsSync()) {
      RegExp rx(String s) => RegExp(s, caseSensitive: false);
      final port = rx(r'^OS2LPORT = (\d+)'), os2lNo = rx(r'^OS2LENABLE = no');
      final inDev = rx(r'^MIDIINDEVICE = (.*)$'), outDev = rx(r'^MIDIOUTDEVICE = (.*)$');
      final inNo = rx(r'^MIDIENABLE = no'), outNo = rx(r'^MIDIOUTENABLE = no');
      for (final l in readLines(f.path)) {
        final pm = port.firstMatch(l);
        if (pm != null) {
          os2l = int.parse(pm[1]!);
        } else if (os2lNo.hasMatch(l)) {
          os2lOff = true;
        }
        final im = inDev.firstMatch(l), om = outDev.firstMatch(l);
        if (im != null) {
          midiIn = im[1]!.trim();
        } else if (om != null) {
          midiOut = om[1]!.trim();
        } else if (inNo.hasMatch(l)) {
          inOff = true;
        } else if (outNo.hasMatch(l)) {
          outOff = true;
        }
      }
    }
    if (os2l == 0) os2l = 7350;
    return PlayerDevices(midiIn: inOff ? '' : midiIn, midiOut: outOff ? '' : midiOut, os2lPort: os2lOff ? 0 : os2l);
  }

  /// MIDI device names, '' for none.
  final String midiIn, midiOut;

  /// VirtualDJ's OS2L port, 0 when OS2L is off.
  final int os2lPort;
}

/// The Auto Show's BPM (`auto_show.json`), else 120. live.ini `manual_bpm`
/// is ShowXpress's sound-to-light setting, not a tempo. Port of `Get-StartBpm`.
double playerStartBpm(String root) {
  final f = File(p.join(root, 'auto_show.json'));
  if (!f.existsSync()) return 120;
  try {
    final j = jsonDecode(readText(f.path));
    if (j is Map && j['bpm'] is num) {
      final b = (j['bpm'] as num).toDouble();
      if (b >= 40 && b <= 250) return b;
    }
  } on FormatException {
    // not JSON: the default
  }
  return 120;
}

/// The show's live pages and buttons for the SX Player screen, and every
/// scene and movement file its own pages can use. Reads only.
///
/// Port of `player.ps1 -List`.
Json playerList(ShowEnv env) {
  final info = LiveInfo.read(env);
  final root = env.root;
  bool pageSwap(int pg) {
    for (final (name, keys) in info.sections) {
      if (psEq(name, 'page$pg')) return psEq(keys['swap'] ?? '', 'yes');
    }
    return false;
  }

  final pages = [
    for (final pg in psSorted<int>(info.pages.keys, [(n) => n]))
      {
        'n': pg,
        'name': info.pages[pg],
        'swap': pageSwap(pg),
        'buttons': [
          for (final b in psSorted<LiveButton>(info.buttons.where((b) => b.page == pg), [
            (b) => psInt('0${b.keys['line'] ?? ''}'),
            (b) => psInt('0${b.keys['column'] ?? ''}'),
          ]))
            _listButton(env, b),
        ],
      },
  ];
  final files = <String>[];
  void addFiles(String dir, bool Function(String name) keep) {
    final d = Directory(p.join(root, dir));
    if (!d.existsSync()) return;
    for (final e in d.listSync().whereType<File>()) {
      final n = p.basename(e.path);
      if (keep(n)) files.add(n);
    }
  }

  addFiles('scenes', (n) {
    final x = p.extension(n).toLowerCase();
    return x == '.scex' || x == '.gpj';
  });
  addFiles('Editor/Generator/projects', (n) => n.toLowerCase().endsWith('.gpj'));
  final unique = <String>[];
  for (final n in psSorted<String>(files, [(n) => n])) {
    if (unique.isEmpty || !psEq(unique.last, n)) unique.add(n);
  }
  return {
    'ok': true,
    'show': root,
    'pages': pages,
    'faders': [for (final f in info.faders) f.toJson()],
    'files': unique,
  };
}

Json _listButton(ShowEnv env, LiveButton b) {
  final k = b.keys;
  final path = scenePath(env, b.name);
  final kind = path == null ? 'missing' : (path.toLowerCase().endsWith('.gpj') ? 'gpj' : 'scex');
  final steps = kind == 'scex' ? RegExp(r'<Step[ >]').allMatches(readText(path!)).length : 0;
  final color = k['color'] ?? '';
  final pad = k['trigger_midi_note'] ?? '';
  // A pad only on the APC mini, MIDI device 0 (or no device written).
  final onApcMini = RegExp(r'^0?$').hasMatch(k['trigger_midi_device'] ?? '');
  return {
    'sec': b.sec,
    'title': _title(b),
    'file': b.name,
    'path': path ?? '',
    'kind': kind,
    'steps': steps,
    'line': psInt('0${k['line'] ?? ''}'),
    'col': psInt('0${k['column'] ?? ''}'),
    'color': _digitsRx.hasMatch(color) ? int.parse(color) : -1,
    'bpm': psEq(k['speed'] ?? '', 'auto_bpm'),
    'fader': psInt('0${k['masterspeedfader'] ?? ''}'),
    'key': k['trigger_keyboard'] ?? '',
    'flash': psEq(k['bpm_trigger'] ?? '', 'flash_mode'),
    'beats': _beats(k['beats']),
    'pad': _digitsRx.hasMatch(pad) && onApcMini ? int.parse(pad) : -1,
  };
}
