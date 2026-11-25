import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

// The aim maths pinned to what `df_aim.ps1`'s own functions answer for the
// same inputs (run through PowerShell 7, numbers copied exactly). The shapes
// are made up, in the range real movements use. Home and reference sizes are
// the old tool's constants.

const home140 = (22600, 49700), ref140 = (3600, 3400);
const home251 = (34200, 10000), ref251 = (4500, 5000);

List<Pt> pts(String s) => textToPts(s);

String exact(List<Pt> p) => p.map((q) => '${psNum(q.$1)},${psNum(q.$2)}').join(';');

const shapes = [
  '20400,46200;24800,46200;24800,53200;20400,53200',
  '21100,47000;22600,52900;24050,47100;19800,50850;25300,50700',
  '20000,47500;22800,52000;25600,48100;23500,46900;21000,52600;25000,51500',
  '33000,8000;35400,8000;34200,13000',
];

void main() {
  group('headFix', () {
    void pin(PanTilt h, PanTilt r, PanTilt c, PanTilt k, (int, int, int, int, double, double, bool, String) want) {
      final f = headFix(h, r, c, k);
      expect((f.op, f.ot, f.zp, f.zt, f.kp, f.kt, f.sized, f.warn), want);
    }

    test(
      'center and corner set',
      () => pin(home140, ref140, (24000, 48000), (20000, 52000), (1400, -1700, 5, 8, 1.1111111111111112, 1.1764705882352942, true, '')),
    );
    test('corner left on the default is normal size', () => pin(home140, ref140, (21800, 50300), (19000, 53100), (-800, 600, 0, 0, 1, 1, false, '')));
    test(
      'a 251 shrinks one way and grows the other',
      () => pin(home251, ref251, (33000, 11000), (28800, 16500), (-1200, 1000, -3, 5, 0.9333333333333333, 1.1, true, '')),
    );
    test('too far and too close is limited and warned', () {
      pin(home140, ref140, (65000, 49700), (64950, 49650), (32767, 0, -45, -45, 0.3, 0.3, true, 'corner very close/far - size limited, check this head'));
      pin(home251, ref251, (34200, 10000), (20000, 31000), (0, 0, 73, 73, 3, 3, true, 'corner very close/far - size limited, check this head'));
    });
    test(
      'zoom rounds half to even',
      () => pin(home140, ref140, (22600, 49700), (18213, 54287), (0, 0, 10, 16, 1.218611111111111, 1.3491176470588235, true, '')),
    );
    test('a center beyond 32767 warns', () {
      expect(
        headFix(home140, ref140, (22600 - 33000, 49700), defaultCorner(home140, ref140)).warn,
        "CENTER TOO FAR from normal - check this head's step 1 aim",
      );
    });
    test('reset is all zero', () {
      final f = headFix(home140, ref140, (1, 2), (3, 4), reset: true);
      expect((f.op, f.ot, f.zp, f.zt, f.kp, f.kt, f.sized), (0, 0, 0, 0, 1.0, 1.0, false));
    });
  });

  test('scalePts around the middle', () {
    expect(
      [for (final s in shapes) ptsToText(scalePts(pts(s), 1.2, 0.9))],
      [
        '19960,46550;25240,46550;25240,52850;19960,52850',
        '20810,47295;22610,52605;24350,47385;19250,50760;25850,50625',
        '19440,47725;22800,51775;26160,48265;23640,47185;20640,52315;25440,51325',
        '32760,8250;35640,8250;34200,12750',
      ],
    );
  });

  test('mirror pairs points and refuses a lopsided axis', () {
    String m(String s, int a) {
      final r = mirror(pts(s), a);
      return r == null ? 'NO' : exact(r);
    }

    expect(
      [
        for (final s in shapes)
          for (final a in [0, 1]) m(s, a),
      ],
      [
        '20400,46200;24800,46200;24800,53200;20400,53200',
        '20400,46200;24800,46200;24800,53200;20400,53200',
        '21075,47050;22550,52900;24025,47050;19800,50775;25300,50775',
        'NO',
        '20000,47800;22800,52000;25600,47800;22800,46900;20800,52050;24800,52050',
        '20500,47200;23150,52300;25300,48050;23150,47200;20500,52300;25300,51450',
        '33000,8000;35400,8000;34200,13000',
        'NO',
      ],
    );
  });

  test('symShape makes symmetrical and centers on home', () {
    final master = pts('21000,48000;24000,51000');
    expect(
      [
        for (final s in shapes)
          () {
            final r = symShape(pts(s), home140, master, false);
            return '${exact(r.pts)}|${r.note}';
          }(),
      ],
      [
        '20400,46200;24800,46200;24800,53200;20400,53200| (changed in Generator -> made symmetrical + centered)',
        '21125,46575;22600,52425;24075,46575;19850,50300;25350,50300| (changed in Generator -> made symmetrical left/right + centered)',
        '20200,47575;22600,52250;25000,47575;22600,47150;20200,51825;25000,51825| (changed in Generator -> made symmetrical + centered)',
        '21400,47000;23800,47000;22600,52000| (changed in Generator -> made symmetrical left/right + centered)',
      ],
    );
    final only = symShape(pts(shapes[2]), home140, null, true);
    expect(
      '${exact(only.pts)}|${only.note}',
      '19800,47450;22600,51950;25400,48050;23300,46850;20800,52550;24800,51450| (changed in Generator -> moved back to center, shape kept)',
    );
  });

  test('curvePath follows the Generator curve', () {
    final p = curvePath(pts(shapes[1]), 2);
    expect(p.length, 50);
    expect(
      [
        for (final k in [0, 1, 7, 23, 49]) p[k],
      ],
      [(20958.0625, 47298.174999999996), (20926.000000000004, 47822.399999999994), (22096.0, 52329.600000000006), (22161.6, 47939.4), (21100.0, 47000.0)],
    );
    expect(ptsToText(curvePath(pts(shapes[1]), 0)), '22600,52900;24050,47100;19800,50850;25300,50700;21100,47000');
  });

  test('parseSize', () {
    expect(
      [
        for (final s in ['100', '120 90', '110x95', '85.5%', ' 75 , 140 ']) parseSize(s),
      ],
      [(1.0, 1.0), (1.2, 0.9), (1.1, 0.95), (0.855, 0.855), (0.75, 1.4)],
    );
    expect(
      () => parseSize('big'),
      throwsA(isA<ToolError>().having((e) => e.message, 'message', "Size 'big' not understood - use e.g. 100 or 120 90. NOTHING was changed.")),
    );
    expect(() => parseSize('19.5'), throwsA(isA<ToolError>().having((e) => e.message, 'message', 'Size 19.5% is outside 20-300. NOTHING was changed.')));
  });

  test('number text the way PowerShell writes it', () {
    expect(
      [psNum(120.0), psNum(0.29 * 100), psNum(1.1 * 100), psFormat0(112.5), psFormat0(113.5), psFormat0(112.49999999999999)],
      ['120', '29', '110', '113', '114', '113'],
    );
    psFlavor = PsFlavor.ps7;
    addTearDown(() => psFlavor = PsFlavor.winPs51);
    expect([psNum(120.0), psNum(0.29 * 100), psNum(1.1 * 100)], ['120', '28.999999999999996', '110.00000000000001']);
  });
}
