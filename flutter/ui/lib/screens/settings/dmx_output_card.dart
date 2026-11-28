import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_menu.dart';
import '../../widgets/sx_widgets.dart';

/// Settings > DMX output: which interface SX Studio itself sends DMX
/// through, for the SX Player, Live Aim and previews. ShowXpress keeps its
/// own. New in the Flutter app. Laptop only.
class DmxOutputCard extends StatefulWidget {
  const DmxOutputCard({super.key});

  @override
  State<DmxOutputCard> createState() => _DmxOutputCardState();
}

class _DmxOutputCardState extends State<DmxOutputCard> {
  DmxOutputInfo? _info;
  DmxOutputSettings _edit = const DmxOutputSettings();
  var _error = '';
  var _busy = false;
  final _port = TextEditingController(), _host = TextEditingController(), _first = TextEditingController(), _count = TextEditingController();

  @override
  void initState() {
    super.initState();
    _run((c) => c.dmxOutput());
  }

  @override
  void dispose() {
    for (final c in [_port, _host, _first, _count]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(DmxOutputSettings s) {
    _edit = s;
    _port.text = s.enttecPort;
    _host.text = s.artnetHost;
    _first.text = '${s.artnetFirst}';
    _count.text = '${s.artnetCount}';
  }

  DmxOutputSettings get _fromFields => _edit.copyWith(
    enttecPort: _port.text.trim(),
    artnetHost: _host.text.trim(),
    artnetFirst: (int.tryParse(_first.text.trim()) ?? _edit.artnetFirst).clamp(0, 32767).toInt(),
    artnetCount: (int.tryParse(_count.text.trim()) ?? _edit.artnetCount).clamp(1, 16).toInt(),
  );

  bool get _changed => _info != null && _fromFields != _info!.settings;

  /// Runs [call] and shows its answer. [keepEdits] leaves unsaved fields alone (find, check).
  Future<void> _run(Future<DmxOutputInfo> Function(SxClient c) call, {bool keepEdits = false}) async {
    setState(() => _busy = true);
    try {
      final i = await call(AppScope.read(context).client);
      if (!mounted) return;
      setState(() {
        final edits = _fromFields;
        _info = i;
        _error = '';
        if (keepEdits) {
          _edit = edits;
        } else {
          _fill(i.settings);
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final k = _edit.kind;
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SxHeader(
            'DMX output',
            sub: 'Which interface SX Studio sends DMX through when the SX Player, Live Aim or a preview drives the lights. ShowXpress keeps using its own.',
          ),
          ErrorBox(_error),
          if (i == null && _error.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text('Reading the setting.', style: Sx.sub),
            ),
          if (i != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 340,
              child: SxMenu<DmxOutputKind>(
                items: {for (final o in DmxOutputKind.values) o: o.label},
                value: k,
                onPick: _busy ? null : (v) => setState(() => _edit = _fromFields.copyWith(kind: v)),
              ),
            ),
            if (k.chauvet) _line('Uses the driver from your ShowXpress install, as before. Close ShowXpress while SX Studio drives the lights.'),
            if (k.enttec) ...[
              GroupLabel('Enttec DMX USB Pro'),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (i.ports.isNotEmpty)
                    SizedBox(
                      width: 260,
                      child: SxMenu<String>(
                        items: {'': 'Find it each time', for (final p in i.ports) p: p},
                        value: i.ports.contains(_port.text) || _port.text.isEmpty ? _port.text : null,
                        hint: _port.text,
                        onPick: (v) => setState(() => _port.text = v),
                      ),
                    )
                  else
                    _field(_port, 'COM port, or empty to find it', 220),
                  MiniButton('Find it', icon: Icons.search, onPressed: _busy ? null : () => _run((c) => c.dmxOutputFind(), keepEdits: true)),
                ],
              ),
              _line('Universe 1 only. A DMXking ultraDMX works here too.'),
            ],
            if (k.artnet) ...[
              GroupLabel('Art-Net'),
              Wrap(
                spacing: 14,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _labelled('Send to', _field(_host, 'IP address, or empty for everyone', 240)),
                  _labelled('Universe', _field(_first, '0', 64, number: true)),
                  _labelled('How many', _field(_count, '1', 56, number: true)),
                ],
              ),
              _line('SX Studio universe 1 goes to the Art-Net universe you type (0 is the first, often shown as 0:0:0), the next ones after it. '
                  'You need an Art-Net node, or lights that take Art-Net, on the same network.'),
            ],
            if (i.message.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: Sx.tint(Sx.blue),
                child: Text(i.message, style: TextStyle(color: Sx.text, fontSize: 13)),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _changed
                        ? 'Not saved yet.'
                        : i.busy
                        ? 'SX Studio is sending DMX now. A change applies the next time the player or Live Aim starts.'
                        : 'Saved on this computer.',
                    style: Sx.sub,
                  ),
                ),
                OutlinedButton(onPressed: _busy || _changed ? null : () => _run((c) => c.dmxOutputCheck(), keepEdits: true), child: const Text('Check')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _busy || !_changed ? null : () => setState(() => _fill(i.settings)), child: const Text('Undo')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _busy || !_changed ? null : () => _run((c) => c.dmxOutputSave(_fromFields)), child: const Text('Save')),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: Sx.sub),
  );

  Widget _labelled(String label, Widget field) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(color: Sx.text, fontSize: 13)),
      const SizedBox(width: 8),
      field,
    ],
  );

  Widget _field(TextEditingController c, String hint, double width, {bool number = false}) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      textAlign: number ? TextAlign.right : TextAlign.start,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(hintText: hint, isDense: true),
    ),
  );
}
