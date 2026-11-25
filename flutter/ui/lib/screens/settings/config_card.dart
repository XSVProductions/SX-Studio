import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../boot/boot.dart';
import '../../page_store.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'settings_bits.dart';
import 'settings_model.dart';

/// The `sxh_` names of this computer's own choices that the port keeps too,
/// under the same names and in the same format as the old page. A settings
/// file carries only these, and an import writes only these.
///
/// - `sxh_theme`: light, dark or the device's own (Settings, Look)
/// - `sxh_looks`: the Looks options
/// - `sxh_mvlite`: the scene the movement editor lights with
/// - `sxh_lvspd`: the live-aim speed
/// - `sxh_flip_<head id>`: how live aim turns each head
bool isPortDeviceKey(String k) =>
    deviceKeyPattern.hasMatch(k) && k != phoneKeyName && (const {'sxh_theme', 'sxh_looks', 'sxh_mvlite', 'sxh_lvspd'}.contains(k) || k.startsWith('sxh_flip_'));

/// This computer's own choices, for Export settings. The page's `devKeys`.
Future<Map<String, String>> readDeviceChoices() async {
  final prefs = await SharedPreferences.getInstance();
  return {
    for (final k in prefs.getKeys())
      if (isPortDeviceKey(k) && prefs.get(k) is String) k: prefs.getString(k)!,
  };
}

/// Keeps the imported choices this app knows, through the same store the
/// screens read.
Future<void> writeDeviceChoices(Map<String, String> keys) async {
  final store = await openPageStore();
  for (final MapEntry(:key, :value) in keys.entries) {
    if (isPortDeviceKey(key)) store.set(key, value);
  }
}

/// A file the user picked: its name and its text.
typedef PickedFile = ({String name, String text});

/// The open dialog for a settings file, or null when the user cancels.
Future<PickedFile?> pickSettingsFile() async {
  const json = XTypeGroup(label: 'SX Studio settings', extensions: ['json'], mimeTypes: ['application/json'], uniformTypeIdentifiers: ['public.json']);
  final f = await openFile(acceptedTypeGroups: const [json], initialDirectory: settingsFileFolder());
  if (f == null) return null;
  return (name: f.name, text: await f.readAsString());
}

/// What the line next to the buttons says (`#scfg`).
sealed class _Line {
  const _Line();
}

class _Empty extends _Line {
  const _Empty();
}

class _Busy extends _Line {
  const _Busy(this.text);
  final String text;
}

class _Failed extends _Line {
  const _Failed(this.text, {this.amber = false});
  final String text;
  final bool amber;
}

class _Saved extends _Line {
  const _Saved(this.r);
  final ConfigExportResult r;
}

class _Imported extends _Line {
  const _Imported(this.done, this.warn);
  final List<String> done;
  final List<String> warn;
}

/// Export & import settings (`#sexp`, `#simp`). Computer only: Settings
/// leaves it out on a phone, and the web build, which phones load, never
/// shows it, as the old phone page had none.
class ConfigCard extends StatefulWidget {
  const ConfigCard({super.key, this.pick = pickSettingsFile});

  /// Opens the file dialog. Tests put their own in.
  final Future<PickedFile?> Function() pick;

  @override
  State<ConfigCard> createState() => _ConfigCardState();
}

class _ConfigCardState extends State<ConfigCard> {
  _Line _line = const _Empty();

  bool get _busy => _line is _Busy;

  Future<void> _export() async {
    final client = AppScope.read(context).client;
    setState(() => _line = const _Busy('Exporting the settings.'));
    _Line line;
    try {
      line = _Saved(await client.configExport(await readDeviceChoices()));
    } on ApiException catch (e) {
      line = _Failed(e.message.isEmpty ? "The settings couldn't be saved." : e.message);
    }
    if (mounted) setState(() => _line = line);
  }

  Future<void> _reveal() async {
    final r = await AppScope.read(context).client.revealExport();
    if (!r.ok && mounted) await showReport(context, 'Not opened', '', error: r.error);
  }

