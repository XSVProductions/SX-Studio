import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app_state.dart';
import '../../tabs.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../settings/settings_model.dart';
import '../settings/update_card.dart';

/// What a tile's small tag means, which sets its color.
enum _Kind { step, live, tool }

/// One Home tile: the tab it opens, its tag and its line of text. The old
/// app's wording.
typedef _TileDef = ({String id, String tag, _Kind kind, String text});

const List<(String, List<_TileDef>)> _sections = [
  (
    'Before the gig',
    [
      (id: 'rt', tag: 'STEP 01', kind: _Kind.step, text: "Which mover hangs where, for the 2D view, Tonight's Rig and Strobe"),
      (id: 'aim', tag: 'STEP 02', kind: _Kind.step, text: "Fit the dance floor and AROUND ROOM to tonight's venue"),
      (id: 'color', tag: 'STEP 03', kind: _Kind.step, text: 'The decor colour on the movers and uplights'),
      (id: 'pre', tag: 'STEP 04', kind: _Kind.step, text: 'One look before the guests arrive'),
    ],
  ),
  (
    'Live',
    [
      (id: 'lab', tag: 'PLAY', kind: _Kind.live, text: "Play your show's buttons straight to the lights, with ShowXpress closed"),
      (id: 'auto', tag: 'AUTO', kind: _Kind.live, text: 'Your looks change every few bars while you mix'),
    ],
  ),
  (
    'Show tools',
    [
      (id: 'rig', tag: 'RIG', kind: _Kind.tool, text: 'Which heads are hung tonight'),
      (id: 'skip', tag: 'RIG', kind: _Kind.tool, text: 'The heads the SKIP FLASH button uses'),
      (id: 'apc', tag: 'CONTROL', kind: _Kind.tool, text: 'Move pads and pick their colours'),
      (id: 'apc40', tag: 'CONTROL', kind: _Kind.tool, text: 'Your own pages of pads for the APC40'),
      (id: 'speed', tag: 'CONTROL', kind: _Kind.tool, text: 'Which fader drives which button'),
      (id: 'health', tag: 'SHOW', kind: _Kind.tool, text: 'Find and fix problems in the show'),
      (id: 'scene', tag: 'SHOW', kind: _Kind.tool, text: 'Change a scene and see it on the lights'),
      (id: 'move', tag: 'SHOW', kind: _Kind.tool, text: "Change a movement's shape and speed"),
      (id: 'look', tag: 'SHOW', kind: _Kind.tool, text: 'Make a new scene from a template'),
      (id: 'settings', tag: 'SETUP', kind: _Kind.tool, text: 'Google Drive, phone & iPad, tabs, light mode, export & import'),
    ],
  ),
];

/// Where a tile goes inside its section on a phone, the old page's
/// `.ph .ht[data-go=...]{order:N}`. A tile not listed has order 0, so it comes
/// first, as in CSS.
const _phoneOrder = {
  'rt': 1,
  'rig': 2,
  'skip': 3,
  'aim': 4,
  'color': 5,
  'pre': 6,
  'auto': 7,
  'lab': 7,
  'apc': 8,
  'apc40': 8,
  'speed': 9,
  'health': 10,
  'settings': 11,
};

/// The tile ids of each section in the order Home shows them: as listed, or
/// on a [phone] by [_phoneOrder], ties kept as listed.
List<List<String>> homeTileOrder({required bool phone}) => [for (final (_, all) in _sections) _ordered(all, phone).map((t) => t.id).toList()];

List<_TileDef> _ordered(List<_TileDef> all, bool phone) {
  if (!phone) return all;
  final i = {for (final (k, t) in all.indexed) t.id: k};
  return [...all]..sort((a, b) {
    final c = (_phoneOrder[a.id] ?? 0).compareTo(_phoneOrder[b.id] ?? 0);
    return c != 0 ? c : i[a.id]!.compareTo(i[b.id]!);
  });
}

