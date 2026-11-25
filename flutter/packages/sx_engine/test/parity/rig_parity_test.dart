import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';
import 'rig_helpers.dart';

/// rig_state.json is written from `@{}` hashtables, so its key order changes
/// from run to run of the old tool.
final _stateOrder = ParityOptions(rewriteFile: (path, b) => path == 'rig_state.json' ? canonicalJson(b) : b);

void main() {
  parityTest('preview', script: 'rig.ps1', args: {'Action': 'Preview'}, dart: rigPreview);
  parityTest('preview with no saved rig', script: 'rig.ps1', args: {'Action': 'Preview'}, setup: (env) => deleteFile(env, 'rig_state.json'), dart: rigPreview);
  parityTest(
    'preview shows reversed heads',
    script: 'rig.ps1',
    args: {'Action': 'Preview'},
    setup: (env) => flipApply(fixedClock(env), {realMovers.first.id: (pan: true, tilt: false), realMovers.last.id: (pan: true, tilt: true)}),
    dart: rigPreview,
  );

  group('apply', () {
    if (paritySkip != null) return;
    // Every 140 but the first, and the first 251: some chase steps go, others stay.
    final some = [...ids(realMovers.where((m) => m.is140).skip(1)), realMovers.firstWhere((m) => !m.is140).id];
    final all = ids(realMovers);
    final two = ids(realMovers.where((m) => m.is140).take(2));

    parityTest(
      'trims for the hung heads',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': some.join(',')},
      options: _stateOrder,
      dart: (env) {
        final r = rigApply(env, some);
        expect(r, contains('CHANGED'));
        return r;
      },
    );
    parityTest(
      'trims from scratch when nothing was saved',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': two.join(',')},
      setup: (env) => deleteFile(env, 'rig_state.json'),
      options: _stateOrder,
      dart: (env) => rigApply(env, two),
    );
    parityTest(
      'the same heads again change nothing',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': some.join(',')},
      setup: (env) => rigApply(env, some),
      options: _stateOrder,
      dart: (env) => rigApply(env, some),
    );
    parityTest(
      'every head puts every scene back (state kept empty, not deleted)',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': all.join(',')},
      dart: (env) {
        final r = rigApply(env, all);
        takeEmptyState(env, 'rig_state.json');
        return r;
      },
    );
    parityTest(
      'every head with nothing saved changes nothing',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': all.join(',')},
      setup: (env) => deleteFile(env, 'rig_state.json'),
      dart: (env) => rigApply(env, all),
    );
    parityTest(
      'a trimmed scene changed in ShowXpress counts as the full scene',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': some.join(',')},
      setup: (env) {
        final trimmed = RigState.read(env).scenes.keys.first;
        editFile(env, 'scenes/$trimmed', (t) => t.replaceFirst('<Steps>', '<Steps>\n    <Step length="7"/>'));
      },
      options: _stateOrder,
      dart: (env) => rigApply(env, some),
    );
    parityTest(
      'preview after a change in ShowXpress',
      script: 'rig.ps1',
      args: {'Action': 'Preview'},
      setup: (env) {
        final trimmed = RigState.read(env).scenes.keys.first;
        editFile(env, 'scenes/$trimmed', (t) => t.replaceFirst('<Steps>', '<Steps>\n    <Step length="7"/>'));
      },
      dart: (env) {
        final p = rigPreview(env);
        expect(p.scenes.where((s) => s.edited), hasLength(1));
        return p;
      },
    );
    parityTest(
      'refuses an unknown head',
      script: 'rig.ps1',
      args: {'Action': 'Apply', 'Heads': '${some.first},999'},
      dart: (env) => rigApply(env, ['${some.first},999']),
    );
    parityTest('refuses no heads', script: 'rig.ps1', args: {'Action': 'Apply', 'Heads': ''}, dart: (env) => rigApply(env, ['']));
    parityTest(
      'refuses a show without CENTER SPOT',
      script: 'rig.ps1',
      args: {'Action': 'Preview'},
      setup: (env) {
        deleteFile(env, 'scenes/CENTER SPOT.scex');
        deleteFile(env, 'scenes/CENTER SPOT (adjust).scex');
      },
      dart: rigPreview,
    );
  });

  group('writes', () {
    if (paritySkip != null) return;
    final some = ids(realMovers.where((m) => m.is140).take(3));

    test('a failed state write puts the scenes back', () {
      final env = copyOfShow();
      deleteFile(env, 'rig_state.json');
      final before = snapshot(env);
      blockWrite(env, 'rig_state.json');
      expect(() => rigApply(env, some), throwsA(isA<ToolError>().having((e) => e.message, 'message', contains('NOTHING was changed'))));
      expect(snapshot(env), before);
    });

    test('an empty state reads as no state', () {
      final env = copyOfShow();
      env.file('rig_state.json').writeAsStringSync(rigEmptyState);
      final p = rigPreview(env);
      expect(p.heads.every((h) => h.on), isTrue);
      expect(p.scenes.any((s) => s.trimmed), isFalse);
    });
  });
}
