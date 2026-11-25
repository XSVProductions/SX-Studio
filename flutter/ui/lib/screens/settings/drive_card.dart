import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';
import 'settings_model.dart';

/// The Google Drive card (`#gdcard`): is Google Drive here, Sync, Import,
/// and on the laptop the My Drive folder and the import backups. In the old
/// app it sits in Settings; Home can show it too.
class DriveCard extends StatefulWidget {
  const DriveCard({super.key});

  @override
  State<DriveCard> createState() => _DriveCardState();
}

class _DriveCardState extends State<DriveCard> {
  DriveInfo? _g;
  var _error = '';
  final _folder = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final g = await AppScope.read(context).client.gdrive();
      if (!mounted) return;
      setState(() {
        _g = g;
        _error = '';
        _folder.text = g.override;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _import(DriveInfo g) async {
    final app = AppScope.read(context);
    final saved = g.srcTime.isEmpty ? '' : ' (saved ${whenText(g.srcTime)})';
    if (!await confirm(
      context,
      'Import the show from Google Drive?',
      'The show on this computer is replaced by the Google Drive copy$saved. Anything changed here since then is lost. The old show is kept as a backup.'
          '${app.sxOpen ? '\n\nShowXpress is open: this waits until you close it.' : ''}',
      'Import',
    )) {
      return;
    }
    if (!mounted) return;
    await runSave(context, app.client.gdriveImport, after: _load);
  }

  Future<void> _setFolder(String v) async {
    final err = await SettingsModel.of(AppScope.read(context)).save(SettingsChange(driveFolder: v));
    if (!mounted) return;
    if (err.isNotEmpty) {
      setState(() => _error = err);
      return;
    }
    await _load();
  }

  Future<void> _open(OpenTarget what) async {
    final r = await AppScope.read(context).client.openOnComputer(what);
    if (mounted) setState(() => _error = r.ok ? '' : r.error);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final phone = SettingsModel.of(app).phone;
    final g = _g;
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    final sub = TextStyle(fontSize: 13, color: Sx.dim, height: 1.45);

    Widget account() {
      if (g == null) return Text('Looking for Google Drive.', style: sub);
      if (g.found) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(Icons.check, size: 15, color: Sx.green),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: sub,
                  children: [
                    const TextSpan(text: 'Google Drive is signed in'),
                    if (g.account.isNotEmpty) ...[const TextSpan(text: ' as '), TextSpan(text: g.account, style: b)],
                    const TextSpan(text: '. It uploads and downloads the show by itself.'),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      return Text(
        g.appFound
            ? 'Google Drive is installed but not signed in. Press Open Google Drive and sign in with the AWAAZ Google account.'
            : "Google Drive for desktop isn't on this computer. Press Get Google Drive, install it and sign in.",
        style: sub.copyWith(color: Sx.amber),
      );
    }

    Widget what(DriveInfo g) {
      if (!g.found) {
        return Text.rich(
          TextSpan(
            style: sub,
            children: [
              const TextSpan(text: "Google Drive isn't on this computer. Install "),
              TextSpan(text: 'Google Drive for desktop', style: b),
              const TextSpan(text: ' and sign in.'),
            ],
          ),
        );
      }
      return Text.rich(
        TextSpan(
          style: sub,
          children: [
            const TextSpan(text: 'Copies the show to '),
            TextSpan(text: g.target, style: b),
            const TextSpan(text: '. New and changed files go up, and a file deleted here since the last sync is removed there. '),
            if (g.last.isEmpty)
              const TextSpan(text: 'Not synced yet.')
            else ...[
              const TextSpan(text: 'Last sync: '),
              TextSpan(text: whenText(g.last), style: b),
              const TextSpan(text: '.'),
            ],
            const TextSpan(text: '\n'),
            TextSpan(text: 'Import', style: b),
            const TextSpan(text: ' copies the show from Google Drive into '),
            TextSpan(text: g.show, style: b),
            const TextSpan(text: ' and replaces the one on this computer'),
            if (g.srcFound)
              TextSpan(text: ' (Google Drive copy saved ${whenText(g.srcTime)})')
            else ...[
              const TextSpan(text: ', '),
              TextSpan(
                text: 'no show on Google Drive yet',
                style: TextStyle(color: Sx.amber),
              ),
            ],
            const TextSpan(text: '.'),
            if (g.lastImport.isNotEmpty) ...[
              const TextSpan(text: ' Last import: '),
              TextSpan(text: whenText(g.lastImport), style: b),
              const TextSpan(text: '.'),
            ],
          ],
        ),
      );
    }

    final buttons = g == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: g.found && g.here ? () => runSave(context, app.client.gdriveSync, after: _load) : null,
                child: const Text('Sync to Google Drive'),
              ),
              const SizedBox(height: 6),
              OutlinedButton(onPressed: g.found && g.srcFound ? () => _import(g) : null, child: const Text('Import from Google Drive')),
            ],
          );

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
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SetTitle('Google Drive'), const SizedBox(height: 4), account()]),
              ),
              if (!phone)
                Wrap(
                  spacing: 6,
                  children: [
                    if (g != null && g.appFound)
                      MiniButton(g.found ? 'Open Google Drive' : 'Sign in to Google Drive', onPressed: () => _open(OpenTarget.gdapp)),
                    MiniButton('Get Google Drive', onPressed: () => _open(OpenTarget.gddl)),
                  ],
                ),
            ],
          ),
          if (g != null) ...[
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, box) {
                final text = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    what(g),
                    if (g.found && app.sxOpen)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'ShowXpress is open. This is queued and done as soon as you save and close ShowXpress.',
                          style: TextStyle(color: Sx.amber, fontSize: 13),
                        ),
                      ),
                  ],
                );
                return box.maxWidth < 560
                    ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [text, const SizedBox(height: 12), buttons])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: text),
                          const SizedBox(width: 10),
                          SizedBox(width: 230, child: buttons),
                        ],
                      );
              },
            ),
          ],
          ErrorBox(_error),
          if (!phone && g != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Details(
                'Google Drive folder and import backups',
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
                        child: TextField(
                          controller: _folder,
                          style: TextStyle(fontSize: 13, color: Sx.text),
                          decoration: txtDecoration(hint: g.my.isNotEmpty && g.override.isEmpty ? 'Found: ${g.my}' : 'Found automatically'),
                        ),
                      ),
                      MiniButton(
                        'Use this folder',
                        onPressed: () {
                          if (_folder.text.trim().isNotEmpty) _setFolder(_folder.text.trim());
                        },
                      ),
                      MiniButton(
                        'Find automatically',
                        onPressed: () {
                          _folder.clear();
                          _setFolder('');
                        },
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text.rich(
                      TextSpan(
                        style: sub,
                        children: [
                          const TextSpan(text: "Google Drive's "),
                          TextSpan(text: 'My Drive', style: b),
                          const TextSpan(text: " folder (the one with AWAAZ in it). Only needed if SX Studio can't find Google Drive by itself."),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      MiniButton('Open import backups', onPressed: () => _open(OpenTarget.backups)),
                      Text('The show as it was before each import (newest 3).', style: sub),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
