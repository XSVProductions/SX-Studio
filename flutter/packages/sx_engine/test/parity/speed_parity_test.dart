import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

void main() {
  parityTest('preview', script: 'speed.ps1', args: {'Action': 'Preview'}, dart: speedPreview);

  // Two real buttons from the show, moved to other faders. One of them has no
  // masterspeedfader key yet, so this covers both replacing and inserting.
  late final List<SpeedChange> moves = () {
    final p = speedPreview(ShowEnv(realShowPath!));
    final keyed = p.buttons.firstWhere((b) => b.hasKey), bare = p.buttons.firstWhere((b) => !b.hasKey, orElse: () => p.buttons.last);
    int other(int f) => p.faders.firstWhere((x) => x.k != f).k;
    return [
      SpeedChange(sec: keyed.sec, title: keyed.title, fader: other(keyed.fader)),
      if (bare.sec != keyed.sec) SpeedChange(sec: bare.sec, title: bare.title, fader: other(bare.fader)),
    ];
  }();

  group('apply', () {
    if (paritySkip != null) return;
    final changes = [for (final c in moves) c.toJson()];
    parityTest('moves buttons to other faders', script: 'speed.ps1', args: {'Action': 'Apply'}, changes: changes, dart: (env) => speedApply(env, moves));

    parityTest(
      'same fader again changes nothing',
      script: 'speed.ps1',
      args: {'Action': 'Apply'},
      changes: changes,
      setup: (env) => speedApply(env, moves),
      dart: (env) => speedApply(env, moves),
    );

    final stale = [SpeedChange(sec: moves.first.sec, title: 'NOT THE TITLE', fader: 0)];
    parityTest(
      'refuses when the title no longer matches',
      script: 'speed.ps1',
      args: {'Action': 'Apply'},
      changes: [for (final c in stale) c.toJson()],
      dart: (env) => speedApply(env, stale),
    );

    final noFader = [SpeedChange(sec: moves.first.sec, title: moves.first.title, fader: 98)];
    parityTest(
      'refuses a fader that is not there',
      script: 'speed.ps1',
      args: {'Action': 'Apply'},
      changes: [for (final c in noFader) c.toJson()],
      dart: (env) => speedApply(env, noFader),
    );
  });
}
