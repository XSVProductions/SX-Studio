import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../rig/rig_widgets.dart';

/// Rig Test: which 140 hangs where tonight. RIG ID lights every 140 in its
/// own look, the user taps each truss spot and picks the look seen there, and
/// Save writes the spots to ShowXpress's 2D view.
class RtScreen extends StatefulWidget {
  const RtScreen(BuildContext _, {super.key});

  @override
  State<RtScreen> createState() => _RtScreenState();
}

class _RtScreenState extends State<RtScreen> with ReloadWhenShown {
  RtPreview? _data;
  var _error = '';

  /// Slot key to head id, saved or not.
  final _assign = <String, String>{};
  var _extra = false;

  /// Also update Tonight's Rig and SKIP FLASH when saving.
  var _rig = true;

  @override
  String get tabId => 'rt';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Future<void> load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.rt();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = '';
        _reset(d);
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

  void _reset(RtPreview d) {
    _assign
      ..clear()
      ..addAll(d.assign);
    _extra = d.extra;
  }

  @override
  bool get dirty {
    final d = _data;
    if (d == null) return false;
    final keys = {...d.assign.keys, ..._assign.keys};
    return _extra != d.extra || keys.any((k) => (d.assign[k] ?? '') != (_assign[k] ?? ''));
  }

  void _edit(VoidCallback f) {
    setState(f);
    AppScope.read(context).setDirty(tabId, dirty);
  }

  bool _used(RtPreview d, String key) => _extra || !d.slots.firstWhere((s) => s.key == key).extra;

  /// The spots that count: set, and not on a middle tower unless those are in use.
  Map<String, String> _placed(RtPreview d) => {
    for (final e in _assign.entries)
      if (e.value.isNotEmpty && _used(d, e.key)) e.key: e.value,
  };

  RtHead? _head(RtPreview d, String? id) => d.heads.where((h) => h.id == id).firstOrNull;

  String _hint(AppState app, RtPreview? d) {
    if (d == null) return '';
    if (app.sxOpen) return 'ShowXpress is open. A save waits until it closes (it rewrites the 2D view when it closes).';
    final n = _placed(d).length;
    if (n == 0) return 'Put at least one mover on a truss.';
    return '$n mover(s) on trusses. Only the 140 positions in the 2D view change${_rig ? ", plus Tonight's Rig and SKIP FLASH." : '.'}';
  }

