import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';
import 'settings_model.dart';

/// The Google Drive card: is Google Drive here, Sync, Import, and (on the
/// laptop) the My Drive folder and the import backups. Used by Settings, and
/// Home can show it too.
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
    final m = SettingsModel.of(AppScope.read(context));
    final err = await m.save(SettingsChange(driveFolder: v));
    if (!mounted) return;
    if (err.isNotEmpty) {
      setState(() => _error = err);
      return;
    }
    await _load();
  }

  Future<void> _open(OpenTarget what) async {
    final r = await AppScope.read(context).client.openOnComputer(what);
    if (mounted && !r.ok) setState(() => _error = r.error);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final phone = SettingsModel.of(app).phone;
    final g = _g;
    final (acct, warn) = g == null
        ? ('Looking for Google Drive.', false)
        : g.found
        ? ('Google Drive is signed in${g.account.isEmpty ? '' : ' as ${g.account}'}. It uploads and downloads the show by itself.', false)
        : g.appFound
        ? ('Google Drive is installed but not signed in. Press Open Google Drive and sign in with the AWAAZ Google account.', true)
        : ("Google Drive for desktop isn't on this computer. Press Get Google Drive, install it and sign in.", true);
    return SxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SxHeader(
            'Google Drive',
            actions: [
              if (!phone && g != null && g.appFound)
                OutlinedButton(onPressed: () => _open(OpenTarget.gdapp), child: Text(g.found ? 'Open Google Drive' : 'Sign in to Google Drive')),
              if (!phone) OutlinedButton(onPressed: () => _open(OpenTarget.gddl), child: const Text('Get Google Drive')),
            ],
          ),
          const SizedBox(height: 6),
          Text(acct, style: Sx.sub.copyWith(color: warn ? Sx.amber : Sx.dim)),
          if (g != null) ...[
            const SizedBox(height: 12),
            if (!g.found)
              const Text("Google Drive isn't on this computer. Install Google Drive for desktop and sign in.", style: Sx.sub)
            else ...[
              Text(
                'Copies the show to ${g.target}. New and changed files go up, and a file deleted here since the last sync is removed there. '
                '${g.last.isEmpty ? 'Not synced yet.' : 'Last sync: ${whenText(g.last)}.'}',
                style: Sx.sub,
              ),
              const SizedBox(height: 6),
              Text(
                'Import copies the show from Google Drive into ${g.show} and replaces the one on this computer'
                '${g.srcFound ? ' (Google Drive copy saved ${whenText(g.srcTime)}).' : '.'}'
                '${g.lastImport.isEmpty ? '' : ' Last import: ${whenText(g.lastImport)}.'}',
                style: Sx.sub,
              ),
              if (!g.srcFound) const Text('No show on Google Drive yet.', style: TextStyle(color: Sx.amber, fontSize: 13)),
            ],
            if (g.found && app.sxOpen)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'ShowXpress is open. This is queued and done as soon as you save and close ShowXpress.',
                  style: TextStyle(color: Sx.amber, fontSize: 13),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: g.found && g.here ? () => runSave(context, app.client.gdriveSync, after: _load) : null,
                  child: const Text('Sync to Google Drive'),
                ),
                OutlinedButton(onPressed: g.found && g.srcFound ? () => _import(g) : null, child: const Text('Import from Google Drive')),
              ],
            ),
          ],
          ErrorBox(_error),
          if (!phone && g != null)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: const Text('Google Drive folder and import backups', style: TextStyle(fontSize: 13.5, color: Sx.text2)),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 320,
                        child: TextField(
                          controller: _folder,
                          decoration: InputDecoration(hintText: g.my.isNotEmpty && g.override.isEmpty ? 'Found: ${g.my}' : 'Found automatically'),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => _folder.text.trim().isEmpty ? null : _setFolder(_folder.text.trim()),
                        child: const Text('Use this folder'),
                      ),
                      OutlinedButton(
                        onPressed: () {
                          _folder.clear();
                          _setFolder('');
                        },
                        child: const Text('Find automatically'),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      "Google Drive's My Drive folder (the one with AWAAZ in it). Only needed if SX Studio can't find Google Drive by itself.",
                      style: Sx.sub,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(onPressed: () => _open(OpenTarget.backups), child: const Text('Open import backups')),
                      const Text('The show as it was before each import (newest 3).', style: Sx.sub),
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
