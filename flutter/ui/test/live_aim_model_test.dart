import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/screens/aim/live_aim_model.dart';

LiveHead _head(String id, int addr, {String partner = '', bool free = true, PanTilt c = (22600, 49700)}) => LiveHead(
  id: id,
  label: 'H$id',
  is140: true,
  addr: addr,
  look: const [(5, 255), (6, 200)],
  dimI: 5,
  shutI: 6,
  c: c,
  k: (19000, 53100),
  home: (22600, 49700),
  dk: (19000, 53100),
  kSet: false,
  free: free,
  partner: partner,
  tower: 'TOWER 1',
  side: partner.isEmpty ? '' : 'L',
  order: int.parse(id),
  hung: true,
  deg: (540, 270),
  rp: false,
  rt: false,
);

LiveAimModel _model(List<LiveHead> heads) => LiveAimModel(
  LiveAimInfo(show: 's', mode: 'Floor', aimTitle: 'DF AIM (ADJUST)', heads: heads),
  mode: AimMode.floor,
  flipOf: (_) => (x: false, y: false),
);

void main() {
  test('a head on a T-bar shows its partner aim until it is aimed itself', () {
    final m = _model([_head('1', 1, partner: '2', free: false, c: (30000, 40000)), _head('2', 17, partner: '1')]);
    final a = m.heads[0], b = m.heads[1];
    expect(m.copies(b), isTrue);
    expect(m.pos(b, AimStep.center), (30000.0, 40000.0));
    expect(m.nav(), [a], reason: 'Next skips a head that only copies');

    m.select(b);
    m.move(10, 0);
    expect(m.copies(b), isFalse);
    expect(m.pos(b, AimStep.center), (30100.0, 40000.0), reason: "starts from the partner's aim, 10 steps a pixel");
    expect(m.aimsToSave().keys, ['2']);
  });

  test('tilt moves the same angle as pan, up is up, Shift is finer', () {
    final m = _model([_head('1', 1)]);
    m.move(0, -4, fine: true);
    // 4 px x 10 x 0.25 x (540 / 270)
    expect(m.pos(m.sel, AimStep.center), (22600.0, 49720.0));
  });

  test('back to normal on an aimed head saves the normal center and the default corner', () {
    final m = _model([_head('1', 1, free: false, c: (30000, 40000))]);
    m.backToNormal();
    final saved = m.aimsToSave()['1']!;
    expect((saved.c, saved.k), ((22600, 49700), (19000, 53100)));
  });

  test('stepping past the last head goes to the corners', () {
    final m = _model([_head('1', 1), _head('2', 17)]);
    m.stepTo(1);
    expect(m.sel.id, '2');
    m.stepTo(1);
    expect((m.step, m.sel.id), (AimStep.corner, '1'));
  });

  test('the output sends only what changed, and the first send clears and jumps', () {
    final m = _model([_head('1', 1), _head('2', 17)]);
    final b = LiveOutputBuffer()..push(m, snap: true);
    expect(b.take(), 'z s:1:2:22600 s:3:4:49700 b:6:255 b:7:200 s:17:18:22600 s:19:20:49700 b:22:0 b:23:0');
    b.push(m);
    expect(b.take(), '', reason: 'nothing changed');
    m.move(1, 0);
    b.push(m);
    expect(b.take(), 'p:1:2:22610');
  });

  test('one request at a time, the rest goes together after it', () async {
    final m = _model([_head('1', 1)]);
    final b = LiveOutputBuffer()..push(m, snap: true);
    final sent = <String>[];
    var reply = Completer<ToolResult>();
    final pump = LiveOutputPump(
      b,
      send: (l) {
        sent.add(l);
        return reply.future;
      },
      onGone: (_) {},
    );
    addTearDown(pump.close);
    pump.kick();
    for (var i = 0; i < 5; i++) {
      m.move(1, 0);
      b.push(m);
      pump.kick();
    }
    expect(sent.length, 1);
    final first = reply;
    reply = Completer<ToolResult>();
    first.complete(const ToolResult(ok: true));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(sent, hasLength(2));
    expect(sent[1], 'p:1:2:22650');
  });
}
