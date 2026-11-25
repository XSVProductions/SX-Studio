import 'dart:convert';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';
import 'rig_helpers.dart';

/// flip_state.json carries the save time.
final _maskSaved = ParityOptions(rewriteFile: (path, b) => path == 'flip_state.json' ? canonicalJson(b, mask: {'saved'}) : b);

Map<String, Object?> _changes(Map<String, Flip> flip) => {
  'flip': {
    for (final e in flip.entries) e.key: {'pan': e.value.pan, 'tilt': e.value.tilt},
  },
};

void main() {
  parityTest('preview', script: 'flip.ps1', args: {'Action': 'Preview'}, dart: flipPreview);

  group('apply', () {
    if (paritySkip != null) return;
    final a140 = realMovers.firstWhere((m) => m.is140), b140 = realMovers.lastWhere((m) => m.is140);
    final a251 = realMovers.firstWhere((m) => !m.is140);
    // pan on one 140, both on another, tilt on a 251: scenes, movements and
    // Tonight's Rig's kept scenes all change
    final flip = <String, Flip>{a140.id: (pan: true, tilt: false), b140.id: (pan: true, tilt: true), a251.id: (pan: false, tilt: true)};
    void flipped(ShowEnv env) => flipApply(fixedClock(env), flip);

    parityTest(
      'reverses heads everywhere',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(flip),
      options: _maskSaved,
      dart: (env) => flipApply(env, flip),
    );

    // The kept full scenes in the real show have no pan or tilt channels, so
    // give one a pan channel on a head this case reverses.
    late final String keptHead = () {
      final st = RigState.read(ShowEnv(realShowPath!)).scenes.values.first.original;
      return RegExp(r'<Fixture id="(\d+)">').firstMatch(st)![1]!;
    }();
    parityTest(
      "reverses Tonight's Rig's kept full scenes",
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({keptHead: (pan: true, tilt: false)}),
      setup: (env) => editFile(env, 'rig_state.json', (t) {
        final j = (jsonDecode(t) as Map).cast<String, Object?>();
        final scenes = (j['scenes'] as Map).cast<String, Object?>();
        final first = (scenes.values.first as Map).cast<String, Object?>();
        first['original'] = '${first['original']}'.replaceFirst(
          '<Fixture id="$keptHead">',
          '<Fixture id="$keptHead">\n        <Channel index="0" name="pan" value="10"/>',
        );
        scenes[scenes.keys.first] = first;
        return rigPsJson({'hung': j['hung'], 'scenes': scenes});
      }),
      options: _maskSaved,
      dart: (env) {
        final r = flipApply(env, {keptHead: (pan: true, tilt: false)});
        expect(r, contains("1 kept full chase scene(s) of Tonight's Rig too"));
        return r;
      },
    );
    parityTest(
      'without a saved rig',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(flip),
      setup: (env) => deleteFile(env, 'rig_state.json'),
      options: _maskSaved,
      dart: (env) => flipApply(env, flip),
    );
    parityTest('preview after reversing', script: 'flip.ps1', args: {'Action': 'Preview'}, setup: flipped, dart: flipPreview);
    parityTest(
      'one head back, one changed axis',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({b140.id: (pan: false, tilt: true), a251.id: (pan: false, tilt: true)}),
      setup: flipped,
      options: _maskSaved,
      dart: (env) => flipApply(env, {b140.id: (pan: false, tilt: true), a251.id: (pan: false, tilt: true)}),
    );
    parityTest(
      'every head back to normal (state kept empty, not deleted)',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({}),
      setup: flipped,
      dart: (env) {
        final r = flipApply(env, {});
        takeEmptyState(env, 'flip_state.json');
        return r;
      },
    );
    parityTest(
      'the same list again changes nothing',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes(flip),
      setup: flipped,
      dart: (env) => flipApply(env, flip),
    );
    parityTest('nothing reversed and nothing asked', script: 'flip.ps1', args: {'Action': 'Apply'}, changes: _changes({}), dart: (env) => flipApply(env, {}));
    parityTest(
      'a head turned off still counts as named',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({a140.id: (pan: false, tilt: false)}),
      dart: (env) => flipApply(env, {a140.id: (pan: false, tilt: false)}),
    );
    parityTest(
      'refuses an unknown head',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: _changes({'999': (pan: true, tilt: false)}),
      dart: (env) => flipApply(env, {'999': (pan: true, tilt: false)}),
    );
  });

  group('writes', () {
    if (paritySkip != null) return;
    test('a failed state write puts every scene and movement back', () {
      final env = copyOfShow();
      final before = snapshot(env);
      blockWrite(env, 'flip_state.json');
      expect(() => flipApply(env, {realMovers.first.id: (pan: true, tilt: false)}), throwsA(isA<ToolError>()));
      expect(snapshot(env), before);
    });

    test('reversing twice gives back the same bytes', () {
      final env = copyOfShow();
      deleteFile(env, 'flip_state.json');
      final before = snapshot(env);
      flipApply(env, {realMovers.first.id: (pan: true, tilt: true)});
      flipApply(env, {});
      final after = snapshot(env)..removeWhere((k, _) => k.endsWith('flip_state.json') || k.endsWith('rig_state.json'));
      expect(after, {...before}..removeWhere((k, _) => k.endsWith('rig_state.json')));
    });
  });
}
