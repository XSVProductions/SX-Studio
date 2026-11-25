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

class _RigScreenState extends State<RigScreen> with ShowWatcher, RigReloads {
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
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
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
              RigHeader(
                "Tonight's rig",
                sub:
                    'Tap the movers that are hung tonight. Every chase scene (CHASE, SKIP AROUND, the BEAT scenes, SKIP FLASH...) drops the steps that would be dark without them, so nothing stutters. Tick them all again to put every scene back.',
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
        if (d != null) ...[
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reversed heads', style: Sx.title),
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    style: Sx.sub,
                    children: [
                      const TextSpan(
                        text: "Use this instead of Pan / Tilt Reverse in a fixture's own menu. A head hung so it moves the same way as its partner? Tap ",
                      ),
                      TextSpan(text: 'pan', style: b),
                      const TextSpan(text: ' (or '),
                      TextSpan(text: 'tilt', style: b),
                      const TextSpan(
                        text:
                            ') on it: every scene and movement in the show is flipped for that head, exactly what the fixture\'s menu does. Tap again to put it back. Leave the fixture\'s own menu as it is, and set this ',
                      ),
                      TextSpan(text: 'before', style: b),
                      const TextSpan(text: ' you aim the movers.'),
                    ],
                  ),
                ),
                _flipGroup(d, true),
                _flipGroup(d, false),
              ],
            ),
          ),
          SxCard(child: _scenes(d, b)),
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
                  blue: true,
                  extra: Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      _Axis('pan', Icons.swap_horiz, 'Reverse pan (left / right)', f.pan, () => toggle(h.id, true)),
                      _Axis('tilt', Icons.swap_vert, 'Reverse tilt (up / down)', f.tilt, () => toggle(h.id, false)),
                    ],
                  ),
                );
              }(),
          ],
        ),
      ],
    );
  }

  Widget _scenes(RigPreview d, TextStyle b) {
    final drops = [for (final s in d.scenes) s.dropFor(_hung)];
    final trimmed = drops.where((x) => x != null && x.isNotEmpty).length;
    WidgetSpan sw(Widget box) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(padding: const EdgeInsets.only(right: 4), child: box),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              Text('Chase scenes', style: Sx.title),
              Text.rich(
                TextSpan(
                  style: TextStyle(color: Sx.dim, fontSize: 13),
                  children: [
                    TextSpan(text: '${d.scenes.length}', style: b),
                    const TextSpan(text: ' chase scenes · '),
                    TextSpan(text: '$trimmed', style: b),
                    const TextSpan(text: ' trimmed for this rig'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (d.scenes.isEmpty) Text('No chase scenes found on your live buttons.', style: Sx.sub),
        for (final (i, s) in d.scenes.indexed) Padding(padding: const EdgeInsets.only(bottom: 6), child: _SceneRow(s, drops[i])),
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(
            style: Sx.sub,
            children: [
              sw(_Swatch(Sx.accent)),
              const TextSpan(text: 'movers lit   '),
              sw(_Swatch(Sx.blue)),
              const TextSpan(text: 'blinder / uplight only   '),
              sw(_Swatch(Sx.tabOn)),
              const TextSpan(text: 'dark   '),
              sw(DashedBox(color: Sx.red, child: const SizedBox(width: 12, height: 12))),
              const TextSpan(
                text:
                    'taken out tonight. Only whole steps are taken out. Colors and timing stay as they are. A step that also lights a blinder or uplight is always kept.',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A pan or tilt toggle inside a reversed-heads tile, the old app's `.fx`.
class _Axis extends StatelessWidget {
  const _Axis(this.text, this.icon, this.tip, this.on, this.onTap);

  final String text;
  final IconData icon;
  final String tip;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 7, 2, 0),
    child: Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: on ? Sx.blue.withValues(alpha: .25) : null,
            border: Border.all(color: on ? Sx.blue : Sx.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: on ? Sx.text : Sx.mute),
              const SizedBox(width: 3),
              Text(
                text,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: on ? Sx.text : Sx.mute),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One chase scene, the old app's `.sc`: name, a square per step, and how many steps stay.
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
    final b = TextStyle(color: Sx.text, fontWeight: FontWeight.w700);
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              s.name,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Sx.text),
            ),
            if (s.trimmed) _Tag('trimmed now', Sx.amber, .4, 'trimmed for the rig saved last time'),
            if (s.edited) _Tag('edited', Sx.red, .45, 'Changed in ShowXpress while it was trimmed. That version now counts as the full scene.'),
          ],
        ),
        if (others.isNotEmpty) Text('button: ${others.join(', ')}', style: TextStyle(color: Sx.dim, fontSize: 11.5)),
      ],
    );
    final dots = Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final (i, st) in s.steps.indexed)
          Tooltip(
            message:
                'step ${i + 1}: ${out.contains(i)
                    ? 'taken out tonight'
                    : st.lit.isNotEmpty
                    ? '${st.lit.length} mover(s) lit'
                    : st.other
                    ? 'blinder / uplight only'
                    : 'dark'}',
            child: out.contains(i)
                ? DashedBox(color: Sx.red, child: const SizedBox(width: 14, height: 14))
                : _Swatch(
                    st.lit.isNotEmpty
                        ? Sx.accent
                        : st.other
                        ? Sx.blue
                        : Sx.tabOn,
                    size: 14,
                    edge: false,
                  ),
          ),
      ],
    );
    final status = drop == null
        ? Text('none of its heads hung, kept complete', style: TextStyle(color: Sx.amber, fontSize: 12))
        : Text.rich(
            TextSpan(
              style: TextStyle(color: Sx.dim, fontSize: 12),
              children: out.isNotEmpty ? [TextSpan(text: '${n - out.length}', style: b), TextSpan(text: ' of $n steps')] : [TextSpan(text: 'all $n steps')],
            ),
          );
    final wide = MediaQuery.sizeOf(context).width > 860;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: out.isNotEmpty ? Sx.blue.withValues(alpha: .45) : Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: wide
          ? Row(
              children: [
                SizedBox(width: 250, child: name),
                const SizedBox(width: 12),
                Expanded(child: dots),
                const SizedBox(width: 12),
                status,
              ],
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 12), dots, const SizedBox(height: 12), status]),
    );
  }
}

/// A small outlined pill after a scene name, the old app's `.tag`.
class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color, this.edge, this.tip);

  final String text;
  final Color color;
  final double edge;
  final String tip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: edge)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// A filled square: a step in a scene's row of dots, or a legend swatch.
class _Swatch extends StatelessWidget {
  const _Swatch(this.color, {this.size = 12, this.edge = true});

  final Color color;
  final double size;

  /// The legend's faint outline (`.sw`). The step dots have none.
  final bool edge;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      border: edge ? Border.all(color: Sx.text.withValues(alpha: .2)) : null,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}
