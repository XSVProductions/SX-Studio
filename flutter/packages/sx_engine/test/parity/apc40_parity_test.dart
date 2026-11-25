import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

// `apc40.ps1 -Action Info` and `-Action Save` against the port. The layout
// file lives outside the show, so this file runs its own cases: the old tool
// first, then the port with the same layout path, comparing the answer, the
// layout file byte for byte, and that the show was left alone.

late Directory _tmp;
late String _show;

Map<String, List<int>> _snapshot(String dir) => {
  for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) p.relative(f.path, from: dir): f.readAsBytesSync(),
};

/// The Dart answer as the old tool prints it: the old server adds
/// `windows` and `status` itself.
Object? _plain(Apc40Info i) => jsonDecode(
  jsonEncode(
    i.toJson()
      ..remove('windows')
      ..remove('status'),
  ),
);

/// One case. [file] is the layout file's text before the run (null: no
/// file). [save] runs `-Action Save` with this config, else `-Action Info`.
/// [liveIni] rewrites the show's live.ini first.
void _case(String name, {String? file, Object? save, String Function(String text)? liveIni, String layoutName = 'apc40.json'}) {
  test(name, skip: paritySkip, () async {
    final dir = Directory(p.join(_tmp.path, name.replaceAll(RegExp(r'\W+'), '_')))..createSync();
    final show = p.join(dir.path, 'show');
    copyDir(Directory(_show), Directory(show));
    if (liveIni != null) {
      final f = File(p.join(show, 'Live', 'live.ini'));
      f.writeAsStringSync(liveIni(f.readAsStringSync()));
    }
    final lay = File(p.join(dir.path, layoutName));
    void reset() {
      if (lay.existsSync()) lay.deleteSync();
      if (file != null) {
        lay.parent.createSync(recursive: true);
        lay.writeAsStringSync(file);
      }
    }

    final before = _snapshot(show);
    reset();
    final args = <String, Object>{'Action': save == null ? 'Info' : 'Save', 'Layout': lay.path, 'TestRoot': show};
    if (save != null) {
      final cf = File(p.join(dir.path, 'cfg.json'))..writeAsStringSync(jsonEncode(save));
      args['ConfigFile'] = cf.path;
    }
    final old = await runOld('apc40.ps1', args);
    expect(old.exitCode, 0, reason: old.stderr);
    final oldBytes = lay.existsSync() ? forCompare(lay.path, lay.readAsBytesSync()) : null;

    reset();
    final env = ShowEnv(show);
    Object? mine;
    try {
      if (save == null) {
        mine = _plain(apc40Info(env, lay));
      } else {
        final l = saveApc40Layout(lay, (save as Map).cast<String, Object?>());
        mine = _plain(apc40Info(env, lay, layout: l));
      }
    } on ToolError catch (e) {
      mine = {'ok': false, 'error': e.message};
    }
    final newBytes = lay.existsSync() ? lay.readAsBytesSync() : null;

    expect(mine, old.json, reason: 'answer');
    if (oldBytes == null || newBytes == null) {
      expect(newBytes == null, oldBytes == null, reason: 'layout file written by one side only');
    } else {
      expect(utf8.decode(newBytes), utf8.decode(oldBytes), reason: 'layout file text');
      expect(newBytes, oldBytes, reason: 'layout file bytes');
    }
    final after = _snapshot(show);
    expect(after.keys, unorderedEquals(before.keys), reason: 'show files');
    for (final k in before.keys) {
      expect(after[k], before[k], reason: 'show file $k');
    }
  });
}

/// A messy layout with every kind of value the cleaning rules look at.
final Json _messy = {
  'pages': [
    {
      'name': ' A\u0001b\u001f ',
      'pads': {
        '0': {
          'a': 1,
          'b': 'x',
          'c': [1, 2],
          'd': {'e': 1},
        },
        '1': [1, 2],
        '2': true,
        '3': 5,
        '4': 'four',
        '+5': 'p5',
        ' 6 ': 'p6',
        '07': 'p7',
        '40': 'too high',
        '-1': 'too low',
        '8': '  ',
        '9': {},
        '10': null,
        '11': ' padded title ',
        '12': '﻿bom',
        '13': 'quotes " and \\ and <tag> & \'apostrophe\'',
        '14': 'tab\tand\u0002control',
        '15': 'Ünïcödé 灯 🎛',
        'x': 'not a number',
        '39': 'top right',
      },
      'colors': {
        '0': {'on': 5, 'off': '7'},
        '1': {'on': ' 3', 'off': 4},
        '2': {'on': 1},
        '3': {'on': 128, 'off': 1},
        '4': [
          {'on': 2, 'off': 3},
        ],
        '5': {'on': -1, 'off': 3},
        '6': {'on': 'x', 'off': 3},
        '7': {'ON': 9, 'Off': 10},
        '20': {'on': 1, 'off': 1},
        '39': {'on': 127, 'off': 0},
      },
    },
    {'name': 'x' * 40, 'pads': {}},
    {
      'name': '${'y' * 29} z',
      'pads': {'0': 'a'},
    },
    {'name': '', 'pads': 'not an object'},
    {
      'NAME': 'Case',
      'Pads': {'1': 'b'},
    },
    null,
  ],
  'faders': {'1': 5, '2': '6', '3': -1, '0': 1, '10': 2, '9': 'x', ' 5': 3, 'Length': 1, '6': '', '7': true, '8': 0},
};

