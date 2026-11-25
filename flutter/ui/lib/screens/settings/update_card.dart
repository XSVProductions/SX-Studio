import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../boot/boot.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';
import 'settings_model.dart';

/// Asks, then updates to [u]: the laptop downloads the installer and runs it,
/// and SX Studio closes so the installer can replace it. The old `doUpd`.
Future<void> startUpdate(BuildContext context, UpdateInfo u) async {
  final app = AppScope.read(context);
  final how = u.mac
      ? "SX Studio closes and the Mac installer opens. Follow it, and SX Studio opens again when it's done."
      : 'SX Studio closes and opens again by itself in a few seconds.';
  if (!await confirm(context, 'Update to version ${u.latest}?', "Downloads it from GitHub and installs it. $how Your show isn't touched.", 'Update')) return;
  if (!context.mounted) return;
  final line = ValueNotifier('Downloading the update.');
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder(
            valueListenable: line,
            builder: (context, text, _) => Text(text, style: TextStyle(color: Sx.text, fontSize: 14)),
          ),
        ),
      ),
    ),
  );
  ToolResult r;
  try {
    r = await app.client.updateInstall();
  } on ApiException catch (e) {
    r = ToolResult.failed(e.message);
  }
  if (r.ok && r.extra['restarting'] == true) {
    line.value = u.mac
        ? "Opening the installer. Follow it, and SX Studio opens again when it's done."
        : 'Installing the update. SX Studio opens again by itself.';
    await shutdown();
    await ServicesBinding.instance.exitApplication(AppExitType.required);
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  if (!r.ok || r.out.trim().isNotEmpty) await showReport(context, r.ok ? 'Update' : 'Not updated', r.out, error: r.error);
}

/// The Updates section of Settings: the version, "Check now", and whether
/// SX Studio checks by itself when it opens. Laptop only.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  UpdateInfo? _u;
  var _line = '';

  Future<void> _check() async {
    setState(() => _line = 'Checking GitHub.');
    try {
      final u = await AppScope.read(context).client.update(fresh: true);
      if (!mounted) return;
      setState(() {
        _u = u;
        _line = u.newer ? 'Version ${u.latest} is ready.' : 'Up to date.';
      });
    } on ApiException {
      if (mounted) setState(() => _line = "Couldn't reach GitHub.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    final u = _u;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => SxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SetTitle('Updates'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(fontSize: 13, color: Sx.dim),
                      children: [
                        const TextSpan(text: 'Version '),
                        TextSpan(
                          text: m.ver,
                          style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
                        ),
                        if (_line.isNotEmpty) TextSpan(text: '. $_line'),
                      ],
                    ),
                  ),
                ),
                if (u != null && u.newer)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: MiniButton('Update to ${u.latest}', icon: Icons.arrow_upward, primary: true, onPressed: () => startUpdate(context, u)),
                  ),
                MiniButton('Check now', onPressed: _check),
              ],
            ),
            const SizedBox(height: 10),
            LinkCheck(
              'Check for a new version when SX Studio opens',
              value: m.settings.autoUpd,
              onChanged: (v) => m.save(SettingsChange(autoUpd: v)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home's version line (`#hver`). Shows nothing on a phone.
class UpdateLine extends StatelessWidget {
  const UpdateLine({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        if (!m.loaded || m.phone) return const SizedBox.shrink();
        final u = m.update;
        final more = u == null
            ? ''
            : u.newer
            ? '  ·  version ${u.latest} is available'
            : '  ·  up to date';
        return Text('Version ${m.ver}$more', style: TextStyle(fontSize: 12.5, color: color));
      },
    );
  }
}

/// The header's Update button (`#upd`), there only when GitHub has a newer
/// version.
class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key});

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final u = m.update;
        if (u == null || !u.newer || m.phone) return const SizedBox.shrink();
        return MiniButton('Update to ${u.latest}', icon: Icons.arrow_upward, primary: true, onPressed: () => startUpdate(context, u));
      },
    );
  }
}