/// The start screen: the brand banner, then a tile per tab in the order a gig
/// night runs. A tab hidden in Settings loses its tile, and a section with no
/// tiles left goes too. A phone (the web build) orders the tiles as the old
/// phone page did.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.phone = kIsWeb});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    return ListenableBuilder(listenable: m, builder: (context, _) => _body(m));
  }

  Widget _body(SettingsModel m) => ScreenBody(
    bar: const SaveBar(hint: 'Pick a tab above to start. Nothing in the show changes until you save in a tab.'),
    children: [
      const _Hero(),
      for (final (title, all) in _sections)
        if ([
              for (final t in _ordered(all, phone))
                if (t.id == 'settings' || !m.settings.tabHidden.contains(t.id)) t,
            ]
            case final tiles when tiles.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                child: Text(title.toUpperCase(), style: Sx.label.copyWith(letterSpacing: 1.6, fontWeight: FontWeight.w600)),
              ),
              LayoutBuilder(
                builder: (context, box) {
                  // Rows of equal-height tiles, four across, or two on a narrow screen.
                  final columns = box.maxWidth > 820 ? 4 : 2;
                  return Column(
                    children: [
                      for (var i = 0; i < tiles.length; i += columns)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var c = 0; c < columns; c++) ...[
                                  if (c > 0) const SizedBox(width: 10),
                                  Expanded(child: i + c < tiles.length ? _Tile(tiles[i + c]) : const SizedBox.shrink()),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
    ],
  );
}

/// The banner. It keeps its dark colors in the light theme, as the old one did.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final small = sxGutter(context) < 22;
    const round = BorderRadius.all(Radius.circular(16));
    // Drawn once and kept: hovering a tile or any other change under the
    // banner doesn't draw its gradients and blend again. The gradients carry
    // the rounded corners themselves, so the banner needs no clip.
    return RepaintBoundary(
      child: Container(
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: Sx.line),
          borderRadius: round,
        ),
        decoration: const BoxDecoration(
          borderRadius: round,
          gradient: LinearGradient(begin: Alignment(-.4, -1), end: Alignment(.4, 1), colors: [Color(0xFF10131A), Color(0xFF07080B)]),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: round,
            gradient: RadialGradient(
              center: Alignment(-.84, -1.2),
              radius: .9,
              colors: [Color(0x38A3E635), Color(0x00A3E635)],
              stops: [0, .6],
              transform: _Ellipse(.08, .6 / .9),
            ),
          ),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              borderRadius: round,
              gradient: RadialGradient(
                center: Alignment(1, 1.4),
                radius: .8,
                colors: [Color(0x1A5AA9FF), Color(0x005AA9FF)],
                stops: [0, .6],
                transform: _Ellipse(1, .5 / .8),
              ),
            ),
            child: CustomPaint(
              painter: const _Grid(),
              child: Padding(
                padding: small ? const EdgeInsets.symmetric(horizontal: 18, vertical: 20) : const EdgeInsets.fromLTRB(30, 30, 30, 26),
                child: Row(
                  children: [
                    Image.asset('assets/img/sx_logo.png', height: small ? 104 : 150, filterQuality: FilterQuality.medium),
                    SizedBox(width: small ? 16 : 26),
                    const Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LIGHTING CONTROL FOR SHOWXPRESS',
                            style: TextStyle(fontSize: 12, letterSpacing: 3, fontWeight: FontWeight.w600, color: Color(0xFFA3E635)),
                          ),
                          SizedBox(height: 6),
                          UpdateLine(color: Color(0xFF8B93A3)),
                        ],
                      ),
                    ),
                    if (!small)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 74, maxWidth: 300),
                        child: const _Screen(child: _Brand()),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Stretches a circular gradient into CSS's `ellipse W% H%`: [ratio] is the
/// width share over the height share, and [x] is where the center sits
/// across the box (0 left, 1 right).
class _Ellipse extends GradientTransform {
  const _Ellipse(this.x, this.ratio);

  final double x;
  final double ratio;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final cx = bounds.left + bounds.width * x;
    final stretch = ratio * bounds.width / bounds.shortestSide;
    return Matrix4.identity()
      ..translateByDouble(cx, 0, 0, 1)
      ..scaleByDouble(stretch, 1, 1, 1)
      ..translateByDouble(-cx, 0, 0, 1);
  }
}

