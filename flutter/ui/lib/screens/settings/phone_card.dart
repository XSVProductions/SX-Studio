import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';

/// The Phone & iPad card (`#phcard`): phone access on or off, the addresses
/// a phone opens, the pairing code, and "Unpair all phones". Laptop only.
/// Port of `renderPhone`.
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
    // minutes and "last phone" current, like the old page's 5 second poll.
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
      // the 5 second poll mostly brings the same answer, which needs no redraw
      final old = _p;
      if (old != null && _error.isEmpty && jsonEncode(old.toJson()) == jsonEncode(p.toJson())) return;
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
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SetTitle('Phone & iPad', icon: Icons.phone_iphone),
                    const SizedBox(height: 4),
                    Text(
                      "Use SX Studio from your iPhone or iPad on the same Wi-Fi: rig setup, aim live with your finger, tonight's color, the pre-show check and the Auto Show.",
                      style: Sx.sub,
                    ),
                  ],
                ),
              ),
              LinkCheck('Let my phone and iPad connect', value: p?.on ?? false, onChanged: p == null || _busy ? null : _turn),
            ],
          ),
          ErrorBox(_error),
          if (p != null) ..._body(p),
        ],
      ),
    );
  }

  List<Widget> _body(PhoneInfo p) {
    final sub = TextStyle(fontSize: 13, color: Sx.dim, height: 1.45);
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    if (!p.on) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Off. Tick the box, then open the address it shows in Safari on the iPhone or iPad.', style: sub),
        ),
      ];
    }
    if (!p.running) return [ErrorBox(p.error.isEmpty ? 'The phone connection is not running.' : p.error)];
    String url(String host) => 'http://$host:${p.port}';
    final addresses = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PanelBox(
          title: 'ON THE PHONE OR IPAD, OPEN SAFARI AND GO TO',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.local.isEmpty && p.addrs.isEmpty) Text("This computer isn't on a network right now.", style: TextStyle(color: Sx.red, fontSize: 13)),
              if (p.local.isNotEmpty) _address(url(p.local), 'same at every venue, try this first'),
              for (final a in p.addrs) _address(url(a.ip), a.name),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(
            style: sub,
            children: [
              const TextSpan(text: 'Then '),
              TextSpan(text: 'Share, Add to Home Screen', style: b),
              const TextSpan(text: ' for an app icon. The phone and the laptop must be on the '),
              TextSpan(text: 'same Wi-Fi', style: b),
              const TextSpan(
                text:
                    ". Venue Wi-Fi often keeps devices apart. The surest way is your own small travel router, or the laptop on your iPhone's Personal Hotspot. ",
              ),
              // the old page named pwsh and PowerShell, the program that
              // listened then; now it is SX Studio
              if (p.mac) ...[
                const TextSpan(text: 'If macOS asks whether '),
                TextSpan(text: 'SX Studio', style: b),
                const TextSpan(text: ' may accept incoming connections, press '),
                TextSpan(text: 'Allow', style: b),
                const TextSpan(text: '.'),
              ] else ...[
                const TextSpan(text: 'The first time, Windows may ask whether '),
                TextSpan(text: 'SX Studio', style: b),
                const TextSpan(text: ' may use the network. Tick '),
                TextSpan(text: 'Private networks', style: b),
                const TextSpan(text: ' and press '),
                TextSpan(text: 'Allow', style: b),
                const TextSpan(text: '.'),
              ],
            ],
          ),
        ),
        if (p.lastSeen.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text.rich(
              TextSpan(
                style: sub,
                children: [
                  const TextSpan(text: 'Last phone: '),
                  TextSpan(text: p.lastIp, style: b),
                  TextSpan(text: ', ${whenText(p.lastSeen)}.'),
                ],
              ),
            ),
          ),
      ],
    );
    final pair = PanelBox(
      title: 'PAIR A PHONE',
      center: true,
      child: Column(
        children: [
          if (p.pin.isNotEmpty) ...[
            SelectableText(
              p.pin,
              style: TextStyle(fontFamily: 'monospace', fontSize: 34, height: 1.1, fontWeight: FontWeight.w700, letterSpacing: 8, color: Sx.accent),
            ),
            const SizedBox(height: 6),
            CopyButton(p.pin, label: 'Copy code'),
            const SizedBox(height: 6),
            Text('Type this on the phone. Good for ${max(1, (p.pinLeft / 60).ceil())} more min.', style: sub, textAlign: TextAlign.center),
          ] else ...[
            Text('Each phone or iPad is paired once, with a 6-digit code.', style: sub, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10), textStyle: const TextStyle(fontSize: 14)),
              onPressed: () => _do((c) => c.phonePin()),
              child: const Text('Pair a phone'),
            ),
          ],
          const SizedBox(height: 12),
          MiniButton(
            'Unpair all phones',
            onPressed: () async {
              if (await confirm(context, 'Unpair all phones?', 'Every paired phone and iPad has to be paired again with a new code.', 'Unpair')) {
                await _do((c) => c.phoneUnpair());
              }
            },
          ),
        ],
      ),
    );
    return [
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, box) => box.maxWidth < 700
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [addresses, const SizedBox(height: 18), pair])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: addresses),
                  const SizedBox(width: 18),
                  SizedBox(width: 280, child: pair),
                ],
              ),
      ),
    ];
  }

  /// One address, the old `.phrow` with its `.phaddr` box and Copy button.
  Widget _address(String url, String note) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Sx.well,
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: url,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w600, color: Sx.text),
                ),
                TextSpan(
                  text: '   $note',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: Sx.dim),
                ),
              ],
            ),
          ),
        ),
        CopyButton(url),
      ],
    ),
  );
}
