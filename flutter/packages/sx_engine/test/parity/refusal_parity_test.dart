/// Old versus new for refusals the other parity files don't reach: every
/// write while ShowXpress is open (Google Drive's are in its own file), an
/// empty Speed save, and a show without movers for Reverse Heads.
///
/// The old tools skip their ShowXpress check under `-TestRoot`, so the open
/// cases run them as on the laptop (`parityTest(sxOpen: true)`).
///
/// Not here, because no request reaches them: the old server always writes
/// the changes file before it runs `flip.ps1`, `rig_test.ps1 -Action Apply`
/// and `looks.ps1 -Action Make` (`df_aim_gui.ps1`, `/api/rig/apply`,
/// `/api/rt/apply`, `/api/looks/make`), so their "No changes were sent" and
/// "No look was sent" refusals never show.
library;

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// A changes file the old tool never reads: it refuses first.
const _unread = {'unread': true};

void main() {
  group('ShowXpress is open', () {
    parityTest(
      'speed',
      script: 'speed.ps1',
      args: {'Action': 'Apply'},
      changes: [const SpeedChange(sec: 'page1_button1', title: 'X', fader: 0).toJson()],
      sxOpen: true,
      dart: (env) => speedApply(env, const [SpeedChange(sec: 'page1_button1', title: 'X', fader: 0)]),
    );
    parityTest(
      'apc',
      script: 'apc.ps1',
      args: {'Action': 'Apply'},
      changes: [const ApcChange(sec: 'page1_button1', title: 'X', note: 1).toJson()],
      sxOpen: true,
      dart: (env) => apcApply(env, const [ApcChange(sec: 'page1_button1', title: 'X', note: 1)]),
    );
    parityTest('color', script: 'color.ps1', args: {'Action': 'Apply', 'Color': 'ff0000'}, sxOpen: true, dart: (env) => colorApply(env, 'ff0000'));
    parityTest(
      'reverse heads',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: {'flip': <String, Object?>{}},
      sxOpen: true,
      dart: (env) => flipApply(env, {}),
    );
    parityTest('rig', script: 'rig.ps1', args: {'Action': 'Apply', 'Heads': '1,2'}, sxOpen: true, dart: (env) => rigApply(env, ['1', '2']));
    parityTest('skip flash', script: 'skip_flash.ps1', args: {'Action': 'Apply', 'Heads': '1,2'}, sxOpen: true, dart: (env) => skipApply(env, ['1', '2']));
    parityTest('rig test install', script: 'rig_test.ps1', args: {'Action': 'Install'}, sxOpen: true, dart: rtInstall);
    parityTest(
      'rig test apply',
      script: 'rig_test.ps1',
      args: {'Action': 'Apply'},
      changes: _unread,
      sxOpen: true,
      dart: (env) => rtApply(env, {'tl-l': '1'}, extra: false),
    );
    parityTest(
      'health fix',
      script: 'health.ps1',
      args: {'Action': 'Fix', 'FixId': 'speed|page1_button1'},
      sxOpen: true,
      dart: (env) => healthFix(env, 'speed|page1_button1'),
    );
    parityTest(
      'scene save',
      script: 'scene_edit.ps1',
      args: {'Action': 'Save'},
      changes: _unread,
      sxOpen: true,
      dart: (env) => sceneSave(
        env,
        const SceneChanges(scene: 'X.scex', sha: '', steps: []),
        backupBase: p.join(p.dirname(env.root), 'scene_backups'),
      ),
    );
    parityTest(
      'scene revert',
      script: 'scene_edit.ps1',
      args: {'Action': 'Revert', 'Scene': 'X.scex', 'Backup': '20200101-120000-000'},
      sxOpen: true,
      dart: (env) => sceneRevert(env, 'X.scex', '20200101-120000-000', backupBase: p.join(p.dirname(env.root), 'scene_backups')).out,
    );
    parityTest(
      'movement save',
      script: 'move_edit.ps1',
      args: {'Action': 'Save'},
      changes: _unread,
      sxOpen: true,
      dart: (env) => moveSave(env, {'move': 'X.gpj'}, backups: p.join(p.dirname(env.root), 'move_backups')),
    );
    parityTest(
      'movement revert',
      script: 'move_edit.ps1',
      args: {'Action': 'Revert', 'Move': 'X.gpj', 'Backup': '20200101-120000-000'},
      sxOpen: true,
      dart: (env) => moveRevert(env, 'X.gpj', '20200101-120000-000', backups: p.join(p.dirname(env.root), 'move_backups')),
    );
    for (final (action, more) in [
      ('Apply', {'Size': '100 100'}),
      ('Home', <String, Object>{}),
      ('Install', <String, Object>{}),
    ]) {
      parityTest(
        'aim ${action.toLowerCase()}',
        script: 'df_aim.ps1',
        args: {'Action': action, 'Mode': 'Floor', 'NoPrompt': true, ...more},
        sxOpen: true,
        dart: (env) => switch (action) {
          'Apply' => aimApply(env, AimMode.floor, size: '100 100'),
          'Home' => aimHome(env, AimMode.floor),
          _ => aimInstall(env, AimMode.floor),
        },
      );
    }
  });

  // not a refusal: the One-Click Looks tab says ShowXpress is open
  parityTest('looks rig while ShowXpress is open', script: 'looks.ps1', args: {'Action': 'Rig'}, sxOpen: true, dart: looksRig);

  parityTest('speed with no changes', script: 'speed.ps1', args: {'Action': 'Apply'}, changes: const <Object?>[], dart: (env) => speedApply(env, const []));

  group('a show without movers', () {
    // CENTER SPOT lists the movers. Emptied, the show has none.
    void noMovers(ShowEnv env) {
      for (final f in ['CENTER SPOT.scex', 'CENTER SPOT (adjust).scex']) {
        final file = env.file(p.join('scenes', f));
        if (file.existsSync()) file.writeAsStringSync('<?xml version="1.0" encoding="utf-8"?>\r\n<Scene>\r\n  <Fixtures>\r\n  </Fixtures>\r\n</Scene>\r\n');
      }
    }

    parityTest('reverse heads preview', script: 'flip.ps1', args: {'Action': 'Preview'}, setup: noMovers, dart: flipPreview);
    parityTest(
      'reverse heads apply',
      script: 'flip.ps1',
      args: {'Action': 'Apply'},
      changes: {'flip': <String, Object?>{}},
      setup: noMovers,
      dart: (env) => flipApply(env, {}),
    );
  });
}
