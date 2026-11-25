import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';
import 'settings_model.dart';

/// Asks to update to [u] and opens its release page on the laptop. The new
/// app's installer isn't decided yet, so nothing is downloaded here.
Future<void> startUpdate(BuildContext context, UpdateInfo u) async {
  final app = AppScope.read(context);
  if (!await confirm(
    context,
    'Update to version ${u.latest}?',
    "The release page opens in the browser on the laptop. Download the installer there and run it. Your show isn't touched.",
    'Open the release page',
  )) {
    return;
  }
  if (!context.mounted) return;
  await runSave(context, app.client.updateInstall);
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
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => SxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SxHeader(
              'Updates',
              actions: [
                if (_u case final u? when u.newer) FilledButton(onPressed: () => startUpdate(context, u), child: Text('Update to ${u.latest}')),
                OutlinedButton(onPressed: _check, child: const Text('Check now')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Version ${m.ver}${_line.isEmpty ? '' : '. $_line'}', style: Sx.sub),
            const SizedBox(height: 6),
            CheckRow(
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

/// One line for Home: the version, and an Update button when GitHub has a
/// newer one. Checks once when shown, unless the user turned that off. Shows
/// nothing on a phone.
class UpdateNotice extends StatefulWidget {
  const UpdateNotice({super.key});

  @override
  State<UpdateNotice> createState() => _UpdateNoticeState();
}

class _UpdateNoticeState extends State<UpdateNotice> {
  UpdateInfo? _u;
  var _asked = false;

  Future<void> _ask(SettingsModel m) async {
    _asked = true;
    try {
      final u = await m.client.update();
      if (mounted) setState(() => _u = u);
    } on ApiException {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = SettingsModel.of(AppScope.of(context));
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        if (!m.loaded || m.phone) return const SizedBox.shrink();
        if (!_asked && m.settings.autoUpd) _ask(m);
        final u = _u;
        return Row(
          children: [
            Expanded(
              child: Text(
                'Version ${m.ver}${u == null
                    ? ''
                    : u.newer
                    ? '. Version ${u.latest} is available'
                    : '. Up to date'}',
                style: Sx.sub,
              ),
            ),
            if (u != null && u.newer) FilledButton(onPressed: () => startUpdate(context, u), child: Text('Update to ${u.latest}')),
          ],
        );
      },
    );
  }
}
