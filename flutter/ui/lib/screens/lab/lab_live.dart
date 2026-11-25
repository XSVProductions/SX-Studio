import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'lab_board.dart';

/// How a tile looks right now.
typedef TileState = ({bool on, String text});

/// Which [Sx] color a line uses. Kept instead of the color itself, so a
/// theme switch reaches lines already on screen.
enum Tone {
  dim,
  green,
  amber,
  red;

  Color get color => switch (this) {
    dim => Sx.dim,
    green => Sx.green,
    amber => Sx.amber,
    red => Sx.red,
  };
}

/// A line of text in a [Tone].
typedef Note = ({String text, Tone tone});

/// A status line: dim text after a dot in [dot]'s color, hollow when [hollow],
/// none when [dot] is null.
typedef DotNote = ({String text, Tone? dot, bool hollow});

/// The beat clock: [beat] was the beat count at [at]. It runs on by itself
/// at [bpm] until the next status moves it.
typedef BeatClock = ({double bpm, double beat, DateTime at});

double beatAt(BeatClock c, DateTime now) => c.bpm == 0 ? 0 : c.beat + now.difference(c.at).inMicroseconds * c.bpm / 60e6;

/// Everything on the screen that changes with the player's status, one
/// notifier per piece. A poll sets them all and only the pieces whose value
/// changed rebuild.
class LabLive {
  final _tiles = <String, ValueNotifier<TileState>>{};
  final _pages = <String, ValueNotifier<int>>{};
  final _faders = <int, ValueNotifier<(int, String)>>{};

  final bo = ValueNotifier(false);
  final clock = ValueNotifier<BeatClock>((bpm: 0, beat: 0, at: DateTime.now()));

  /// The BPM as shown, and where it came from.
  final tempo = ValueNotifier<(String, String)>(('-', ''));
  final os2l = ValueNotifier<DotNote>((text: '', dot: null, hollow: false));
  final midi = ValueNotifier<DotNote>((text: '', dot: null, hollow: false));

  /// The interface is unplugged.
  final lost = ValueNotifier(false);

  /// Show check problems, one per line.
  final warn = ValueNotifier('');

  /// The message line under the controls.
  final msg = ValueNotifier<Note?>(null);

  /// The value a tile shows before any status: off, with its kind.
  ValueNotifier<TileState> tile(LabTile t) => _tiles.putIfAbsent(t.sec, () => ValueNotifier((on: false, text: t.label)));

  /// How many buttons play on a collapsed page.
  ValueNotifier<int> pageOn(String id) => _pages.putIfAbsent(id, () => ValueNotifier(0));

  /// A fader's slider position (0 to 127) and its speed text.
  ValueNotifier<(int, String)> fader(int k) => _faders.putIfAbsent(k, () => ValueNotifier((64, faderText(.5))));

  void dispose() {
    for (final n in [..._tiles.values, ..._pages.values, ..._faders.values, bo, clock, tempo, os2l, midi, lost, warn, msg]) {
      n.dispose();
    }
  }
}

/// One button on the board, the old page's `.lbb`. Rebuilds only when its
/// own state changes.
class TileView extends StatefulWidget {
  const TileView({
    super.key,
    required this.tile,
    required this.state,
    required this.width,
    required this.idle,
    this.arranging = false,
    this.onTap,
    this.onMenu,
    this.onDelete,
  });

  final LabTile tile;
  final ValueNotifier<TileState> state;
  final double width;

  /// The player isn't running.
  final bool idle;
  final bool arranging;
  final VoidCallback? onTap;

  /// Opens the button's menu at a screen position: right-click, or a long
  /// press outside Arrange (where a press drags).
  final void Function(Offset at)? onMenu;

  /// Takes a player page's button off its page (Arrange only).
  final VoidCallback? onDelete;

  @override
  State<TileView> createState() => _TileViewState();
}