/// Every `color = ` line of live.ini replaced in turn by [values].
String Function(String) _colors(List<String> values) => (text) {
  var i = 0;
  return text.replaceAllMapped(RegExp(r'^color = .*$', multiLine: true), (m) => 'color = ${i < values.length ? values[i++] : '0'}');
};

/// ShowXpress colours (decimal RGB, as live.ini keeps them) around
/// the hue wheel, at the saturation and brightness edges.
List<String> _sweep() {
  int rgb(double h, double s, double v) {
    final c = v * s, x = c * (1 - ((h / 60) % 2 - 1).abs()), m = v - c;
    final (r, g, b) = switch (h ~/ 60) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    int k(double z) => ((z + m) * 255).round().clamp(0, 255);
    return k(r) << 16 | k(g) << 8 | k(b);
  }

  return [
    for (var h = 0.0; h < 360; h += 2.5) '${rgb(h, 1, 1)}',
    for (final h in [10.0, 40.0, 77.5, 107.5, 127.5, 142.5, 157.5, 180.0, 205.0, 227.5, 252.5, 282.5, 317.5, 347.5]) '${rgb(h, 0.9, 0.6)}',
    for (final s in [0.29, 0.3, 0.31, 0.5]) '${rgb(200, s, 0.8)}',
    for (final v in [0.07, 0.08, 0.09]) '${rgb(30, 1, v)}',
    '0',
    '16777215',
    '8421504',
    '-1',
    '-16776961',
    '33554431',
    ' 5',
    'abc',
    '',
    '12.5',
    '0x10',
  ];
}

void main() {
  setUpAll(() {
    if (paritySkip != null) return;
    _tmp = Directory.systemTemp.createTempSync('sx_apc40_parity_');
    _show = realShowPath!;
  });
  tearDownAll(() {
    if (paritySkip == null) _tmp.deleteSync(recursive: true);
  });

  group('info', () {
    _case('no layout file');
    _case('empty layout file', file: '');
    _case('broken layout file', file: '{"pages":[{"name":"x"');
    _case('layout file with a byte order mark', file: '﻿{"pages":[{"name":"bom","pads":{"3":"STROBE"}}]}');
    _case('messy layout file', file: jsonEncode(_messy));
    _case('a list at the top of the file', file: '[{"pages":[{"name":"one"}]},{"pages":{"name":"two"},"faders":{"2":1}}]');
    _case('a number at the top of the file', file: '0');
    _case('fader value too big in the file', file: '{"pages":[{"name":"p"}],"faders":{"1":3000000000}}');
    final sweep = _sweep();
    for (var i = 0; i < sweep.length; i += 74) {
      _case('button colours ${i ~/ 74 + 1}', liveIni: _colors(sweep.sublist(i, min(i + 74, sweep.length))));
    }
    _case(
      'titles that repeat with other case',
      liveIni: (t) {
        var i = 0;
        return t.replaceAllMapped(RegExp(r'^title = .*$', multiLine: true), (m) => 'title = ${['Same', 'SAME', ' same ', '', 'Other'][i++ % 5]}');
      },
    );
  });

  group('save', () {
    _case('messy layout', save: _messy);
    _case(
      'replaces the file that was there',
      file: '{"pages":[{"name":"old"}]}',
      save: {
        'pages': [
          {
            'name': 'new',
            'pads': {'0': 'A'},
          },
        ],
      },
    );
    _case(
      'more than 8 pages',
      save: {
        'pages': [
          for (var i = 0; i < 11; i++)
            {
              'name': 'P$i',
              'pads': {'$i': 'B$i'},
            },
        ],
      },
    );
    _case(
      'faders missing',
      save: {
        'pages': [
          {'name': 'a'},
        ],
      },
    );
    _case(
      'faders empty',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': {},
      },
    );
    _case(
      'faders null',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': null,
      },
    );
    _case(
      'faders a list',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': [1, 2],
      },
    );
    _case(
      'faders zero',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': 0,
      },
    );
    _case(
      'fractions',
      save: {
        'pages': [
          {
            'name': 1.5,
            'pads': {'0': 2.0, '1': 2.25},
            'colors': {
              '0': {'on': 5.0, 'off': 6.5},
              '1': {'on': 5.0, 'off': 6.0},
            },
          },
        ],
        'faders': {'1': 3.0, '2': 1.5},
      },
    );
    _case(
      'a single page, not a list',
      save: {
        'pages': {
          'name': 'only',
          'pads': {'0': 'A'},
        },
      },
    );
    _case(
      'Pages with a capital',
      save: {
        'Pages': [
          {'name': 'cap'},
        ],
      },
    );
    _case('no pages', save: {'faders': {}});
    _case('empty pages', save: {'pages': []});
    _case(
      'pages of nothing',
      save: {
        'pages': [null],
      },
    );
    _case(
      'fader value too big',
      file: '{"pages":[{"name":"kept"}]}',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': {'1': 3000000000},
      },
    );
    _case(
      'fader text too big',
      save: {
        'pages': [
          {'name': 'a'},
        ],
        'faders': {'1': '99999999999999999999'},
      },
    );
    _case(
      'folder that is not there yet',
      layoutName: 'new/folder/apc40.json',
      save: {
        'pages': [
          {'name': 'a'},
        ],
      },
    );
  });
}
