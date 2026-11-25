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
  await runSave(context, app.client.updateInstall, quiet: true);
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

/// For Home: the version line (`#hver`) and an Update button when GitHub has
/// a newer one. Checks once when shown, unless the user turned that off.
/// Shows nothing on a phone.
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
        return Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Version ${m.ver}${u == null
                  ? ''
                  : u.newer
                  ? ', version ${u.latest} is available'
                  : ', up to date'}',
              style: TextStyle(fontSize: 12.5, color: Sx.mute),
            ),
            if (u != null && u.newer) MiniButton('Update to ${u.latest}', icon: Icons.arrow_upward, primary: true, onPressed: () => startUpdate(context, u)),
          ],
        );
      },
    );
  }
}
