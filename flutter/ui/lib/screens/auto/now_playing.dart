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
  const NowPlaying({super.key, required this.status, required this.received, required this.visible});

  final AutoStatus status;

  /// When [status] arrived, to count on from.
  final DateTime received;

  /// The Auto Show tab is on show. Off tab, nothing redraws.
  final bool visible;

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
        ? 'Playing on the SX Player (Lab)${s.src == 'VirtualDJ' ? ' · tempo from VirtualDJ' : s.src == 'tap' ? ' · tapped tempo' : ''}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NOW PLAYING', style: Sx.label),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      text: s.name,
                      children: [
                        if (s.held)
                          const TextSpan(
                            text: '  HELD',
                            style: TextStyle(fontSize: 12, color: Sx.amber, letterSpacing: 1),
                          ),
                      ],
                    ),
                    style: const TextStyle(fontFamily: Sx.display, fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  Text('bar ${p.bar} of ${s.bars} · $next', style: Sx.sub),
                  if (warn.isNotEmpty) Text(warn, style: const TextStyle(color: Sx.amber, fontSize: 13)),
                  if (target.isNotEmpty) Text(target, style: Sx.sub),
                ],
              ),
            ),
            Row(
              children: [
                for (var k = 0; k < 4; k++)
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(left: 6, top: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: k < p.beat ? (k == 0 ? Sx.accent : Sx.green) : Sx.well,
                      border: Border.all(color: Sx.line2),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: p.fraction, minHeight: 6, backgroundColor: Sx.well, color: Sx.green),
        ),
      ],
    );
  }
}
