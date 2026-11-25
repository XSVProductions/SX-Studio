import 'dart:convert';

import 'package:test/test.dart';

import 'parity.dart';

// The harness's JSON re-layout: Windows PowerShell 5.1 and PowerShell 7 write
// the same state differently, and only what it holds may count.
void main() {
  String lay(String s) => utf8.decode(jsonLayout(utf8.encode(s)));

  test('5.1 and 7 layouts of the same value come out the same', () {
    const ps51 = '{\r\n    "a":  "x \\u003e y",\r\n    "b":  [\r\n              1,\r\n              2.5\r\n          ],\r\n    "c":  {\r\n\r\n          }\r\n}';
    const ps7 = '{\n  "a": "x > y",\n  "b": [\n    1,\n    2.5\n  ],\n  "c": {}\n}';
    expect(lay(ps51), lay(ps7));
    expect(lay(ps7), ps7);
  });

  test('numbers compare by exact value: 1 is 1.0, other digits still differ', () {
    expect(lay('{"beats": 1}'), lay('{"beats": 1.0}'));
    expect(lay('[3, 1E+20, -0.0]'), lay('[3.0, 100000000000000000000, 0]'));
    expect(lay('[1.1]'), isNot(lay('[1.10000000000000001]')));
    expect(lay('[1.1]'), isNot(lay('[1.2]')));
    expect(lay('[0.1, 1E-07, -3, 12.50]'), '[0.1,0.0000001,-3,12.5]');
  });

  test('key order and a byte order mark are kept, one-line files stay compact', () {
    expect(lay('{"b":1, "a":2}'), '{"b":1,"a":2}');
    expect(jsonLayout([0xEF, 0xBB, 0xBF, ...utf8.encode('[ ]')]), [0xEF, 0xBB, 0xBF, ...utf8.encode('[]')]);
  });

  test('text that is not JSON comes back unchanged', () {
    for (final s in ['{"a":', '{not json', '', '[1,]']) {
      expect(lay(s), s);
    }
  });
}
