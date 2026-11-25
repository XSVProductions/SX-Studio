import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import 'rig_widgets.dart';

/// Tonight's Rig: which movers are hung tonight, and which heads SX Studio
/// reverses. Both are saved together.
class RigScreen extends StatefulWidget {
  const RigScreen(BuildContext _, {super.key});

  @override
  State<RigScreen> createState() => _RigScreenState();
}

class _RigScreenState extends State<RigScreen> with ReloadWhenShown {
  RigPreview? _data;
  var _error = '';

  /// Heads ticked as hung, saved or not.
  final _hung = <String>{};

  /// Reversed axes per head, saved or not. Always the full list.
  final _flip = <String, Flip>{};

  @override
  String get tabId => 'rig';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Future<void> load() async {
    final app = AppScope.read(context);
    try {
      final d = await app.client.rig();
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

  void _reset(RigPreview d) {
    _hung
      ..clear()
      ..addAll([
        for (final h in d.heads)
          if (h.on) h.id,
      ]);
    _flip
      ..clear()
      ..addAll({for (final h in d.heads) h.id: (pan: h.rp, tilt: h.rt)});
  }

  bool _flipChanged(RigHead h) {
    final f = _flip[h.id];
    return (f?.pan ?? false) != h.rp || (f?.tilt ?? false) != h.rt;
  }

  bool get _hungDirty => _data != null && _data!.heads.any((h) => h.on != _hung.contains(h.id));
  bool get _flipDirty => _data != null && _data!.heads.any(_flipChanged);

  @override
  bool get dirty => _hungDirty || _flipDirty;

  void _edit(VoidCallback f) {
    setState(f);
    AppScope.read(context).setDirty(tabId, dirty);
  }

  void _undo() => _edit(() => _reset(_data!));

  Future<void> _save() => runSave(
    context,
    () => AppScope.read(context).client.rigApply([
      for (final h in _data!.heads)
        if (_hung.contains(h.id)) h.id,
    ], _flip),
    after: load,
  );

  String _hint(AppState app) {
    if (_data == null) return '';
    if (app.sxOpen) return 'ShowXpress is open. A save waits until it closes.';
    if (_hung.isEmpty) return 'Tick at least one head.';
    if (!dirty) return 'The show already matches these heads.';
    return [
      if (_flipDirty) 'Reversed heads: every scene and movement flips for those heads.',
      if (_hungDirty) 'Only chase scenes change for the hung heads. The full scenes are kept, so ticking every head puts them back.',
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final d = _data;
    return ScreenBody(
      bar: SaveBar(
        hint: _hint(app),
        actions: [
          TextButton(onPressed: d != null && dirty ? _undo : null, child: const Text('Undo')),
          OutlinedButton(
            onPressed: d == null || d.heads.every((h) => _hung.contains(h.id)) ? null : () => _edit(() => _hung.addAll(d.heads.map((h) => h.id))),
            child: const Text('All heads'),
          ),
          FilledButton(onPressed: d != null && dirty && _hung.isNotEmpty ? _save : null, child: const Text('Save')),
        ],
      ),
      children: [
        SxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SxHeader(
                "Tonight's rig",
                sub:
                    'Tap the movers that are hung tonight. Every chase scene (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH...) drops the steps that would be dark without them, so nothing stutters. Tick them all again to put every scene back.',
                actions: [OutlinedButton(onPressed: load, child: const Text('Refresh'))],
              ),
              ErrorBox(_error),
              if (d == null && _error.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('Reading the show.', style: Sx.sub),
                ),
              if (d != null) ...[StateTag(dirty), _group(d, true), _group(d, false)],
            ],
          ),
        ),
        if (d != null) ...[
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SxHeader(
                  'Reversed heads',
                  sub:
                      "Use this instead of Pan / Tilt Reverse in a fixture's own menu. A head hung so it moves the same way as its partner? Tap pan (or tilt) on it: every scene and movement in the show is flipped for that head, exactly what the fixture's menu does. Tap again to put it back. Set this before you aim the movers.",
                ),
                _flipGroup(d, true),
                _flipGroup(d, false),
              ],
            ),
          ),
          SxCard(child: _scenes(d)),
        ],
      ],
    );
  }

  Widget _group(RigPreview d, bool is140) {
    final hs = d.heads.where((h) => h.is140 == is140).toList();
    if (hs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeadGroupHeader(
          is140 ? '140SR' : '251SR',
          '${hs.where((h) => _hung.contains(h.id)).length} of ${hs.length} hung',
          onAll: () => _edit(() => _hung.addAll(hs.map((h) => h.id))),
          onNone: () => _edit(() => _hung.removeAll(hs.map((h) => h.id))),
        ),
        HeadGrid(
          children: [
            for (final h in hs)
              HeadTile(
                title: '#${h.num}',
                sub: _hung.contains(h.id) ? 'hung' : 'not here',
                on: _hung.contains(h.id),
                changed: _hung.contains(h.id) != h.on,
                onTap: () => _edit(() => _hung.contains(h.id) ? _hung.remove(h.id) : _hung.add(h.id)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _flipGroup(RigPreview d, bool is140) {
    final hs = d.heads.where((h) => h.is140 == is140).toList();
    if (hs.isEmpty) return const SizedBox.shrink();
    final n = hs.where((h) => (_flip[h.id]?.pan ?? false) || (_flip[h.id]?.tilt ?? false)).length;
    void toggle(String id, bool pan) => _edit(() {
      final f = _flip[id] ?? (pan: false, tilt: false);
      _flip[id] = pan ? (pan: !f.pan, tilt: f.tilt) : (pan: f.pan, tilt: !f.tilt);
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HeadGroupHeader(is140 ? '140SR' : '251SR', n > 0 ? '$n reversed' : 'none reversed'),
        HeadGrid(
          children: [
            for (final h in hs)
              () {
                final f = _flip[h.id] ?? (pan: false, tilt: false);
                return HeadTile(
                  title: '#${h.num}',
                  on: f.pan || f.tilt,
                  changed: _flipChanged(h),
                  onColor: Sx.blue,
                  onFill: rigBlueFill,
                  extra: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      children: [_Axis('↔ pan', f.pan, () => toggle(h.id, true)), _Axis('↕ tilt', f.tilt, () => toggle(h.id, false))],
                    ),
                  ),
                );
              }(),
          ],
        ),
      ],
    );
  }

  Widget _scenes(RigPreview d) {
    final drops = [for (final s in d.scenes) s.dropFor(_hung)];
    final trimmed = drops.where((x) => x != null && x.isNotEmpty).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Chase scenes', style: Sx.title)),
            Text('${d.scenes.length} chase scenes · $trimmed trimmed for this rig', style: const TextStyle(color: Sx.text2, fontSize: 12.5)),
          ],
        ),
        const SizedBox(height: 10),
        if (d.scenes.isEmpty) const Text('No chase scenes found on your live buttons.', style: Sx.sub),
        for (final (i, s) in d.scenes.indexed) _SceneRow(s, drops[i]),
        const SizedBox(height: 10),
        const Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            _Legend(Sx.accent, 'movers lit'),
            _Legend(Sx.blue, 'blinder / uplight only'),
            _Legend(Sx.line, 'dark'),
            _Legend(null, 'taken out tonight'),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Only whole steps are taken out. Colors and timing stay as they are. A step that also lights a blinder or uplight is always kept.',
          style: Sx.sub,
        ),
      ],
    );
  }
}