  Future<void> _pick(RtPreview d, RtSlot slot) async {
    final cur = _assign[slot.key];
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _PickDialog(d: d, slot: slot, current: cur, assign: _assign, used: (k) => _used(d, k)),
    );
    if (picked == null) return;
    _edit(() {
      if (picked.isEmpty) {
        _assign.remove(slot.key);
      } else {
        _assign.removeWhere((_, v) => v == picked);
        _assign[slot.key] = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    final placed = d == null ? const <String, String>{} : _placed(d);
    return ScreenBody(
      bar: SaveBar(
        hint: _hint(app, d),
        actions: [
          TextButton(onPressed: d != null && _assign.isNotEmpty ? () => _edit(_assign.clear) : null, child: const Text('New event')),
          TextButton(onPressed: d != null && dirty ? () => _edit(() => _reset(d)) : null, child: const Text('Undo')),
          FilledButton(
            onPressed: d != null && placed.isNotEmpty
                ? () => runSave(
                    context,
                    () => app.client.rtApply(placed, extra: _extra, rig: _rig),
                    after: load,
                  )
                : null,
            child: const Text('Save to 2D view'),
          ),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SxHeader(
                'Rig test',
                sub:
                    '1. RIG ID comes on in ShowXpress by itself (or press it on the SETUP page): every 140 lights in its own look (key below). '
                    '2. Tap each truss spot and pick the look you see on that head. '
                    '3. Close ShowXpress (save first) and press Save to 2D view.',
                actions: [OutlinedButton(onPressed: load, child: const Text('Refresh'))],
              ),
              const _RemoteRow(),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null) ...[
                StateTag(dirty),
                _install(d),
                const SizedBox(height: 12),
                HeadGrid(children: [for (final h in d.heads) _LegendTile(h)]),
                const SizedBox(height: 14),
                _map(d, placed),
                const SizedBox(height: 10),
                _Check('Bigger event: 2 extra towers (top middle and bottom middle)', _extra, (v) => _edit(() => _extra = v)),
                _Check("Also update Tonight's Rig and Skip Flash (heads not on a truss = not hung)", _rig, (v) => setState(() => _rig = v)),
                if (d.saved case final s? when s.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Rig Test last saved ${s.replaceFirst('T', ' ')}', style: Sx.sub),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _install(RtPreview d) {
    final i = d.install;
    final String text, button;
    if (!i.scene || !i.button) {
      text = "The RIG ID button isn't in the show yet.";
      button = 'Add RIG ID to the SETUP page';
    } else if (i.old) {
      text = 'The RIG ID scene in the show is the old one (amber instead of light green, no visible flash).';
      button = 'Update RIG ID';
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x66FFB020)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(text, style: const TextStyle(color: Sx.amber, fontSize: 13)),
          FilledButton(
            onPressed: () => runSave(context, () => AppScope.read(context).client.rtInstall(), after: load),
            child: Text(button),
          ),
        ],
      ),
    );
  }

  Widget _map(RtPreview d, Map<String, String> placed) {
    Widget tower(String key) {
      final slots = d.slots.where((s) => s.tower == key).toList();
      final t = Container(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
        decoration: BoxDecoration(
          color: Sx.panel,
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              slots.first.towerName.toUpperCase(),
              style: const TextStyle(color: Sx.dim, fontSize: 10.5, letterSpacing: .8, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final (i, s) in slots.indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _SlotTile(
                      slot: s,
                      head: _head(d, _assign[s.key]),
                      changed: (d.assign[s.key] ?? '') != (_assign[s.key] ?? ''),
                      onTap: () => _pick(d, s),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
      return Expanded(
        child: slots.first.extra && !_extra ? Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: t) : t,
      );
    }

    final spare = d.heads.where((h) => !placed.containsValue(h.id)).toList();
    const gap = SizedBox(width: 8);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Sx.well,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [tower('tl'), gap, tower('tm'), gap, tower('tr')]),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: Sx.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(
                  spare.isEmpty ? 'Every 140 is on a truss' : 'Not on a truss, grouped in the middle of the 2D page',
                  style: const TextStyle(color: Sx.dim, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                if (spare.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: [for (final h in spare) Text('#${h.num}', style: const TextStyle(color: Sx.text2, fontSize: 12.5))],
                  ),
                ],
              ],
            ),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [tower('bl'), gap, tower('bm'), gap, tower('br')]),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0x80A3E635), width: 2)),
            ),
            child: const Text(
              '▲ DJ BOOTH (you) ▲',
              textAlign: TextAlign.center,
              style: TextStyle(color: Sx.accent, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }
}

/// A head's look: a color swatch, outlined when the look pulses.
class _Swatch extends StatelessWidget {
  const _Swatch(this.h);

  final RtHead h;
  static const size = 12.0;

  @override
  Widget build(BuildContext context) {
    final c = Color(0xFF000000 | (int.tryParse(h.hex, radix: 16) ?? 0));
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: h.flash ? null : c,
        shape: BoxShape.circle,
        border: h.flash ? Border.all(color: c, width: 2.5) : null,
      ),
    );
  }
}

/// One entry of the key: "#9  White flashing".
class _LegendTile extends StatelessWidget {
  const _LegendTile(this.h);

  final RtHead h;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    decoration: BoxDecoration(
      color: Sx.panel,
      border: Border.all(color: Sx.line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Swatch(h),
            const SizedBox(width: 5),
            Text('#${h.num}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
        Text(
          h.flash ? '${h.look} flashing' : h.look,
          style: const TextStyle(fontSize: 11, color: Sx.text2),
          textAlign: TextAlign.center,
          maxLines: 2,
        ),
      ],
    ),
  );
}