/// The faint 26 px grid on the banner's left, fading out to the right.
class _Grid extends CustomPainter {
  const _Grid();

  @override
  void paint(Canvas canvas, Size size) {
    // the banner's rounded corners, the only clip on the page
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)));
    final paint = Paint()
      ..strokeWidth = 1
      ..shader = const LinearGradient(colors: [Color(0x05FFFFFF), Color(0x00FFFFFF)], stops: [0, .75]).createShader(Offset.zero & size);
    for (var x = .5; x < size.width * .75; x += 26) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = .5; y < size.height; y += 26) {
      canvas.drawLine(Offset(0, y), Offset(size.width * .75, y), paint);
    }
  }

  @override
  bool shouldRepaint(_Grid old) => false;
}

/// Paints its child with the "screen" blend, so a logo on a black background
/// shows without the black. The old app's `mix-blend-mode:screen`.
class _Screen extends SingleChildRenderObjectWidget {
  const _Screen({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderScreen();
}

class _RenderScreen extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    context.canvas.saveLayer(offset & size, Paint()..blendMode = BlendMode.screen);
    context.paintChild(child, offset);
    context.canvas.restore();
  }
}

/// The banner's image on the right: the user's own `brand.png` from the
/// settings folder when there is one, otherwise the built-in one.
class _Brand extends StatefulWidget {
  const _Brand();

  @override
  State<_Brand> createState() => _BrandState();
}

class _BrandState extends State<_Brand> {
  Uint8List? _own;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).client.bytes('/brand.png').then((b) {
      if (b != null && mounted) setState(() => _own = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final builtIn = Image.asset('assets/img/brand.png', filterQuality: FilterQuality.medium);
    // a file that isn't a picture falls back to the built-in one
    return switch (_own) {
      final own? => Image.memory(own, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => builtIn),
      null => builtIn,
    };
  }
}

class _Tile extends StatefulWidget {
  const _Tile(this.def);

  final _TileDef def;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final def = widget.def;
    final name = def.id == 'settings' ? 'Settings' : SettingsModel.of(AppScope.read(context)).nameOf(tabs.firstWhere((t) => t.id == def.id));
    return InkWell(
      onTap: () => AppScope.read(context).go(def.id),
      onHover: (h) => setState(() => _hover = h),
      hoverColor: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        foregroundPainter: _TileEdge(hover: _hover),
        child: Container(
          decoration: BoxDecoration(color: _hover ? Sx.hover : Sx.card, borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                def.tag,
                style: TextStyle(
                  fontFamily: Sx.display,
                  fontSize: 9.5,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w600,
                  color: switch (def.kind) {
                    _Kind.step => Sx.accent,
                    _Kind.live => Sx.green,
                    _Kind.tool => Sx.mute,
                  },
                ),
              ),
              const SizedBox(height: 7),
              Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: .2)),
              const SizedBox(height: 2),
              Text(def.text, style: TextStyle(fontSize: 12.5, color: Sx.dim, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile's thin outline, and while [hover] the lime bar along its left
/// edge, cut to the rounded corners. Painted here so the tile needs no clip.
class _TileEdge extends CustomPainter {
  _TileEdge({required this.hover});

  final bool hover;

  /// So a theme switch repaints.
  final light = Sx.isLight;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    if (hover) {
      canvas
        ..save()
        ..clipRRect(r)
        ..drawRect(Rect.fromLTWH(0, 0, 3, size.height), Paint()..color = Sx.accent)
        ..restore();
    }
    canvas.drawDRRect(r, r.deflate(1), Paint()..color = Sx.line);
  }

  @override
  bool shouldRepaint(_TileEdge old) => old.hover != hover || old.light != light;
}
