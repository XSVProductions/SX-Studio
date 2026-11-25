import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../app_state.dart';
import '../theme.dart';
import 'sx_widgets.dart';

/// Text with **bold** parts, for the old copy's `<b>` tags. [text] uses `*`
/// around the bold words.
Text boldText(String text, {TextStyle? style, Color? bold}) {
  final parts = text.split('*');
  return Text.rich(
    TextSpan(
      children: [
        for (final (i, p) in parts.indexed)
          TextSpan(
            text: p,
            style: i.isOdd ? TextStyle(fontWeight: FontWeight.w600, color: bold ?? Sx.text) : null,
          ),
      ],
    ),
    style: style,
  );
}

/// The icon in front of a result's title: done, a warning, failed, or waiting
/// in the queue.
enum ResultTone { ok, warn, err, queued }

/// What the old page's `#result` card shows after a save: a title, what
/// changed, warnings, and the tool's whole report under Full details.
class SaveResult {
  const SaveResult(
    this.tone,
    this.title, {
    this.lead = '',
    this.text = const [],
    this.items = const [],
    this.after = '',
    this.warnings = const [],
    this.log = '',
  });

  final ResultTone tone;
  final String title;

  /// A paragraph in the normal text color, the reason a save failed.
  final String lead;

  /// Paragraphs in the dim color, before [items]. `*` marks bold, as in [boldText].
  final List<String> text;

  /// What changed, one line each.
  final List<String> items;

  /// A dim line after [items] ("Open ShowXpress to use it.").
  final String after;

  /// The `.warnbox` at the bottom.
  final List<String> warnings;

  /// The tool's full report.
  final String log;

  /// Shown with a red border, as the old `.result.err`.
  bool get bad => tone == ResultTone.err || tone == ResultTone.warn;

  SaveResult copyWith({String? title, List<String>? text}) =>
      SaveResult(tone, title ?? this.title, lead: lead, text: text ?? this.text, items: items, after: after, warnings: warnings, log: log);
}

/// The kinds of save the old `showResult` reports as saves (its `SV` list),
/// with the title of each when it worked.
const _savedTitles = {
  'skip': 'Saved to SKIP FLASH',
  'rig': "Tonight's rig saved",
  'apc': 'APC pads saved',
  'speed': 'Speed faders saved',
  'fix': 'Fix applied',
  'revert': 'Fix reverted',
  'keep': 'Fix kept',
  'rt': 'Saved to the 2D view',
  'install': 'RIG ID added',
  'color': "Tonight's color saved",
  'gsync': 'Copied to Google Drive',
  'gimport': 'Imported from Google Drive',
  'prefix': 'Done',
  'roominstall': 'ROOM buttons added to the SETUP page',
  'sx': 'Done',
  'update': 'Installer opened',
  'remote': 'ShowXpress remote control turned on',
  'auto': 'Auto Show saved',
  'scene': 'Scene saved',
  'scenerev': 'Scene reverted',
  'move': 'Movement saved',
  'moverev': 'Movement reverted',
  'look': 'Look made',
};

/// The title of a failed [what], from the old `showResult`.
String failedTitle(String what) => switch (what) {
  'gsync' => 'Not copied',
  'gimport' => 'Not imported',
  'live' => "Live aim didn't start",
  'clprev' => "Preview didn't start",
  'sx' || 'update' || 'prefix' || 'lab' => "Didn't work",
  _ => _savedTitles.containsKey(what) ? 'Not saved' : 'Not applied',
};

/// A failure of [what] with [error]. Old `showResult` for `ok:false`.
SaveResult failedResult(String what, String error, {String out = ''}) =>
    SaveResult(ResultTone.err, failedTitle(what), lead: error, text: const ['Nothing was changed.'], log: out);

/// A save that waits in the queue until ShowXpress closes. [reopen] is the
/// queue's "Open ShowXpress again afterwards".
SaveResult queuedResult(ToolResult r, {required bool reopen}) => SaveResult(
  ResultTone.queued,
  'Queued: ${r.extra['label'] ?? ''}',
  text: [
    "${r.extra['replaced'] == true ? 'Replaces what was queued for it before. ' : ''}Nothing is changed yet. Keep setting up. When you're done, "
        '*save and close ShowXpress*: SX Studio does everything in the list at the top${reopen ? ' and opens ShowXpress again' : ''}.',
  ],
);

final _nl = RegExp(r'\r?\n');
final _indented = RegExp(r'^ {2}\S');
final _boring = RegExp(r'^(same\s|live\.ini saved|nothing to change|2D view saved|RIGHEADS|SKIPHEADS)');