class _TileViewState extends State<TileView> {
  var _hover = false;
  var _down = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tile;
    // The button's own color from live.ini: show data, the same in both themes.
    final own = t.color < 0 ? null : Color(0xFF000000 | (t.color & 0xFFFFFF));
    return ValueListenableBuilder(
      valueListenable: widget.state,
      builder: (context, s, _) {
        final on = s.on && !widget.arranging;
        final hover = _hover && !t.missing && !widget.arranging;
        final edge = on
            ? Sx.green
            : widget.arranging
            ? Sx.line2
            : hover
            ? Sx.accent
            : Sx.line;
        final box = Container(
          width: widget.width,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: on ? Sx.green.withValues(alpha: .09) : Sx.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: edge),
            // `box-shadow: 0 0 0 1px`: a second line around a playing button.
            boxShadow: on ? [BoxShadow(color: Sx.green.withValues(alpha: .45), spreadRadius: 1)] : null,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: own ?? (on ? Sx.green : (hover ? Sx.accent : Sx.line2))),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(7, 9, widget.onDelete == null ? 11 : 26, 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Sx.text, height: 1.3),
                        ),
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            children: [
                              if (on)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Icon(Icons.play_arrow, size: 13, color: Sx.green),
                                ),
                              TextSpan(text: widget.arranging ? t.label : s.text),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: on ? Sx.green : Sx.mute, fontWeight: on ? FontWeight.w600 : FontWeight.w400, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        final opacity = widget.arranging
            ? 1.0
            : t.missing
            ? (widget.idle ? .4 : .45)
            : (widget.idle ? .85 : 1.0);
        return Stack(
          children: [
            Opacity(
              opacity: opacity,
              child: widget.onTap == null && widget.onMenu == null
                  ? box
                  : MouseRegion(
                      cursor: widget.onTap == null
                          ? MouseCursor.defer
                          : t.missing
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.click,
                      onEnter: (_) => setState(() => _hover = true),
                      onExit: (_) => setState(() => _hover = false),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
                        onTapUp: widget.onTap == null ? null : (_) => setState(() => _down = false),
                        onTapCancel: widget.onTap == null ? null : () => setState(() => _down = false),
                        onTap: widget.onTap,
                        onSecondaryTapUp: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
                        onLongPressStart: widget.onMenu == null || widget.onTap == null ? null : (d) => widget.onMenu!(d.globalPosition),
                        // `.lbb:active{transform:scale(.97)}`
                        child: Transform.scale(scale: _down ? .97 : 1, child: box),
                      ),
                    ),
            ),
            if (widget.onDelete != null)
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: widget.onDelete,
                  tooltip: 'Take it off this page',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 15, color: Sx.mute),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Four dots, one more lit on each beat (`.aubeats`). Wakes once a beat on
/// a timer, never every frame.
class BeatDots extends StatefulWidget {
  const BeatDots({super.key, required this.clock});

  final ValueNotifier<BeatClock> clock;

  @override
  State<BeatDots> createState() => _BeatDotsState();
}

class _BeatDotsState extends State<BeatDots> {
  Timer? _t;
  var _n = -1;

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_tick);
    _tick();
  }

  void _tick() {
    _t?.cancel();
    final c = widget.clock.value;
    final b = beatAt(c, DateTime.now());
    final n = c.bpm == 0 ? -1 : b.floor() % 4;
    if (n != _n) setState(() => _n = n);
    if (c.bpm == 0) return;
    final toNext = (b.floor() + 1 - b) * 60e6 / c.bpm;
    _t = Timer(Duration(microseconds: toNext.ceil() + 1000), _tick);
  }

  @override
  void dispose() {
    _t?.cancel();
    widget.clock.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var k = 0; k < 4; k++)
        Container(
          width: 18,
          height: 18,
          margin: EdgeInsets.only(right: k < 3 ? 8 : 0),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: k <= _n ? (k == 0 ? Sx.green : Sx.accent) : Sx.tabOn,
            boxShadow: k <= _n ? [BoxShadow(color: (k == 0 ? Sx.green : Sx.accent).withValues(alpha: .6), blurRadius: 12)] : null,
          ),
        ),
    ],
  );
}

/// A small round dot, the old page's `&#9679;` and `&#9675;`.
class Dot extends StatelessWidget {
  const Dot(this.tone, {super.key, this.hollow = false});

  final Tone tone;
  final bool hollow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Icon(hollow ? Icons.circle_outlined : Icons.circle, size: 9, color: tone.color),
  );
}

/// A status line that follows a [DotNote] notifier.
class DotLine extends StatelessWidget {
  const DotLine(this.note, {super.key});

  final ValueNotifier<DotNote> note;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: note,
    builder: (context, n, _) => n.text.isEmpty
        ? const SizedBox.shrink()
        : Text.rich(
            TextSpan(
              children: [
                if (n.dot case final d?)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Dot(d, hollow: n.hollow),
                  ),
                TextSpan(text: n.text),
              ],
            ),
            style: TextStyle(fontSize: 13, color: Sx.dim, height: 1.4),
          ),
  );
}

/// The tempo card (`#lbbpm`): BPM, where it comes from, the beat, tap, type and nudge it.
class BpmCard extends StatelessWidget {
  const BpmCard({super.key, required this.live, required this.input, required this.focus, required this.onTap, required this.onSet, required this.onSync});

  final LabLive live;
  final TextEditingController input;
  final FocusNode focus;

  /// Called on pointer down, so the tap lands on the beat.
  final VoidCallback onTap;

