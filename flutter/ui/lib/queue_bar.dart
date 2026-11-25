import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'theme.dart';
import 'widgets/sx_widgets.dart';

/// The bar under the header for saves made while ShowXpress was open. While
/// they wait it lists them. After ShowXpress closed and they ran, it says how
/// each one went until the user presses OK.
///
/// Port of `renderQ` in `df_aim_gui.ps1`.
class QueueBar extends StatelessWidget {
  const QueueBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final q = app.status?.queue;
    if (q == null) return const SizedBox.shrink();
    if (q.done case final done?) return _Done(done);
    if (q.items.isEmpty) return const SizedBox.shrink();
    final n = q.items.length;
    return _Box(
      color: Sx.amber,
      title: 'Waiting for ShowXpress to close. $n thing${n > 1 ? 's' : ''} to do',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final item in q.items)
              Container(
                padding: const EdgeInsets.fromLTRB(11, 3, 4, 3),
                decoration: BoxDecoration(
                  color: Sx.panel,
                  border: Border.all(color: Sx.line),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(item.label, style: const TextStyle(fontSize: 13))),
                    IconButton(
                      onPressed: () => runSave(context, () => app.client.queueCancel(item.key), quiet: true),
                      icon: Icon(Icons.close, size: 14, color: Sx.dim),
                      tooltip: 'Take it off the list',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
          ],
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            InkWell(
              onTap: () => runSave(context, () => app.client.queueReopen(!q.reopen), quiet: true),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(q.reopen ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: q.reopen ? Sx.accent : Sx.dim),
                  const SizedBox(width: 8),
                  Text('Open ShowXpress again afterwards', style: Sx.sub),
                ],
              ),
            ),
            if (app.sxOpen) ...[
              Text('Save your show, then close ShowXpress.', style: Sx.sub),
              MiniButton('Close ShowXpress now', primary: true, onPressed: () => runSave(context, () => app.client.sxClose(), quiet: true)),
            ] else
              Text('ShowXpress is closed. Doing it now.', style: Sx.sub),
          ],
        ),
      ],
    );
  }
}

/// How the queued saves went.
class _Done extends StatelessWidget {
  const _Done(this.done);

  final Json done;

  @override
  Widget build(BuildContext context) {
    final results = done.list('results', (j) => j);
    final bad = results.where((r) => !r.boolean('ok')).length;
    final reopenError = done.str('reopenError');
    return _Box(
      color: bad > 0 ? Sx.red : Sx.green,
      title: bad > 0 ? "Done after ShowXpress closed. $bad didn't work" : 'Done after ShowXpress closed',
      children: [
        for (final r in results)
          Text(
            r.boolean('ok') ? '${r.str('label')}: done' : '${r.str('label')}: NOT done. ${r.str('error')}',
            style: TextStyle(fontSize: 13, color: r.boolean('ok') ? Sx.text2 : Sx.redText),
          ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            if (done.boolean('reopened')) Text('ShowXpress is opening again.', style: Sx.sub),
            if (reopenError.isNotEmpty) Text("ShowXpress didn't open: $reopenError", style: TextStyle(fontSize: 13, color: Sx.red)),
            MiniButton(
              'Full details',
              onPressed: () => showReport(
                context,
                'Full details',
                [for (final r in results) '== ${r.str('label')}\n${r.str('out').isEmpty ? r.str('error') : r.str('out')}'].join('\n'),
              ),
            ),
            MiniButton('OK', onPressed: () => runSave(context, AppScope.read(context).client.queueSeen, quiet: true)),
          ],
        ),
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.color, required this.title, required this.children});

  final Color color;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gutter = sxGutter(context);
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(gutter, gutter < 22 ? 10 : 14, gutter, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: Sx.tint(color, radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Sx.title),
          for (final c in children) Padding(padding: const EdgeInsets.only(top: 6), child: c),
        ],
      ),
    );
  }
}