/// What the old page's `showResult(r, what)` shows for a save, from the
/// tool's report: the lines that changed, "Nothing needed changing" when
/// nothing did, and where to look next. Aim Movers' Apply and Reset build
/// their own (`AimScreen`).
SaveResult resultOf(ToolResult r, String what, {bool reopen = true}) {
  if (!r.ok) return failedResult(what, r.error, out: r.out);
  if (r.extra['queued'] == true) return queuedResult(r, reopen: reopen);
  final lines = r.out.split(_nl);
  if (what == 'skip') {
    final same = lines.any((l) => l.contains('nothing to change'));
    return SaveResult(
      ResultTone.ok,
      same ? 'SKIP FLASH already uses these heads' : 'Saved to SKIP FLASH',
      items: [
        for (final l in lines.map((l) => l.trim()))
          if (l.startsWith('heads:') || l.startsWith('loop:')) l,
      ],
      after: 'Open ShowXpress and press *SKIP FLASH* to check it.',
      log: r.out,
    );
  }
  final same = lines.any((l) => l.contains('nothing to change')) && !lines.any((l) => l.contains('SKIP FLASH now'));
  final use = const ['rig', 'apc', 'speed', 'rt', 'install', 'color', 'roominstall', 'remote'].contains(what);
  final check = const ['fix', 'revert', 'scene', 'scenerev', 'move', 'moverev'].contains(what);
  return SaveResult(
    ResultTone.ok,
    same ? 'Nothing needed changing' : _savedTitles[what] ?? 'Done',
    items: [
      for (final l in lines)
        if (_indented.hasMatch(l) && !_boring.hasMatch(l.trim())) l.trim().replaceFirst(RegExp(r'^CHANGED\s+'), ''),
    ],
    after: use || check ? 'Open ShowXpress to ${use ? 'use' : 'check'} it.' : '',
    log: r.out,
  );
}

/// Runs a save and shows how it went in the result card, as the old page's
/// `saveTo` did.
///
/// While ShowXpress is open the engine queues the save instead of running it,
/// and the card says so. On a real save [after] runs (reload the screen, and
/// the tabs the save made stale). [what] is the old page's name for the save,
/// which picks the card's title and wording (see [resultOf]). [quiet] shows
/// only a failure, for actions that are not saves (the old `sxLaunch`).
/// [busy] covers the page while it saves, "Queueing." while ShowXpress is open.
Future<ToolResult> runSave(
  BuildContext context,
  Future<ToolResult> Function() save, {
  String what = 'sx',
  String busy = '',
  Future<void> Function()? after,
  bool quiet = false,
}) async {
  final app = AppScope.read(context);
  if (busy.isNotEmpty) app.setBusy(app.sxOpen ? 'Queueing.' : busy);
  ToolResult r;
  try {
    r = await save();
  } on ApiException catch (e) {
    r = ToolResult.failed(e.message);
  }
  if (busy.isNotEmpty) app.setBusy('');
  final queued = r.extra['queued'] == true;
  if (r.ok && !queued) await after?.call();
  await app.refresh();
  if (quiet && r.ok) return r;
  app.showResult(resultOf(r, what, reopen: app.status?.queue.reopen ?? true));
  return r;
}

/// The old page's `#result` card: under the screen, scrolled into view when
/// it appears. A new tab hides it.
class ResultCard extends StatefulWidget {
  const ResultCard(this.result, {super.key});

  final SaveResult result;

  @override
  State<ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<ResultCard> {
  var _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final (color, icon) = switch (r.tone) {
      ResultTone.ok => (Sx.green, Icons.check),
      ResultTone.warn => (Sx.amber, Icons.warning_amber_rounded),
      ResultTone.err => (Sx.red, Icons.close),
      ResultTone.queued => (Sx.amber, Icons.hourglass_empty),
    };
    return Container(
      padding: sxGutter(context) < 22 ? const EdgeInsets.fromLTRB(13, 14, 13, 14) : const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: Sx.card,
        border: Border.all(color: r.bad ? Sx.red.withValues(alpha: .5) : Sx.green.withValues(alpha: .4)),
        borderRadius: BorderRadius.circular(sxGutter(context) < 22 ? 12 : 14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(r.title, style: Sx.title)),
            ],
          ),
          if (r.lead.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: boldText(r.lead, style: TextStyle(color: Sx.text, fontSize: 14)),
            ),
          for (final t in r.text)
            if (t.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: boldText(t, style: Sx.sub),
              ),
          if (r.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in r.items)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 7, 10, 0),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(color: Sx.text2, shape: BoxShape.circle),
                          ),
                        ),
                        Expanded(
                          child: Text(l, style: TextStyle(color: Sx.text2, fontSize: 13)),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          if (r.after.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: boldText(r.after, style: Sx.sub),
            ),
          if (r.warnings.isNotEmpty) ErrorBox(r.warnings.join('\n')),
          if (r.tone != ResultTone.queued) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Sx.dim),
                  Text('Full details', style: TextStyle(color: Sx.dim, fontSize: 12.5)),
                ],
              ),
            ),
            if (_open)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 300),
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Sx.well,
                  border: Border.all(color: Sx.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    r.log,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4, color: Sx.text2),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
