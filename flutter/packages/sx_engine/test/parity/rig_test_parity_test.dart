import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';
import 'rig_helpers.dart';

/// `saved` is a timestamp. The old tool also reads it back through PowerShell
/// 7's ConvertFrom-Json, which turns it into a date and prints it in the US
/// format ("11/23/2026 12:17:44"); the port returns it as stored.
Object? _maskSavedJson(Object? j) => j is Map ? {...j, 'saved': '<masked>'} : j;

/// rig_test.json carries the save time, and its `hung` list comes from a
/// hashtable's keys, so its order changes from run to run. So do the id lists
/// on the RIGHEADS and SKIPHEADS lines of the report.
final _applyOptions = ParityOptions(
  rewriteFile: (path, b) => path == 'rig_test.json' ? canonicalJson(b, mask: {'saved'}, sortLists: {'hung'}) : b,
  rewriteText: (t) => t.replaceAllMapped(RegExp(r'^(RIGHEADS|SKIPHEADS): (.*)$', multiLine: true), (m) => '${m[1]}: ${(m[2]!.split(',')..sort()).join(',')}'),
);

Map<String, Object> _changes(Map<String, String> assign, {bool extra = false}) => {'assign': assign, 'extra': extra};

void main() {
  final previewOptions = ParityOptions(rewriteJson: _maskSavedJson);
  parityTest('preview', script: 'rig_test.ps1', args: {'Action': 'Preview'}, options: previewOptions, dart: rtPreview);
  parityTest(
    'preview with nothing saved',
    script: 'rig_test.ps1',
    args: {'Action': 'Preview'},
    setup: (env) => deleteFile(env, 'rig_test.json'),
    dart: rtPreview,
  );
  parityTest(
    'refuses without a 2D view',
    script: 'rig_test.ps1',
    args: {'Action': 'Preview'},
    setup: (env) => deleteFile(env, 'Editor/2DView/fixtures.ini'),
    dart: rtPreview,
  );

  group('apply', () {
    if (paritySkip != null) return;
    final h = ids(realMovers.where((m) => m.is140));
    final four = {'tl-l': h[0], 'tl-r': h[1], 'br-l': h[2], 'br-r': h[3]};
    final six = {...four, 'tm-l': h[4], 'tm-r': h[5]};

    parityTest(
      'four heads on the corner towers',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(four),
      options: _applyOptions,
      dart: (env) => rtApply(env, four, extra: false),
    );
    parityTest(
      'middle towers on a bigger event',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(six, extra: true),
      options: _applyOptions,
      dart: (env) => rtApply(env, six, extra: true),
    );
    parityTest(
      'middle towers are left out without extra',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(six),
      options: _applyOptions,
      dart: (env) => rtApply(env, six, extra: false),
    );
    parityTest(
      'without a saved rig every 251 counts as hung',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(four),
      setup: (env) => deleteFile(env, 'rig_state.json'),
      options: _applyOptions,
      dart: (env) => rtApply(env, four, extra: false),
    );
    parityTest(
      'a head missing from the 2D view is added',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(four),
      setup: (env) {
        final name = realMovers.firstWhere((m) => m.id == h[0]).name;
        editFile(env, 'Editor/2DView/fixtures.ini', (t) => t.replaceFirst('[$name]', '[gone $name]'));
      },
      options: _applyOptions,
      dart: (env) => rtApply(env, four, extra: false),
    );
    parityTest(
      'the same spots again leave the 2D view alone',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(four),
      setup: (env) => rtApply(fixedClock(env), four, extra: false),
      options: _applyOptions,
      dart: (env) {
        final r = rtApply(env, four, extra: false);
        expect(r, contains('nothing to change in the 2D view'));
        return r;
      },
    );
    parityTest(
      'preview reads the spots back',
      script: 'rig_test.ps1',
      args: {'Action': 'Preview'},
      setup: (env) => rtApply(fixedClock(env), six, extra: true),
      options: previewOptions,
      dart: (env) {
        final p = rtPreview(env);
        expect(p.assign, six);
        return p;
      },
    );
    parityTest(
      'refuses an unknown spot',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({'xx-l': h[0]}),
      dart: (env) => rtApply(env, {'xx-l': h[0]}, extra: false),
    );
    parityTest(
      'refuses an unknown head',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({'tl-l': '999'}),
      dart: (env) => rtApply(env, {'tl-l': '999'}, extra: false),
    );
    parityTest(
      'refuses a head in two spots',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({'tl-l': h[0], 'br-r': h[0]}),
      dart: (env) => rtApply(env, {'tl-l': h[0], 'br-r': h[0]}, extra: false),
    );
    parityTest(
      'refuses no heads on a truss',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({'tm-l': h[0], 'tl-r': ''}),
      dart: (env) => rtApply(env, {'tm-l': h[0], 'tl-r': ''}, extra: false),
    );
  });

  group('install', () {
    if (paritySkip != null) return;
    void dropButton(ShowEnv env) =>
        editFile(env, 'Live/live.ini', (t) => t.replaceFirst(RegExp(r'\[page\d+_button\d+\]\r?\n(?:(?!\[)[^\n]*\n)*?name = RIG ID\.scex'), '[x]\nname = gone'));

    parityTest('nothing to change', script: 'rig_test.ps1', args: {'Action': 'Install'}, dart: rtInstall);
    parityTest('makes the scene', script: 'rig_test.ps1', args: {'Action': 'Install'}, setup: (env) => deleteFile(env, 'scenes/RIG ID.scex'), dart: rtInstall);
    parityTest(
      'makes the scene with reversed heads',
      script: 'rig_test.ps1',
      args: {'Action': 'Install'},
      setup: (env) {
        deleteFile(env, 'scenes/RIG ID.scex');
        flipApply(fixedClock(env), {realMovers.first.id: (pan: true, tilt: false), realMovers[1].id: (pan: true, tilt: true)});
      },
      dart: rtInstall,
    );
    parityTest(
      'updates an old scene',
      script: 'rig_test.ps1',
      args: {'Action': 'Install'},
      setup: (env) => editFile(env, 'scenes/RIG ID.scex', (t) => t.replaceAll('value="41"', 'value="26"')),
      dart: rtInstall,
    );
    parityTest(
      'adds the button',
      script: 'rig_test.ps1',
      args: {'Action': 'Install'},
      setup: dropButton,
      dart: (env) {
        final r = rtInstall(env);
        expect(r, contains('added the RIG ID button to the SETUP page'));
        return r;
      },
    );
    parityTest('preview without the button', script: 'rig_test.ps1', args: {'Action': 'Preview'}, setup: dropButton, options: previewOptions, dart: rtPreview);
    parityTest(
      'refuses without a SETUP page',
      script: 'rig_test.ps1',
      args: {'Action': 'Install'},
      setup: (env) {
        dropButton(env);
        editFile(env, 'Live/live.ini', (t) => t.replaceAll(RegExp(r'^name = SETUP', multiLine: true), 'name = SET UP'));
      },
      dart: rtInstall,
    );

    test('without a SETUP page a missing scene is not written either', () {
      final env = copyOfShow();
      deleteFile(env, 'scenes/RIG ID.scex');
      dropButton(env);
      editFile(env, 'Live/live.ini', (t) => t.replaceAll(RegExp(r'^name = SETUP', multiLine: true), 'name = SET UP'));
      final before = snapshot(env);
      expect(() => rtInstall(env), throwsA(isA<ToolError>().having((e) => e.message, 'message', 'No live page called SETUP found. NOTHING was changed.')));
      expect(snapshot(env), before);
    });

    test('a failed state write puts the 2D view back', () {
      final env = copyOfShow();
      final before = snapshot(env);
      blockWrite(env, 'rig_test.json');
      final h = ids(realMovers.where((m) => m.is140));
      expect(() => rtApply(env, {'tl-l': h[0]}, extra: false), throwsA(isA<ToolError>()));
      expect(snapshot(env), before);
    });
  });
}
