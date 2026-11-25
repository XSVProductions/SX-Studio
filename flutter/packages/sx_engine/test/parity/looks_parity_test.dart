import 'dart:io';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// Runs looks.ps1 Make and the port on the same look, sent as the same JSON.
/// The look is built from the real show's rig when the test is declared.
/// A case whose name doesn't start with "refuses" must make the scene: a
/// refusal there fails the test instead of being compared.
void _make(String name, Json Function(LookRig rig) look, {void Function(ShowEnv env)? setup}) {
  final made = !name.startsWith('refuses');
  final Json body = look(looksRig(ShowEnv(realShowPath!)));
  parityTest(
    name,
    script: 'looks.ps1',
    args: {'Action': 'Make'},
    changes: body,
    setup: setup,
    dart: (env) {
      try {
        return looksMake(env, LookDraft.fromJson(body));
      } on ToolError catch (e) {
        if (made) fail('refused: ${e.message}');
        rethrow;
      }
    },
  );
}

/// A look from a template, with the template's own name.
Json _template(LookRig rig, LookTemplate t, LookOptions o) {
  final l = buildLook(rig, t, o);
  if (l.err.isNotEmpty) throw StateError(l.err);
  return l.draft('${lookAutoName(t, o, rig.scenes)}.scex').toJson();
}

void main() {
  parityTest('rig', script: 'looks.ps1', args: {'Action': 'Rig'}, dart: looksRig);

  group('make', () {
    if (paritySkip != null) return;

    _make('contrast pairs, every other head', (rig) => _template(rig, LookTemplate.contrast, LookOptions()));
    _make(
      'contrast pairs, halves, no swap, fading, with every light',
      (rig) => _template(
        rig,
        LookTemplate.contrast,
        LookOptions()
          ..split = ContrastSplit.half
          ..swap = false
          ..fade = true
          ..hold = 2.5
          ..on[LookTemplate.contrast]!.addAll({for (final m in rig.models.keys) m: true}),
      ),
    );
    _make(
      'contrast pairs, movers against the other lights',
      (rig) => _template(
        rig,
        LookTemplate.contrast,
        LookOptions()
          ..split = ContrastSplit.type
          ..on[LookTemplate.contrast]!.addAll({for (final m in rig.models.keys) m: true}),
      ),
    );
    _make('colour chase, back and forth', (rig) => _template(rig, LookTemplate.chase, LookOptions()));
    _make(
      'colour chase spread over the heads, fading',
      (rig) => _template(
        rig,
        LookTemplate.chase,
        LookOptions()
          ..spread = true
          ..chaseFade = true
          ..pingPong = false
          ..chaseHold = 0.25,
      ),
    );
    _make('strobe on the beat', (rig) => _template(rig, LookTemplate.strobe, LookOptions()));
    _make(
      'steady UV strobe on every light',
      (rig) => _template(
        rig,
        LookTemplate.strobe,
        LookOptions()
          ..beat = false
          ..strobeColor = 'UV'
          ..strobeOn = 0.03
          ..strobeOff = 0.12
          ..on[LookTemplate.strobe]!.addAll({for (final m in rig.models.keys) m: true}),
      ),
    );
    _make(
      'steady amber strobe',
      (rig) => _template(
        rig,
        LookTemplate.strobe,
        LookOptions()
          ..strobeColor = 'Amber'
          ..beat = false,
      ),
    );
    _make('prism fan', (rig) => _template(rig, LookTemplate.prism, LookOptions()));
    _make(
      'prism fan, still and spinning right',
      (rig) => _template(
        rig,
        LookTemplate.prism,
        LookOptions()
          ..prisms.setAll(0, [PrismSetting(PrismMode.still, 0), PrismSetting(PrismMode.r, 50)])
          ..zoom = 0
          ..focus = 255,
      ),
    );

    // refusals, on real heads
    Json one(LookRig rig, {String? name, Object? len = 10, int ix = 0, int v = 1}) => {
      'name': name ?? 'NEW LOOK.scex',
      'steps': [
        {
          'len': len,
          'f': {
            rig.heads.first.id: [
              [ix, v],
            ],
          },
        },
      ],
    };
    _make('refuses a scene that is already in the show', (rig) => one(rig, name: rig.scenes.first));
    _make('refuses a name that is not a scene', (rig) => one(rig, name: 'x.gpj'));
    _make('refuses a name with a folder in it', (rig) => one(rig, name: r'..\x.scex'));
    _make('refuses a name that starts with a dot', (rig) => one(rig, name: '.x.scex'));
    _make('refuses a name with a space before .scex', (rig) => one(rig, name: 'x .scex'));
    _make(
      'refuses a head that is not in the show',
      (rig) => {
        ...one(rig),
        'steps': [
          {
            'len': 10,
            'f': {
              '999': [
                [0, 1],
              ],
            },
          },
        ],
      },
    );
    _make('refuses a channel the head does not have', (rig) => one(rig, ix: 99));
    _make('refuses a value over 255', (rig) => one(rig, v: 256));
    _make('refuses a negative value', (rig) => one(rig, v: -1));
    _make('refuses a step time of 0', (rig) => one(rig, len: 0));
    _make('refuses a step time over an hour', (rig) => one(rig, len: 360001));
    _make('refuses a step time that is not a whole number', (rig) => one(rig, len: 1.5));
    _make('refuses no steps', (rig) => {...one(rig), 'steps': []});
    _make('refuses too many steps', (rig) => {...one(rig), 'steps': List.filled(257, (one(rig)['steps'] as List).first)});
    _make(
      'refuses a step with no channels',
      (rig) => {
        ...one(rig),
        'steps': [
          {
            'len': 10,
            'f': {rig.heads.first.id: []},
          },
        ],
      },
    );
    _make(
      'refuses a bad channel',
      (rig) => {
        ...one(rig),
        'steps': [
          {
            'len': 10,
            'f': {
              rig.heads.first.id: [
                [3],
              ],
            },
          },
        ],
      },
    );
    _make(
      'refuses a channel twice',
      (rig) => {
        ...one(rig),
        'steps': [
          {
            'len': 10,
            'f': {
              rig.heads.first.id: [
                [0, 1],
                [0, 2],
              ],
            },
          },
        ],
      },
    );
    _make(
      'refuses steps with different heads',
      (rig) => {
        ...one(rig),
        'steps': [
          {
            'len': 10,
            'f': {
              rig.heads[0].id: [
                [0, 1],
              ],
            },
          },
          {
            'len': 10,
            'f': {
              rig.heads[1].id: [
                [0, 1],
              ],
            },
          },
        ],
      },
    );
    _make(
      'makes 256 steps, 0.01 s to 1 hour',
      (rig) => {
        ...one(rig),
        'steps': [
          for (var i = 0; i < 256; i++)
            {
              'len': i == 0
                  ? 1
                  : i == 255
                  ? 360000
                  : i * 7,
              'f': {
                rig.heads.first.id: [
                  [0, i],
                  [1, 255 - i, i % 2],
                ],
              },
            },
        ],
      },
    );
    _make('refuses without fixtures.ini', (rig) => one(rig), setup: (env) => env.file('fixtures.ini').deleteSync());
  });

  parityTest(
    'rig refuses a folder with no scenes',
    script: 'looks.ps1',
    args: {'Action': 'Rig'},
    setup: (env) => Directory(env.path('scenes')).deleteSync(recursive: true),
    dart: looksRig,
  );
}
