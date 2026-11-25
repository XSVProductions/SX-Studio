import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../theme.dart';

/// Connects a phone or tablet to the laptop with the 6-digit code the
/// laptop shows. Shown by `boot_web.dart` before the app when the phone has
/// no key, or its key stopped working. [onPaired] gets the phone's new key.
/// [off] says phone access is turned off on the laptop, as the old
/// `phUnpaired` did.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.client, required this.onPaired, this.off = false});

  /// A client for the laptop with no key yet.
  final SxClient client;
  final ValueChanged<String> onPaired;

  /// The laptop refused this phone because phone access is turned off.
  final bool off;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _pin = TextEditingController();
  var _msg = '';
  late var _off = widget.off;
  var _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final v = _pin.text.replaceAll(RegExp(r'\D'), '');
    if (v.length != 6) {
      setState(() {
        _off = false;
        _msg = 'Type the 6 digits from the laptop.';
      });
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _off = false;
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
  Widget build(BuildContext context) {
    final wide = BoxConstraints(maxWidth: 280);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/img/sx_mark.png', width: 64, height: 64, filterQuality: FilterQuality.medium),
                  const SizedBox(height: 12),
                  Text(
                    'Connect to the laptop',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: Sx.display, fontSize: 21, fontWeight: FontWeight.w600, letterSpacing: .5, color: Sx.text),
                  ),
                  const SizedBox(height: 12),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(fontSize: 13, color: Sx.dim, height: 1.45),
                      children: [
                        const TextSpan(text: 'On the laptop, open '),
                        TextSpan(
                          text: 'SX Studio',
                          style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ': press the cogwheel (top right), and in '),
                        TextSpan(
                          text: 'Phone & iPad',
                          style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' press '),
                        TextSpan(
                          text: 'Pair a phone',
                          style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: '. Type the 6-digit code here.'),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: wide,
                    child: TextField(
                      controller: _pin,
                      autofocus: true,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      textAlign: TextAlign.center,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 30, height: 1, fontWeight: FontWeight.w600, letterSpacing: 10, color: Sx.text),
                      decoration: InputDecoration(
                        hintText: '------',
                        filled: true,
                        fillColor: Sx.well,
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Sx.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Sx.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Sx.accent),
                        ),
                      ),
                      onChanged: (v) {
                        if (v.length == 6) _pair();
                      },
                      onSubmitted: (_) => _pair(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: wide,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: _busy ? null : _pair, child: Text(_busy ? 'Connecting' : 'Connect')),
                    ),
                  ),
                  if (_off)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Phone access is turned off on the laptop (Settings, Phone & iPad).',
                        style: TextStyle(color: Sx.amber, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_msg.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _msg,
                        style: TextStyle(color: Sx.red, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
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
}