  Future<void> _import() async {
    final app = AppScope.read(context);
    final f = await widget.pick();
    if (f == null || !mounted) return;
    SettingsFile? d;
    try {
      final j = jsonDecode(f.text);
      if (j is Map<String, Object?>) d = SettingsFile(j);
    } on FormatException {
      d = null;
    }
    if (d == null || !d.isSettingsFile) {
      setState(() => _line = const _Failed("That file isn't an SX Studio settings file."));
      return;
    }
    final what = d.parts;
    if (what.isEmpty) {
      setState(() => _line = const _Failed('That file has no settings in it.', amber: true));
      return;
    }
    final saved = d.saved.isEmpty
        ? ''
        : ' (saved ${d.saved.length > 10 ? d.saved.substring(0, 10) : d.saved}${d.version.isEmpty ? '' : ' by version ${d.version}'})';
    if (!await confirm(context, 'Import these settings?', '${f.name}$saved replaces ${andList(what)}. What you have now is backed up first.', 'Import')) return;
    if (!mounted) return;
    setState(() => _line = const _Busy('Importing the settings.'));
    ConfigImportResult r;
    try {
      r = await app.client.configImport(d.raw);
    } on ApiException catch (e) {
      if (mounted) setState(() => _line = _Failed(e.message.isEmpty ? 'Nothing was imported.' : e.message));
      return;
    }
    final done = [...r.done];
    final dev = d.device;
    if (dev != null) {
      await writeDeviceChoices(dev);
      done.add("this computer's own choices");
    }
    // take it all up now, as the old page did: theme, tabs, and every tab's data
    app.setThemeMode(await loadThemeMode());
    await SettingsModel.of(app).load();
    app.settingsImported();
    if (mounted) setState(() => _line = _Imported(done, r.warn));
  }

  @override
  Widget build(BuildContext context) => kIsWeb
      ? const SizedBox.shrink()
      : SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SetTitle('Export & import settings'),
              const SizedBox(height: 4),
              Text(
                'Save everything you set up in SX Studio in one file, and load it again later or on another computer: the tabs (order, names, hidden), '
                'the SX Player pages and your own player pages, the APC40 pads and faders, the APC mini pads and their colours, which speed fader each '
                "button follows, the Auto Show, the options above, phone access on or off, and this computer's own choices (light or dark, Looks options, "
                "live-aim view). Not in it: the show itself (scenes, movements, aims, Tonight's Rig and Color, which Google Drive sync keeps) and the phone "
                "pairing code. The APC mini pads and speed faders are saved in ShowXpress's live board, so while ShowXpress is open they wait until it's closed.",
                style: Sx.sub,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(onPressed: _busy ? null : _export, icon: const Icon(Icons.download, size: 18), label: const Text('Export settings')),
                  OutlinedButton.icon(onPressed: _busy ? null : _import, icon: const Icon(Icons.upload, size: 18), label: const Text('Import settings')),
                  ..._summary(),
                ],
              ),
            ],
          ),
        );

  /// The old `.summary` line: 13 px, dim, the file name or the parts in bold.
  List<Widget> _summary() {
    final dim = TextStyle(fontSize: 13, color: Sx.dim, height: 1.4);
    final bold = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    // the old `&#10003;` before "Saved" and "Imported", in the line's own colour
    final tick = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(Icons.check, size: 15, color: Sx.dim),
      ),
    );
    return switch (_line) {
      _Empty() => const [],
      _Busy(:final text) => [Text(text, style: dim)],
      _Failed(:final text, :final amber) => [Text(text, style: dim.copyWith(color: amber ? Sx.amber : Sx.red))],
      _Saved(:final r) => [
        Text.rich(
          TextSpan(
            style: dim,
            children: [
              tick,
              const TextSpan(text: 'Saved '),
              TextSpan(text: r.name, style: bold),
              TextSpan(text: ' in ${r.folder}'),
            ],
          ),
        ),
        MiniButton('Show the file', onPressed: _reveal),
      ],
      _Imported(:final done, :final warn) => [
        Text.rich(
          TextSpan(
            style: dim,
            children: [
              if (done.isNotEmpty) ...[tick, TextSpan(text: 'Imported ${andList(done)}.')] else const TextSpan(text: 'Nothing was imported.'),
              if (warn.isNotEmpty)
                TextSpan(
                  text: ' ${warn.join(' ')}',
                  style: TextStyle(color: Sx.amber),
                ),
            ],
          ),
        ),
      ],
    };
  }
}
