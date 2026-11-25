import 'client.dart';
import 'json.dart';

/// One moving head on the Strobe screen.
class SkipHead {
  const SkipHead({required this.id, required this.label, required this.num, required this.is140, required this.on});

  factory SkipHead.fromJson(Json j) => SkipHead(id: j.str('id'), label: j.str('label'), num: j.integer('num'), is140: j.boolean('is140'), on: j.boolean('on'));

  final String id;
  final String label;
  final int num;
  final bool is140;

  /// True when the SKIP FLASH scene uses this head now.
  final bool on;

  Json toJson() => {'id': id, 'label': label, 'num': num, 'is140': is140, 'on': on};
}

/// What the Strobe screen shows.
class SkipPreview {
  const SkipPreview({
    required this.show,
    required this.scene,
    required this.stepCs,
    required this.unknown,
    required this.heads,
    required this.order,
    required this.order140,
    required this.order251,
  });

  factory SkipPreview.fromJson(Json j) => SkipPreview(
    show: j.str('show'),
    scene: j.str('scene'),
    stepCs: j.integer('stepCs'),
    unknown: j.integer('unknown'),
    heads: j.list('heads', SkipHead.fromJson),
    order: j.strList('order'),
    order140: j.intList('order140'),
    order251: j.intList('order251'),
  );

  final String show;

  /// The scene behind the SKIP FLASH button, without `.scex`.
  final String scene;

  /// Step length in hundredths of a second.
  final int stepCs;

  /// Fixtures in the scene that are not 140s or 251s.
  final int unknown;
  final List<SkipHead> heads;

  /// Labels of the heads in the scene, in flash order.
  final List<String> order;

  /// Flash order by head number, for each model.
  final List<int> order140;
  final List<int> order251;

  /// The flash order for a set of picked heads: 140s in [order140], 251s
  /// spread evenly in between. Same rule as `skip_flash.ps1`.
  List<SkipHead> flashOrder(Set<String> picked) {
    final hs = heads.where((h) => picked.contains(h.id));
    List<SkipHead> pick(bool is140, List<int> ord) {
      final g = hs.where((h) => h.is140 == is140).toList();
      return [for (final n in ord) ...g.where((h) => h.num == n), ...g.where((h) => !ord.contains(h.num))];
    }

    final a = pick(true, order140), b = pick(false, order251), out = <SkipHead>[];
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      final takeA = j >= b.length || (i < a.length && (i + .5) / a.length <= (j + .5) / b.length);
      out.add(takeA ? a[i++] : b[j++]);
    }
    return out;
  }

  Json toJson() => {
    'ok': true,
    'show': show,
    'scene': scene,
    'stepCs': stepCs,
    'unknown': unknown,
    'heads': [for (final h in heads) h.toJson()],
    'order': order,
    'order140': order140,
    'order251': order251,
  };
}

extension SkipFlashApi on SxClient {
  Future<SkipPreview> skip() => get('/api/skip', SkipPreview.fromJson);

  Future<ToolResult> skipApply(List<String> heads) => run('/api/skip/apply', {'heads': heads});
}
