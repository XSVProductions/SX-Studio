import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';

/// The Phone & iPad card: phone access on or off, the addresses a phone
/// opens, the pairing code, and the paired phones. Laptop only.
class PhoneCard extends StatefulWidget {
  const PhoneCard({super.key});

  @override
  State<PhoneCard> createState() => _PhoneCardState();
}

class _PhoneCardState extends State<PhoneCard> {
  PhoneInfo? _p;
  var _error = '';
  var _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // While phone access is on and Settings is showing, keep the code's
    // minutes and "last phone" current.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && (_p?.on ?? false) && AppScope.read(context).tab == 'settings') _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() => _do((c) => c.phone());

  Future<void> _do(Future<PhoneInfo> Function(SxClient c) call) async {
    try {
      final p = await call(AppScope.read(context).client);
      if (mounted) {
        setState(() {
          _p = p;
          _error = '';
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _turn(bool on) async {
    setState(() => _busy = true);
    await _do((c) => c.phoneSet(on));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SxHeader(
            'Phone & iPad',
            sub:
                "Use SX Studio from your iPhone or iPad on the same Wi-Fi: rig setup, aim live with your finger, tonight's color, the pre-show check and the Auto Show.",
          ),
          const SizedBox(height: 6),
          CheckRow('Let my phone and iPad connect', value: p?.on ?? false, onChanged: p == null || _busy ? null : _turn),
          ErrorBox(_error),
          if (p != null) ..._body(p),
        ],
      ),
    );
  }

  List<Widget> _body(PhoneInfo p) {
    if (!p.on) return const [Text('Off. Tick the box, then open the address it shows in Safari on the iPhone or iPad.', style: Sx.sub)];
    if (!p.running) return [ErrorBox(p.error.isEmpty ? 'The phone connection is not running.' : p.error)];
    String url(String host) => 'http://$host:${p.port}';
    final addresses = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ON THE PHONE OR IPAD, OPEN SAFARI AND GO TO', style: Sx.label),
        const SizedBox(height: 6),
        if (p.local.isEmpty && p.addrs.isEmpty) const Text("This computer isn't on a network right now.", style: TextStyle(color: Sx.red)),
        if (p.local.isNotEmpty) _address(url(p.local), 'same at every venue, try this first'),
        for (final a in p.addrs) _address(url(a.ip), a.name),
        const SizedBox(height: 8),
        Text(
          'Then Share, Add to Home Screen for an app icon. The phone and the laptop must be on the same Wi-Fi. '
          "Venue Wi-Fi often keeps devices apart. The surest way is your own small travel router, or the laptop on your iPhone's Personal Hotspot. "
          '${p.mac ? 'If macOS asks whether SX Studio may accept incoming connections, press Allow.' : 'The first time, Windows may ask whether SX Studio may use the network. Tick Private networks and press Allow.'}',
          style: Sx.sub,
        ),
        if (p.lastSeen.isNotEmpty) Text('Last phone: ${p.lastIp}, ${whenText(p.lastSeen)}.', style: Sx.sub),
      ],
    );
    final pair = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PAIR A PHONE', style: Sx.label),
        const SizedBox(height: 6),
        if (p.pin.isNotEmpty) ...[
          Row(
            children: [
              SelectableText(
                p.pin,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 6, color: Sx.accent),
              ),
              CopyButton(p.pin, label: 'Copy code'),
            ],
          ),
          Text('Type this on the phone. Good for ${(p.pinLeft / 60).ceil().clamp(1, 10)} more min. One phone per code.', style: Sx.sub),
        ] else ...[
          const Text('Each phone or iPad is paired once, with a 6-digit code.', style: Sx.sub),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => _do((c) => c.phonePin()), child: const Text('Pair a phone')),
        ],
        const SizedBox(height: 14),
        Text('PAIRED (${p.phones.length})', style: Sx.label),
        const SizedBox(height: 4),
        if (p.phones.isEmpty) const Text('None yet.', style: Sx.sub),
        for (final ph in p.phones)
          Row(
            children: [
              Expanded(
                child: Text(
                  [ph.name, if (ph.paired.isNotEmpty) 'paired ${whenText(ph.paired)}', if (ph.lastSeen.isNotEmpty) 'seen ${whenText(ph.lastSeen)}'].join(', '),
                  style: const TextStyle(fontSize: 13, color: Sx.text2),
                ),
              ),
              TextButton(onPressed: () => _do((c) => c.phoneUnpair(ph.id)), child: const Text('Unpair')),
            ],
          ),
        if (p.phones.length > 1)
          TextButton(
            onPressed: () async {
              if (await confirm(context, 'Unpair all phones?', 'Every paired phone and iPad has to be paired again with a new code.', 'Unpair')) {
                await _do((c) => c.phoneUnpair('*'));
              }
            },
            child: const Text('Unpair all phones'),
          ),
      ],
    );
    return [
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (context, box) => box.maxWidth < 640
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [addresses, const SizedBox(height: 18), pair])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: addresses),
                  const SizedBox(width: 24),
                  SizedBox(width: 300, child: pair),
                ],
              ),
      ),
    ];
  }

  Widget _address(String url, String note) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(url, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
            Text(note, style: const TextStyle(fontSize: 12, color: Sx.mute)),
          ],
        ),
      ),
      CopyButton(url),
    ],
  );
}