  /// Set the BPM to this (the caller clamps it).
  final ValueChanged<double> onSet;
  final VoidCallback onSync;

  double _bpm() => live.clock.value.bpm == 0 ? 120 : live.clock.value.bpm;

  @override
  Widget build(BuildContext context) {
    final phone = sxGutter(context) < 22;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ValueListenableBuilder(
              valueListenable: live.tempo,
              builder: (context, t, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TEMPO', style: TextStyle(fontSize: 11.5, letterSpacing: 1, color: Sx.dim)),
                  Text.rich(
                    TextSpan(
                      text: t.$1,
                      style: TextStyle(
                        fontFamily: Sx.display,
                        fontSize: phone ? 22 : 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .5,
                        color: Sx.text,
                        height: 1.15,
                      ),
                      children: [
                        TextSpan(
                          text: ' BPM',
                          style: TextStyle(fontFamily: Sx.body, fontSize: 13, color: Sx.dim, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Text(t.$2, style: TextStyle(fontSize: 13, color: Sx.dim)),
                ],
              ),
            ),
            BeatDots(clock: live.clock),
            Listener(
              onPointerDown: (_) => onTap(),
              child: Tooltip(
                message: 'Tap along with the beat',
                child: FilledButton(onPressed: () {}, child: const Text('Tap')),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconMini(Icons.remove, () => onSet(_bpm() - 1), tip: '1 BPM slower'),
                const SizedBox(width: 6),
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: input,
                    focusNode: focus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 15, color: Sx.text),
                    decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    onSubmitted: (v) {
                      final b = double.tryParse(v.trim());
                      if (b != null && b >= 40 && b <= 250) onSet(b);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                IconMini(Icons.add, () => onSet(_bpm() + 1), tip: '1 BPM faster'),
              ],
            ),
            Tooltip(
              message: 'Press on the first beat of a bar: BPM chases start again from their first step',
              child: OutlinedButton(onPressed: onSync, child: const Text('Beat 1 now')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DotLine(live.os2l),
      ],
    );
  }
}

/// A `.mini` button with only an icon in it.
class IconMini extends StatelessWidget {
  const IconMini(this.icon, this.onPressed, {super.key, this.tip, this.on = false});

  final IconData icon;
  final VoidCallback onPressed;
  final String? tip;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final b = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        backgroundColor: on ? Sx.green.withValues(alpha: .1) : Sx.hover,
        foregroundColor: on ? Sx.green : Sx.text,
        side: BorderSide(color: on ? Sx.green : Sx.line),
      ),
      child: Icon(icon, size: 15),
    );
    return tip == null ? b : Tooltip(message: tip!, child: b);
  }
}

/// The show's speed faders (type 1), each a slider from a quarter to four
/// times speed (`#lbfd`).
class FadersCard extends StatelessWidget {
  const FadersCard({super.key, required this.live, required this.faders, required this.onMove});

  final LabLive live;
  final List<MasterFader> faders;

  /// Slider [k] moved to [pos] (0 to 127).
  final void Function(int k, int pos) onMove;

  @override
  Widget build(BuildContext context) {
    final fs = faders.where((f) => f.isSpeed).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Speed faders', style: Sx.title),
        const SizedBox(height: 4),
        DotLine(live.midi),
        const SizedBox(height: 10),
        if (fs.isEmpty) Text('The show has no speed faders.', style: Sx.sub),
        LayoutBuilder(
          builder: (context, box) {
            // `flex: 1 1 200px` with a 22 px gap.
            final cols = ((box.maxWidth + 22) / (200 + 22)).floor().clamp(1, fs.isEmpty ? 1 : fs.length);
            final w = (box.maxWidth - 22 * (cols - 1)) / cols;
            return Wrap(
              spacing: 22,
              runSpacing: 10,
              children: [
                for (final f in fs)
                  SizedBox(
                    width: w,
                    child: ValueListenableBuilder(
                      valueListenable: live.fader(f.k),
                      builder: (context, v, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.caption.isEmpty ? 'Fader ${f.k + 1}' : f.caption,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Sx.text),
                          ),
                          SizedBox(
                            height: 26,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: Sx.accent,
                                inactiveTrackColor: Sx.line2,
                                thumbColor: Sx.accent,
                                overlayColor: Colors.transparent,
                                trackHeight: 4,
                                padding: EdgeInsets.zero,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                              ),
                              child: Slider(value: v.$1.toDouble(), min: 0, max: 127, divisions: 127, onChanged: (x) => onMove(f.k, x.round())),
                            ),
                          ),
                          Text(v.$2, style: TextStyle(fontSize: 12, color: Sx.dim)),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
