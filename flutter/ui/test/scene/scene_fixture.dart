import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';

/// A small scene: two Spot heads, three steps. Step 1 has head 1 lit and
/// head 2 dark, step 2 only head 1 with a closed shutter and a fading
/// dimmer, step 3 both heads.
Map<String, Object?> sceneJson() => {
  'ok': true,
  'show': '/show',
  'file': 'TEST SCENE.scex',
  'name': 'TEST SCENE',
  'sha': 'abc123',
  'used': ['PAGE: TEST'],
  'trimmed': false,
  'readonly': '',
  'structural': true,
  'backups': 0,
  'heads': [
    {'id': '1', 'name': 'Spot 1', 'model': 'Spot', 'addr': 1},
    {'id': '2', 'name': 'Spot 2', 'model': 'Spot', 'addr': 11},
  ],
  'models': {
    'Spot': {
      'chans': [
        {'ix': 0, 'name': 'dimmer'},
        {'ix': 1, 'name': 'shutter'},
        {'ix': 2, 'name': 'color'},
      ],
      'ranges': {
        'shutter': [
          {'n': 'closed', 'lo': 0, 'hi': 7},
          {'n': 'open', 'lo': 8, 'hi': 255},
        ],
      },
    },
  },
  'steps': [
    {
      'len': 50,
      'lenRaw': '50',
      'fx': [
        {
          'id': '1',
          'ch': [
            [0, 'dimmer', 255, 0],
            [1, 'shutter', 255, 0],
          ],
        },
        {
          'id': '2',
          'ch': [
            [0, 'dimmer', 0, 0],
            [1, 'shutter', 255, 0],
          ],
        },
      ],
    },
    {
      'len': null,
      'lenRaw': '',
      'fx': [
        {
          'id': '1',
          'ch': [
            [0, 'dimmer', 100, 1],
            [1, 'shutter', 0, 0],
          ],
        },
      ],
    },
    {
      'len': 200,
      'lenRaw': '200',
      'fx': [
        {
          'id': '1',
          'ch': [
            [0, 'dimmer', 0, 0],
            [1, 'shutter', 255, 0],
          ],
        },
        {
          'id': '2',
          'ch': [
            [0, 'dimmer', 255, 1],
            [1, 'shutter', 255, 0],
          ],
        },
      ],
    },
  ],
};

SceneOpen testScene() => SceneOpen.fromJson(jsonDecode(jsonEncode(sceneJson())) as Map<String, Object?>);

/// A request the fake engine got: its path and JSON body.
typedef Sent = ({String path, Map<String, Object?> body});

/// A fake engine. [answers] gives the reply per path; [sent] collects every
/// POST in order.
SxClient fakeEngine(List<Sent> sent, Map<String, Object? Function(Map<String, Object?> body)> answers) => SxClient(
  Uri.parse('http://engine'),
  token: 't',
  client: MockClient((req) async {
    final body = req.method == 'POST' && req.body.isNotEmpty ? (jsonDecode(req.body) as Map).cast<String, Object?>() : <String, Object?>{};
    if (req.method == 'POST') sent.add((path: req.url.path, body: body));
    final a = answers[req.url.path];
    final out = a == null ? {'ok': false, 'error': 'no route'} : a(body);
    return http.Response.bytes(utf8.encode(jsonEncode(out)), a == null ? 404 : 200, headers: {'content-type': 'application/json'});
  }),
);
