import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'issue_row.dart';

/// Health Check: problems in the show, with fixes that can be applied,
/// reverted or kept. Checking changes nothing.
class HealthScreen extends StatefulWidget {
  const HealthScreen(BuildContext _, {super.key});

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> with ShowWatcher {
  HealthReport? _data;
  var _error = '';
  var _loading = true;
  var _notesOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // The old poll read the health check again after the queue ran and when
  // ShowXpress closed. It holds no edits, so it always reads again.
  @override
  void onQueueRan() => _load();

  @override
  void onSxClosed() => _load();

  Future<void> _load() async {
    setState(() => _loading = true);
    final client = AppScope.read(context).client;
    try {
      final d = await client.health();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fix(HealthIssue i) async {
    final app = AppScope.read(context);
    final client = app.client;
    final ok = await askConfirm(
      context,
      'Apply this fix?',
      confirmText(i.title, [i.advice, 'You can revert it afterwards at the top of this tab.']),
      i.fix!.label,
    );
    if (!ok || !mounted) return;
    // the other tabs' copies are stale too; this screen reloads with them (onSxClosed)
    await runSave(context, () => client.healthFix(i.fix!.key), after: () async => app.showEdited());
  }

  Future<void> _revert(AppliedFix a, {bool force = false}) async {
    final client = AppScope.read(context).client;
    if (!force) {
      final ok = await askConfirm(
        context,
        'Revert this fix?',
        confirmText(a.title, ['Puts back what "${a.label}" changed, exactly as it was before.']),
        'Revert',
      );
      if (!ok) return;
    }
    HealthRevert r;
    try {
      r = await client.healthRevert(a.id, force: force);
    } on ApiException catch (e) {
      r = HealthRevert(result: ToolResult.failed(e.message));
    }
    if (!mounted) return;
    if (r.result.ok && r.conflict.isNotEmpty) {
      final again = await askConfirm(
        context,
        'Changed since the fix',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in r.conflict) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('- $c')),
            const SizedBox(height: 8),
            const Text('Reverting puts back the version from before the fix, so those later changes are lost too.'),
          ],
        ),
        'Revert anyway',
      );
      if (again && mounted) await _revert(a, force: true);
      return;
    }
    if (r.result.ok) AppScope.read(context).showEdited();
    await AppScope.read(context).refresh();
    if (!mounted) return;
    await showReport(context, r.result.ok ? 'Reverted' : 'Not reverted', r.result.out, error: r.result.error);
  }

  Future<void> _keep(AppliedFix a) async {
    final client = AppScope.read(context).client;
    final ok = await askConfirm(
      context,
      'Keep this fix?',
      confirmText('', ["The backup of ${a.title} is deleted, so it can't be reverted any more. The fix itself stays."]),
      'Keep it',
    );
    if (!ok || !mounted) return;
    await runSave(context, () => client.healthKeep(a.id), after: _load);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    return ScreenBody(
      bar: SaveBar(
        hint: app.sxOpen
            ? 'ShowXpress is open. A fix waits until it closes.'
            : 'Checking changes nothing. A fix changes only what it says, and can be reverted at the top of this tab.',
        actions: [FilledButton(onPressed: _loading ? null : _load, child: const Text('Check again'))],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SxHeader(
                'Show health check',
                sub:
                    'Looks through the whole show for things that have caused trouble before: missing scenes, broken beat settings, '
                    'APC pads that fire two buttons, colour chases that spin the wheel. Checking changes nothing. Each problem shows a '
                    "recommended fix; where the helper can do it for you there's a button, and every fix can be reverted.",
              ),
              if (d != null && d.applied.isNotEmpty) _applied(app, d.applied),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _loading
                    ? Text('Checking the show.', style: Sx.sub)
                    : _error.isNotEmpty
                    ? Text(_error, style: TextStyle(color: Sx.red, fontSize: 13))
                    : d == null
                    ? const SizedBox.shrink()
                    : _summary(d),
              ),
              if (!_loading && d != null) ..._issues(d),
            ],
          ),
        ),
      ],
    );
  }

  Widget _applied(AppState app, List<AppliedFix> applied) => Container(
    margin: const EdgeInsets.only(top: 12, bottom: 4),
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
    decoration: BoxDecoration(
      color: Sx.panel,
      border: Border.all(color: Sx.green.withValues(alpha: .35)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Row(
            children: [
              Icon(Icons.check, size: 15, color: Sx.green),
              const SizedBox(width: 6),
              Text(
                'Fixes you applied (${applied.length})',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Sx.green),
              ),
            ],
          ),
        ),
        for (final (i, a) in applied.indexed)
          IssueRow(
            level: 'done',
            first: i == 0,
            title: a.title,
            detail: '${a.label} · ${a.time}. Revert puts it back as it was, Keep forgets the backup.',
            actions: [
              MiniButton('Revert', icon: Icons.undo, onPressed: app.sxOpen || _loading ? null : () => _revert(a)),
              MiniButton('Keep', onPressed: _loading ? null : () => _keep(a)),
            ],
          ),
      ],
    ),
  );

  Widget _summary(HealthReport d) {
    int count(String level) => d.issues.where((i) => i.level == level).length;
    final fixable = d.issues.where((i) => i.fix != null).length;
    TextSpan n(int v, Color c) => TextSpan(
      text: '$v',
      style: TextStyle(color: c, fontWeight: FontWeight.w700),
    );
    TextSpan b(String t) => TextSpan(
      text: t,
      style: TextStyle(color: Sx.text, fontWeight: FontWeight.w700),
    );
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Checked '),
          b('${d.buttons}'),
          const TextSpan(text: ' buttons and '),
          b('${d.scenes}'),
          const TextSpan(text: ' scenes. '),
          n(count('error'), Sx.red),
          const TextSpan(text: ' problem(s) · '),
          n(count('warn'), Sx.amber),
          const TextSpan(text: ' warning(s) · '),
          n(count('info'), Sx.blue),
          const TextSpan(text: ' note(s)'),
          if (fixable > 0) ...[const TextSpan(text: ' · '), n(fixable, Sx.green), const TextSpan(text: ' can be fixed here')],
        ],
      ),
      style: TextStyle(fontSize: 13, color: Sx.dim),
    );
  }

  List<Widget> _issues(HealthReport d) {
    final main = d.issues.where((i) => i.level != 'info').toList(), notes = d.issues.where((i) => i.level == 'info').toList();
    Widget row(HealthIssue i, bool first) => IssueRow(
      level: i.level,
      first: first,
      title: i.title,
      detail: i.detail,
      advice: i.advice,
      actions: [if (i.fix != null) MiniButton(i.fix!.label, primary: true, onPressed: _loading ? null : () => _fix(i))],
    );
    return [
      const SizedBox(height: 10),
      if (main.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(Icons.check, size: 16, color: Sx.green),
              const SizedBox(width: 6),
              Text('No problems found.', style: TextStyle(color: Sx.green)),
            ],
          ),
        ),
      for (final (k, i) in main.indexed) row(i, k == 0),
      if (notes.isNotEmpty) ...[
        InkWell(
          onTap: () => setState(() => _notesOpen = !_notesOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(_notesOpen ? Icons.expand_more : Icons.chevron_right, size: 18, color: Sx.dim),
                const SizedBox(width: 4),
                Text('${notes.length} note(s), probably fine', style: TextStyle(fontSize: 13, color: Sx.dim)),
              ],
            ),
          ),
        ),
        if (_notesOpen)
          for (final (k, i) in notes.indexed) row(i, k == 0),
      ],
    ];
  }
}
