import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../health/issue_row.dart';

/// Pre-show Check: the show, the gear and the laptop in one look, plus a line
/// for the Health Check. Checking changes nothing.
class PreScreen extends StatefulWidget {
  const PreScreen(BuildContext _, {super.key});

  @override
  State<PreScreen> createState() => _PreScreenState();
}

/// The Health Check line the old page added third in the list.
PreItem? healthLine(HealthReport? h) {
  if (h == null) return null;
  final e = h.issues.where((i) => i.level == 'error').length, w = h.issues.where((i) => i.level == 'warn').length;
  const fix = PreFix(key: 'tab:health', label: 'Open Health Check');
  if (e > 0) {
    return PreItem(
      group: 'Show',
      level: 'error',
      title: 'Health Check: $e problem(s) in the show',
      detail: w > 0 ? '$w warning(s) too.' : '',
      advice: 'Open the Health Check tab and look at the red ones.',
      fix: fix,
    );
  }
  if (w > 0) {
    return PreItem(
      group: 'Show',
      level: 'warn',
      title: 'Health Check: $w warning(s)',
      detail: 'No real problems.',
      advice: 'Have a look in the Health Check tab if you have time.',
      fix: fix,
    );
  }
  return const PreItem(group: 'Show', level: 'ok', title: 'Health Check: no problems in the show');
}

class _PreScreenState extends State<PreScreen> {
  List<PreItem>? _items;
  var _error = '';
  var _loading = true;
  DateTime? _at;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final client = AppScope.read(context).client;
    try {
      // The health check is only a line here; if it fails the rest still shows.
      final health = client.health().then<HealthReport?>((h) => h, onError: (Object _) => null);
      final pre = await client.preshow();
      final items = [...pre.items];
      final h = healthLine(await health);
      if (h != null) items.insert(items.length < 2 ? items.length : 2, h);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = '';
        _at = DateTime.now();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _items = null;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _ask = {
    'sleep': 'Sets "When plugged in, PC goes to sleep after" to Never.',
    'usb': 'Turns USB selective suspend off when plugged in, so Windows never powers down the APC mini or the DMX interface.',
    'restart': 'Windows restarts in 1 minute to finish its updates. Save and close ShowXpress first. Changed your mind? Run shutdown /a.',
  };

  Future<void> _fix(PreItem i) async {
    final app = AppScope.read(context);
    final key = i.fix!.key;
    if (key.startsWith('tab:')) return app.go(key.substring(4));
    if (key == 'launch') return runSave(context, app.client.sxLaunch, quiet: true);
    final ok = await askConfirm(context, i.title, confirmText('', [_ask[key] ?? '']), i.fix!.label);
    if (!ok || !mounted) return;
    await runSave(context, () => app.client.preshowFix(key), after: _load);
  }

  String _time(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final items = _items;
    final groups = <String, List<PreItem>>{};
    for (final i in items ?? const <PreItem>[]) {
      groups.putIfAbsent(i.group, () => []).add(i);
    }
    return ScreenBody(
      bar: SaveBar(
        hint: _at == null || items == null ? '' : 'Checked at ${_time(_at!)}. Checking changes nothing; a fix button changes only what it says.',
        actions: [FilledButton(onPressed: _loading ? null : _load, child: const Text('Check again'))],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SxHeader('Pre-show check', sub: 'One look before the guests arrive: the show, your gear and the laptop. Checking changes nothing.'),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _loading
                    ? Text('Checking.', style: Sx.sub)
                    : _error.isNotEmpty
                    ? Text(_error, style: TextStyle(color: Sx.red, fontSize: 13))
                    : items == null
                    ? const SizedBox.shrink()
                    : _summary(items),
              ),
              if (!_loading && items != null)
                for (final g in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 14, bottom: 4),
                    child: Text(g.key.toUpperCase(), style: Sx.label),
                  ),
                  for (final (k, i) in g.value.indexed)
                    IssueRow(
                      level: i.level,
                      first: k == 0,
                      title: i.title,
                      detail: i.detail,
                      advice: i.level == 'ok' ? '' : i.advice,
                      actions: [
                        if (i.fix != null && i.level != 'ok')
                          MiniButton(i.fix!.label, primary: true, onPressed: i.fix!.key == 'launch' && app.sxOpen ? null : () => _fix(i)),
                      ],
                    ),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _summary(List<PreItem> items) {
    final e = items.where((i) => i.level == 'error').length, w = items.where((i) => i.level == 'warn').length;
    final base = TextStyle(fontSize: 13, color: Sx.dim);
    if (e > 0) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$e thing(s) to fix',
              style: TextStyle(color: Sx.red, fontWeight: FontWeight.w700),
            ),
            TextSpan(text: ' before the show · $w to check'),
          ],
        ),
        style: base,
      );
    }
    if (w > 0) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$w thing(s) to check',
              style: TextStyle(color: Sx.amber, fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: ', nothing broken'),
          ],
        ),
        style: base,
      );
    }
    return Row(
      children: [
        Icon(Icons.check, size: 16, color: Sx.green),
        const SizedBox(width: 6),
        Text(
          'All good, ready for the show',
          style: TextStyle(color: Sx.green, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ],
    );
  }
}