/// One mover spot on a tower.
class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.slot, required this.head, required this.changed, required this.onTap});

  final RtSlot slot;
  final RtHead? head;
  final bool changed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = head;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        constraints: const BoxConstraints(minHeight: 66),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: BoxDecoration(
          color: Sx.well,
          border: Border.all(color: changed ? Sx.blue : (h != null ? Sx.line2 : Sx.line)),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          children: [
            Text(
              '${slot.side} mover',
              style: const TextStyle(color: Sx.mute, fontSize: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (h == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'tap to set',
                  style: TextStyle(color: Sx.dim, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Swatch(h),
                  const SizedBox(width: 4),
                  Text('#${h.num}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ],
              ),
              Text(
                h.flash ? '${h.look} flashing' : h.look,
                style: const TextStyle(color: Sx.dim, fontSize: 11),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Pick the look you see on this head." Pops the head's id, '' for
/// nothing hung here, or null for cancel.
class _PickDialog extends StatelessWidget {
  const _PickDialog({required this.d, required this.slot, required this.current, required this.assign, required this.used});

  final RtPreview d;
  final RtSlot slot;
  final String? current;
  final Map<String, String> assign;
  final bool Function(String key) used;

  /// Where a head sits now, if somewhere else ("now top right left").
  String _where(String id) {
    final e = assign.entries.where((e) => e.value == id && e.key != slot.key && used(e.key)).firstOrNull;
    if (e == null) return '';
    final o = d.slots.firstWhere((s) => s.key == e.key);
    return 'now ${o.towerName.toLowerCase()} ${o.side}';
  }

  @override
  Widget build(BuildContext context) {
    Widget grid(bool flash) => HeadGrid(
      wideCols: 4,
      narrowCols: 4,
      children: [
        for (final h in d.heads.where((h) => h.flash == flash))
          InkWell(
            onTap: () => Navigator.pop(context, h.id),
            borderRadius: BorderRadius.circular(9),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              decoration: BoxDecoration(
                color: h.id == current ? rigOnFill : Sx.panel,
                border: Border.all(color: h.id == current ? Sx.accent : Sx.line),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Swatch(h),
                      const SizedBox(width: 4),
                      Text('#${h.num}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Text(
                    h.look,
                    style: const TextStyle(color: Sx.mute, fontSize: 10.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _where(h.id),
                    style: const TextStyle(color: Sx.mute, fontSize: 10.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    return AlertDialog(
      title: Text('${slot.towerName} tower, ${slot.side} mover', style: Sx.title),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Pick the look you see on this head.', style: Sx.sub),
              const GroupLabel('Solid'),
              grid(false),
              const GroupLabel('Flashing'),
              grid(true),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Nothing hung here')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

class _Check extends StatelessWidget {
  const _Check(this.text, this.value, this.onChanged);

  final String text;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact),
        Expanded(
          child: Text(text, style: const TextStyle(color: Sx.text2, fontSize: 13)),
        ),
      ],
    ),
  );
}

/// ShowXpress's remote control: SX Studio presses RIG ID so the heads light
/// up. The routes belong to the remote area; this calls them with the old
/// page's request shapes.
class _RemoteRow extends StatefulWidget {
  const _RemoteRow();

  @override
  State<_RemoteRow> createState() => _RemoteRowState();
}

class _RemoteRowState extends State<_RemoteRow> {
  static const _titles = ['RIG ID'];

  Json? _r;
  var _note = '';

  @override
  void initState() {
    super.initState();
    // When ShowXpress is open, turn RIG ID on straight away (unless the show is playing).
    _refresh(auto: AppScope.read(context).sxOpen);
  }

  Future<void> _refresh({bool auto = false}) async {
    final client = AppScope.read(context).client;
    Json r;
    try {
      r = auto ? (await client.run('/api/remote/press', {'titles': _titles, 'solo': true, 'idle': true})).toJson() : await client.get('/api/remote', (j) => j);
    } on ApiException catch (e) {
      r = {'ok': false, 'error': e.message};
    }
    if (!mounted) return;
    final pressedNow = r['pressedNow'];
    setState(() {
      _r = r;
      _note = auto && r.boolean('connected') && !r.boolean('skipped') && pressedNow is List && pressedNow.isNotEmpty ? '✓ Turned on by SX Studio. ' : '';
    });
  }

  Future<bool> _ask(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title, style: Sx.title),
          content: Text(body, style: const TextStyle(color: Sx.text2)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  Future<void> _act(Future<ToolResult> Function(SxClient c) call) async {
    final r = await call(AppScope.read(context).client);
    if (!mounted) return;
    setState(() {
      _r = r.toJson();
      _note = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final r = _r;
    final List<Widget> parts;
    if (r == null) {
      parts = [const Text('Checking ShowXpress.', style: TextStyle(color: Sx.text2, fontSize: 13))];
    } else if (r['ok'] == false && r['setup'] == null) {
      parts = [_text(r.str('error')), MiniButton('Try again', _refresh)];
    } else if (!r.boolean('ready')) {
      parts = [
        _text(
          'Let SX Studio press RIG ID for you. Turn on ShowXpress remote control once, it is saved in the show${app.sxOpen ? ' (done when ShowXpress next closes).' : '.'}',
        ),
        MiniButton('Turn on remote control', () async {
          if (!await _ask(
            'Turn on ShowXpress remote control?',
            'Lets SX Studio press buttons in ShowXpress (RIG ID, DF CHECK, ROOM CHECK, Auto Show). It switches on External App in ShowXpress and remote access for every Live page, with a password only SX Studio uses. Only this computer connects to it.',
            'Turn it on',
          )) {
            return;
          }
          if (!context.mounted) return;
          await runSave(context, () => app.client.run('/api/remote/enable'), after: _refresh);
        }),
      ];
    } else if (!r.boolean('open')) {
      parts = [
        _text('ShowXpress is closed. Open it and SX Studio turns on RIG ID by itself.'),
        MiniButton('Launch ShowXpress', () => _act((c) => c.run('/api/sx/launch'))),
      ];
    } else if (!r.boolean('connected')) {
      parts = [_text(r.str('error')), MiniButton('Try again', _refresh)];
    } else {
      final pressed = r.list('pressed', (j) => (title: j.str('title'), page: j.str('page')));
      final on = {for (final p in pressed) p.title};
      final have = r.strList('titles').toSet();
      final playing = r.strList('playing');
      final isOn = _titles.every(on.contains);
      parts = [
        _text(
          '$_note'
          '${r.boolean('skipped') ? "Your show is playing (${playing.take(4).join(', ')}${playing.length > 4 ? '...' : ''}), SX Studio didn't press anything, so it isn't cut. " : ''}'
          '${isOn
              ? '● RIG ID is on in ShowXpress.'
              : on.isNotEmpty
              ? 'Playing: ${on.take(5).join(', ')}${on.length > 5 ? '...' : ''}'
              : 'Nothing is playing in ShowXpress.'}',
          color: isOn ? Sx.green : Sx.text2,
        ),
        MiniButton(
          'RIG ID',
          _titles.any((t) => !have.contains(t))
              ? null
              : () async {
                  final others = [
                    for (final p in pressed)
                      if (!RegExp(r'^\s*setup\s*$', caseSensitive: false).hasMatch(p.page) && !_titles.contains(p.title)) p.title,
                  ];
                  if (others.isNotEmpty &&
                      !await _ask(
                        'Turn off what is playing?',
                        '${others.take(6).join(', ')} ${others.length > 1 ? 'are' : 'is'} playing. Turning on RIG ID turns ${others.length > 1 ? 'them' : 'it'} off.',
                        'Turn on RIG ID',
                      )) {
                    return;
                  }
                  await _act((c) => c.run('/api/remote/press', {'titles': _titles, 'solo': true}));
                },
        ),
        if (on.isNotEmpty)
          MiniButton('All off', () async {
            if (!await _ask('Turn everything off?', 'Releases every button that is playing in ShowXpress.', 'All off')) return;
            await _act((c) => c.run('/api/remote/off', {}));
          }),
      ];
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x0D3DDC84),
        border: Border.all(color: const Color(0x4D3DDC84)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: parts),
    );
  }

  Widget _text(String s, {Color color = Sx.text2}) => Text(s, style: TextStyle(color: color, fontSize: 13));
}