/// A pan or tilt toggle inside a head tile.
class _Axis extends StatelessWidget {
  const _Axis(this.text, this.on, this.onTap);

  final String text;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(7),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: on ? const Color(0x405096FF) : null,
        border: Border.all(color: on ? Sx.blue : Sx.line),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: on ? Sx.text : Sx.mute),
      ),
    ),
  );
}

/// One chase scene: name, a square per step, and how many steps stay.
class _SceneRow extends StatelessWidget {
  const _SceneRow(this.s, this.drop);

  final RigScene s;

  /// Steps taken out for the ticked heads, or null when none of its heads are hung.
  final Set<int>? drop;

  @override
  Widget build(BuildContext context) {
    final out = drop ?? const <int>{};
    final n = s.steps.length;
    final others = s.titles.where((t) => t != s.name).toList();
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (s.trimmed) const _Tag('trimmed now', Sx.amber),
            if (s.edited) const _Tag('edited', Sx.red),
          ],
        ),
        if (others.isNotEmpty) Text('button: ${others.join(', ')}', style: const TextStyle(color: Sx.dim, fontSize: 11.5)),
      ],
    );
    final dots = Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final (i, st) in s.steps.indexed)
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: out.contains(i)
                  ? null
                  : st.lit.isNotEmpty
                  ? Sx.accent
                  : st.other
                  ? Sx.blue
                  : Sx.line,
              border: out.contains(i) ? Border.all(color: Sx.red) : null,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
    final status = drop == null
        ? const Text('none of its heads hung, kept complete', style: TextStyle(color: Sx.amber, fontSize: 12))
        : Text(out.isNotEmpty ? '${n - out.length} of $n steps' : 'all $n steps', style: const TextStyle(color: Sx.dim, fontSize: 12));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: out.isNotEmpty ? const Color(0x735AA9FF) : Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 560
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 6), dots, const SizedBox(height: 6), status])
            : Row(
                children: [
                  SizedBox(width: 220, child: name),
                  const SizedBox(width: 12),
                  Expanded(child: dots),
                  const SizedBox(width: 12),
                  status,
                ],
              ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
  );
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.text);

  /// Null for the outlined "taken out" square.
  final Color? color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: color,
          border: color == null ? Border.all(color: Sx.red) : null,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 5),
      Text(text, style: const TextStyle(color: Sx.dim, fontSize: 12)),
    ],
  );
}
