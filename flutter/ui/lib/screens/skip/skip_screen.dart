import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../rig/rig_widgets.dart';

/// Skip Flash: which movers the SKIP FLASH button flashes tonight.
class SkipScreen extends StatefulWidget {
  const SkipScreen(BuildContext _, {super.key});

  @override
  State<SkipScreen> createState() => _SkipScreenState();
}

class _SkipScreenState extends State<SkipScreen> with ReloadWhenShown {
  SkipPreview? _data;
  var _error = '';

  /// Heads picked, saved or not.
  final _picked = <String>{};

  @override
  String get tabId => 'skip';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Future<void> load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.skip();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
        _picked
          ..clear()
          ..addAll([
            for (final h in d.heads)
              if (h.on) h.id,
          ]);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = e.message;
      });
    }
    app.setDirty(tabId, false);
  }

  @override
  bool get dirty => _data != null && _data!.heads.any((h) => h.on != _picked.contains(h.id));

  void _edit(VoidCallback f) {
    setState(f);
    AppScope.read(context).setDirty(tabId, dirty);
  }

  String _hint(AppState app) {
    if (_data == null) return '';
    if (app.sxOpen) return 'ShowXpress is open. A save waits until it closes.';
    if (_picked.length < 2) return 'Pick at least 2 heads.';
    if (!dirty) return 'SKIP FLASH already uses exactly these heads.';
    return 'Only the SKIP FLASH scene is changed. Heads you turn off are taken out of it.';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    return ScreenBody(
      bar: SaveBar(
        hint: _hint(app),
        actions: [
          TextButton(
            onPressed: d != null && dirty
                ? () => _edit(
                    () => _picked
                      ..clear()
                      ..addAll([
                        for (final h in d.heads)
                          if (h.on) h.id,
                      ]),
                  )
                : null,
            child: const Text('Undo'),
          ),
          FilledButton(
            onPressed: d != null && dirty && _picked.length >= 2
                ? () => runSave(
                    context,
                    () => app.client.skipApply([
                      for (final h in d.heads)
                        if (_picked.contains(h.id)) h.id,
                    ]),
                    after: load,
                  )
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RigHeader(
                'Skip Flash heads',
                sub: 'Tap the movers that are set up tonight. SKIP FLASH will only flash those, so the chase has no dark gaps.',
                dirty: d == null ? null : dirty,
                onRefresh: load,
              ),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null) ...[_group(d, true), _group(d, false)],
            ],
          ),
        ),
        if (d != null) SxCard(child: _order(d)),
      ],
    );
  }

  Widget _group(SkipPreview d, bool is140) {
    final hs = d.heads.where((h) => h.is140 == is140).toList();
    if (hs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeadGroupHeader(
          is140 ? '140SR' : '251SR',
          '${hs.where((h) => _picked.contains(h.id)).length} of ${hs.length}',
          onAll: () => _edit(() => _picked.addAll(hs.map((h) => h.id))),
          onNone: () => _edit(() => _picked.removeAll(hs.map((h) => h.id))),
        ),
        HeadGrid(
          children: [
            for (final h in hs)
              HeadTile(
                title: '#${h.num}',
                sub: _picked.contains(h.id) ? 'in use' : 'not here',
                on: _picked.contains(h.id),
                changed: _picked.contains(h.id) != h.on,
                onTap: () => _edit(() => _picked.contains(h.id) ? _picked.remove(h.id) : _picked.add(h.id)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _order(SkipPreview d) {
    final o = d.flashOrder(_picked);
    final each = d.stepCs / 100;
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: 4,
          children: [
            Text('Flash order', style: Sx.title),
            Text.rich(
              TextSpan(
                style: TextStyle(color: Sx.dim, fontSize: 13),
                children: [
                  TextSpan(text: '${o.length}', style: b),
                  TextSpan(text: ' heads · ${_trim(each)} s each · one loop '),
                  TextSpan(text: '${(o.length * each).toStringAsFixed(2)} s', style: b),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (o.isEmpty)
          Text('no heads picked', style: Sx.sub)
        else
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (i, h) in o.indexed) ...[
                if (i > 0) Icon(Icons.chevron_right, size: 13, color: Sx.mute),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Sx.panel,
                    border: Border.all(color: Sx.line),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(h.label, style: TextStyle(fontSize: 12, color: Sx.text)),
                ),
              ],
            ],
          ),
        const SizedBox(height: 10),
        Text('The order and the step time come from your scene. Only the list of heads changes.', style: Sx.sub),
      ],
    );
  }
}

/// 0.02 as "0.02", 1.0 as "1", like JavaScript prints a number.
String _trim(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
