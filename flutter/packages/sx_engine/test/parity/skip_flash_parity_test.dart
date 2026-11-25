import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';
import 'rig_helpers.dart';

void main() {
  parityTest('preview', script: 'skip_flash.ps1', args: {'Action': 'Preview'}, dart: skipPreview);

  group('apply', () {
    if (paritySkip != null) return;
    // every 140 and two 251s: the 251s are spread between the 140s
    final mixed = [...ids(realMovers.where((m) => m.is140)), ...ids(realMovers.where((m) => !m.is140).take(2))];
    final only251 = ids(realMovers.where((m) => !m.is140).take(3));
    late final List<String> now = [
      for (final h in skipPreview(ShowEnv(realShowPath!)).heads)
        if (h.on) h.id,
    ];

    parityTest(
      'rebuilds with 140s and 251s',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': mixed.join(',')},
      dart: (env) => skipApply(env, mixed),
    );
    parityTest(
      'rebuilds with 251s only',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': only251.join(',')},
      dart: (env) => skipApply(env, only251),
    );
    parityTest('preview after a rebuild', script: 'skip_flash.ps1', args: {'Action': 'Preview'}, setup: (env) => skipApply(env, mixed), dart: skipPreview);
    parityTest(
      'the heads it has now change nothing',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': now.join(',')},
      dart: (env) {
        final r = skipApply(env, now);
        expect(r, contains('nothing to change'));
        return r;
      },
    );
    parityTest(
      'a scene with no lit or dark heads falls back to a white flash',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': only251.join(',')},
      setup: (env) => editFile(env, 'scenes/SKIP FLASH.scex', (t) => t.replaceAll(RegExp(r'<Channel [^>]*/>\s*'), '')),
      dart: (env) => skipApply(env, only251),
    );
    parityTest(
      'falls back to SKIP FLASH.scex when no button is titled SKIP FLASH',
      script: 'skip_flash.ps1',
      args: {'Action': 'Preview'},
      setup: (env) => editFile(env, 'Live/live.ini', (t) => t.replaceAll('title = SKIP FLASH', 'title = SKIP FLASHY')),
      dart: skipPreview,
    );
    parityTest(
      'follows the button to another scene file',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': only251.join(',')},
      setup: (env) {
        env.file('scenes/SKIP FLASH.scex').renameSync(env.path('scenes/FLASH SKIPPER.scex'));
        editFile(env, 'Live/live.ini', (t) => t.replaceAll('name = SKIP FLASH.scex', 'name = FLASH SKIPPER.scex'));
      },
      dart: (env) {
        final r = skipApply(env, only251);
        expect(r, contains('FLASH SKIPPER.scex'));
        return r;
      },
    );
    parityTest(
      'refuses when the scene is missing',
      script: 'skip_flash.ps1',
      args: {'Action': 'Preview'},
      setup: (env) => deleteFile(env, 'scenes/SKIP FLASH.scex'),
      dart: skipPreview,
    );
    parityTest('refuses one head', script: 'skip_flash.ps1', args: {'Action': 'Apply', 'Heads': mixed.first}, dart: (env) => skipApply(env, [mixed.first]));
    parityTest(
      'refuses an unknown head',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': '${mixed.first},12;x'},
      dart: (env) => skipApply(env, ['${mixed.first},12;x']),
    );
    parityTest(
      'refuses a scene without <Fixtures>',
      script: 'skip_flash.ps1',
      args: {'Action': 'Apply', 'Heads': mixed.join(',')},
      setup: (env) => editFile(env, 'scenes/SKIP FLASH.scex', (t) => t.replaceAll(RegExp(r'<Fixtures>.*?</Fixtures>', dotAll: true), '<Fixtures/>')),
      dart: (env) => skipApply(env, mixed),
    );
  });
}
