import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';
import 'lab_board.dart';

/// How a tile looks right now.
typedef TileState = ({bool on, String text});

/// A line of text in a color.
typedef Note = ({String text, Color color});

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
  final tempo = ValueNotifier<(String, String)>(('–', ''));
  final os2l = ValueNotifier<Note>((text: '', color: Sx.dim));
  final midi = ValueNotifier<Note>((text: '', color: Sx.dim));

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

/// One button on the board. Rebuilds only when its own state changes.
class TileView extends StatelessWidget {
  const TileView({
    super.key,
    required this.tile,
    required this.state,
    required this.width,
    required this.idle,
    this.arranging = false,
    this.onTap,
    this.onDelete,
  });

  final LabTile tile;
  final ValueNotifier<TileState> state;
  final double width;

  /// The player isn't running.
  final bool idle;
  final bool arranging;
  final VoidCallback? onTap;

  /// Takes a player page's button off its page (Arrange only).
  final VoidCallback? onDelete;

  static const height = 62.0;

  @override
  Widget build(BuildContext context) {
    final c = tile.color < 0 ? null : Color(0xFF000000 | (tile.color & 0xFFFFFF));
    return ValueListenableBuilder(
      valueListenable: state,
      builder: (context, s, _) {
        final on = s.on && !arranging;
        final edge = on ? Sx.green : (arranging ? Sx.mute : Sx.line);
        final box = Container(
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: on ? const Color(0x173DDC84) : Sx.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: edge),
          ),
          child: Row(
            children: [
              Container(width: 4, color: c ?? (on ? Sx.green : Sx.line2)),
              Expanded(
                child: Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(10, 8, onDelete == null ? 8 : 26, 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            tile.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Sx.text),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            arranging ? tile.label : s.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: on ? Sx.green : Sx.mute, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                    if (onDelete != null)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          onPressed: onDelete,
                          tooltip: 'Take it off this page',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 16, color: Sx.mute),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        return Opacity(
          opacity: tile.missing ? (idle ? .4 : .45) : (idle && !arranging ? .85 : 1),
          child: onTap == null
              ? box
              : MouseRegion(
                  cursor: tile.missing ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: box),
                ),
        );
      },
    );
  }
}

/// Four dots, one more lit on each beat. Wakes once a beat on a timer, never every frame.
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
    final now = DateTime.now();
    final b = beatAt(c, now);
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
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(shape: BoxShape.circle, color: k <= _n ? (k == 0 ? Sx.green : Sx.accent) : Sx.hover),
        ),
    ],
  );
}

/// A line of text that follows a [Note] notifier.
class NoteLine extends StatelessWidget {
  const NoteLine(this.note, {super.key});

  final ValueNotifier<Note> note;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: note,
    builder: (context, n, _) => n.text.isEmpty ? const SizedBox.shrink() : Text(n.text, style: Sx.sub.copyWith(color: n.color)),
  );
}

/// The tempo card: BPM, where it comes from, the beat, tap, type and nudge it.
class BpmCard extends StatelessWidget {
  const BpmCard({super.key, required this.live, required this.input, required this.focus, required this.onTap, required this.onSet, required this.onSync});

  final LabLive live;
  final TextEditingController input;
  final FocusNode focus;

  /// Called on pointer down, so the tap lands on the beat.
  final VoidCallback onTap;

  /// Set the BPM to this (already clamped by the caller).
  final ValueChanged<double> onSet;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 14,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ValueListenableBuilder(
            valueListenable: live.tempo,
            builder: (context, t, _) => SizedBox(
              width: 130,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('TEMPO', style: Sx.label),
                  Text.rich(
                    TextSpan(
                      text: t.$1,
                      style: const TextStyle(fontFamily: Sx.display, fontSize: 26, fontWeight: FontWeight.w700, color: Sx.text),
                      children: const [
                        TextSpan(
                          text: '  BPM',
                          style: TextStyle(fontFamily: Sx.body, fontSize: 13, color: Sx.dim, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Text(t.$2, style: Sx.sub),
                ],
              ),
            ),
          ),
          BeatDots(clock: live.clock),
          Listener(
            onPointerDown: (_) => onTap(),
            child: FilledButton(
              onPressed: () {},
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              child: const Text('Tap'),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Nudge('−', 'Slower', () => onSet(_bpm() - 1)),
              const SizedBox(width: 6),
              SizedBox(
                width: 76,
                child: TextField(
                  controller: input,
                  focusNode: focus,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  onSubmitted: (v) {
                    final b = double.tryParse(v.trim());
                    if (b != null && b >= 40 && b <= 250) onSet(b);
                  },
                ),
              ),
              const SizedBox(width: 6),
              _Nudge('+', 'Faster', () => onSet(_bpm() + 1)),
            ],
          ),
          Tooltip(
            message: 'Press on the first beat of a bar: BPM chases start again from their first step',
            child: OutlinedButton(
              onPressed: onSync,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('Beat 1 now'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      NoteLine(live.os2l),
    ],
  );

  double _bpm() => live.clock.value.bpm == 0 ? 120 : live.clock.value.bpm;
}

class _Nudge extends StatelessWidget {
  const _Nudge(this.text, this.tip, this.onPressed);

  final String text;
  final String tip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '1 BPM ${tip.toLowerCase()}',
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero),
      child: Text(text, style: const TextStyle(fontSize: 18)),
    ),
  );
}

/// The show's speed faders (type 1), each a slider from a quarter to four times speed.
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
        const Text('Speed faders', style: Sx.title),
        const SizedBox(height: 4),
        NoteLine(live.midi),
        const SizedBox(height: 10),
        if (fs.isEmpty) const Text('The show has no speed faders.', style: Sx.sub),
        LayoutBuilder(
          builder: (context, box) {
            final cols = ((box.maxWidth + 22) / (130 + 22)).floor().clamp(1, fs.isEmpty ? 1 : fs.length);
            final w = (box.maxWidth - 22 * (cols - 1)) / cols;
            return Wrap(
              spacing: 22,
              runSpacing: 6,
              children: [
                for (final f in fs)
                  SizedBox(
                    width: w,
                    child: ValueListenableBuilder(
                      valueListenable: live.fader(f.k),
                      builder: (context, v, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.caption.isEmpty ? 'Fader ${f.k + 1}' : f.caption, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: Sx.accent,
                              inactiveTrackColor: Sx.line2,
                              thumbColor: Sx.accent,
                              overlayColor: Colors.transparent,
                              trackHeight: 4,
                            ),
                            child: Slider(value: v.$1.toDouble(), min: 0, max: 127, divisions: 127, onChanged: (x) => onMove(f.k, x.round())),
                          ),
                          Text(v.$2, style: const TextStyle(fontSize: 12, color: Sx.dim)),
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
