import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';
import 'auto_logic.dart';

/// The "now playing" lines of a running Auto Show: look, bar, time to the
/// next look, a progress line and four beat marks.
///
/// Redraws four times a second from the last status, the way the old page
/// did, and only while [visible]. No animation runs between redraws.
class NowPlaying extends StatefulWidget {
  const NowPlaying({super.key, required this.status, required this.received, required this.visible, required this.big});

  final AutoStatus status;

  /// When [status] arrived, to count on from.
  final DateTime received;

  /// The Auto Show tab is on show. Off tab, nothing redraws.
  final bool visible;

  /// The style of the look's name (the old `.aubig`).
  final TextStyle big;

  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(NowPlaying old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final want = widget.visible && widget.status.running && !widget.status.held;
    if (want && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    } else if (!want) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final p = lookProgress(s, DateTime.now().difference(widget.received).inMilliseconds.toDouble());
    final next = s.held ? 'held, stays on this look until you resume' : 'next: ${s.next.isEmpty ? s.name : s.next} in ${fmtSeconds((p.leftMs ?? 0) / 1000)}';
    final warn = s.error.isNotEmpty ? s.error : (s.missing.isNotEmpty ? 'Not in the show: ${s.missing.join(', ')}' : '');
    final target = s.target == 'player'
        ? 'Playing on the SX Player (Lab)${s.src == 'VirtualDJ'
              ? ' · tempo from VirtualDJ'
              : s.src == 'tap'
              ? ' · tapped tempo'
              : ''}'
        : '';
    final big = widget.big;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NOW PLAYING', style: Sx.sub.copyWith(fontSize: 11.5, letterSpacing: 1)),
                  Text.rich(
                    TextSpan(
                      text: s.name,
                      children: [
                        if (s.held)
                          TextSpan(
                            text: '  HELD',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Sx.accent),
                          ),
                      ],
                    ),
                    style: big,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('bar ${p.bar} of ${s.bars} · $next', style: Sx.sub),
                  ),
                  if (warn.isNotEmpty) Text(warn, style: TextStyle(color: Sx.amber, fontSize: 13)),
                  if (target.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(target, style: Sx.sub),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            for (var k = 0; k < 4; k++)
              Container(
                width: 18,
                height: 18,
                margin: EdgeInsets.only(left: k == 0 ? 0 : 8),
                decoration: BoxDecoration(shape: BoxShape.circle, color: k < p.beat ? (k == 0 ? Sx.green : Sx.accent) : Sx.tabOn),
              ),
          ],
        ),
        // the old `.auprog`
        Container(
          height: 8,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Sx.hover, borderRadius: BorderRadius.circular(99)),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: p.fraction.clamp(0, 1).toDouble(),
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: LinearGradient(colors: [Sx.green, Sx.accent])),
            ),
          ),
        ),
      ],
    );
  }
}
