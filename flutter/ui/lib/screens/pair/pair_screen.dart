import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';

/// Connects a phone or tablet to the laptop with the 6-digit code the
/// laptop shows. Shown by `boot_web.dart` before the app when the phone has
/// no key, or its key stopped working. [onPaired] gets the phone's new key.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.client, required this.onPaired});

  /// A client for the laptop with no key yet.
  final SxClient client;
  final ValueChanged<String> onPaired;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _pin = TextEditingController();
  var _msg = '';
  var _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final v = _pin.text.replaceAll(RegExp(r'\D'), '');
    if (v.length != 6) {
      setState(() => _msg = 'Type the 6 digits from the laptop.');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final key = await widget.client.phonePair(v);
      widget.onPaired(key);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _msg = e.status == null && e.message.startsWith("Can't reach") ? "Can't reach the laptop. Is this phone on the same Wi-Fi?" : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/img/sx_mark.png', height: 56, filterQuality: FilterQuality.medium),
                const SizedBox(height: 16),
                const Text('Connect to the laptop', style: Sx.title, textAlign: TextAlign.center),
                const SizedBox(height: 10),
                const Text(
                  'On the laptop, open SX Studio, press the cogwheel (top right), and in Phone & iPad press Pair a phone. Type the 6-digit code here.',
                  style: Sx.sub,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _pin,
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(hintText: '------'),
                  onChanged: (v) {
                    if (v.length == 6) _pair();
                  },
                  onSubmitted: (_) => _pair(),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: _busy ? null : _pair, child: Text(_busy ? 'Connecting' : 'Connect')),
                ),
                if (_msg.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _msg,
                      style: const TextStyle(color: Sx.redText),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 18),
                const Text(
                  'Tip: first add this page to your Home Screen (Share, then Add to Home Screen), then open it from there and pair. The Home Screen icon keeps its own pairing.',
                  style: TextStyle(fontSize: 12, color: Sx.dim, height: 1.4),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
