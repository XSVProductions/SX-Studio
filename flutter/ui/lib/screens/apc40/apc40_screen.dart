import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../widgets/sx_widgets.dart';
import '../apc/apc_palette.dart';
import '../apc/apc_parts.dart';
import 'apc40_edits.dart';

const _tab = 'apc40';

/// APC40: up to 8 pages of 40 pads, each playing a ShowXpress button the
/// user picks, and what the 9 faders move. Saves SX Studio's own
/// `apc40.json`, never a show file, so ShowXpress can stay open. Port of the
/// old page's `v-apc40` view and its `a4...` script.
class Apc40Screen extends StatefulWidget {
  const Apc40Screen(BuildContext _, {super.key});

  @override
  State<Apc40Screen> createState() => _Apc40ScreenState();
}

class _Apc40ScreenState extends State<Apc40Screen> {
  Apc40Edits? _e;
  var _error = '';
  var _loading = true;
  Apc40Status? _status;

  /// What the bar says for 5 s after a save, a fill or a move to another page.
  var _msg = '';
  var _msgFailed = false;
  Timer? _msgT;

  Timer? _pollT;
  var _polling = false;

  /// [AppState.imports] as last seen.
  late int _imports = AppScope.read(context).imports;

  /// The grid, the side panel, the page tabs and the bar: a press outside
  /// them lets go of the picked pad.
  final _keep = Object();

  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _list = ScrollController();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _edit((e) => e.renameDone());
    });
    _load();
  }

  /// The status poll runs while the tab is on show, as the old `a4Poll`.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    // a settings import replaced the pages
    if (_imports != app.imports) {
      _imports = app.imports;
      _load();
    }
    if (app.tab == _tab) {
      if (_pollT == null && !_polling) _poll();
    } else {
      _pollT?.cancel();
      _pollT = null;
    }
  }

  @override
  void dispose() {
    _pollT?.cancel();
    _msgT?.cancel();
    _query.dispose();
    _queryFocus.dispose();
    _list.dispose();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  bool get _shown => mounted && AppScope.read(context).tab == _tab;

  Future<void> _poll() async {
    _pollT = null;
    if (!_shown) return;
    _polling = true;
    try {
      final s = await AppScope.read(context).client.apc40Status();
      // Most polls bring the same status. Redraw only when the line it shows changes.
      final e = _e;
      if (e != null && apc40StatusLine(e.info.windows, s) == apc40StatusLine(e.info.windows, _status)) {
        _status = s;
      } else if (mounted) {
        setState(() => _status = s);
      }
    } on Exception {
      // The next poll tries again, as the old one did.
    }
    _polling = false;
    if (_shown) _pollT = Timer(const Duration(milliseconds: 1500), _poll);
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    _loading = true;
    try {
      final d = await app.client.apc40();
      if (!mounted) return;
      setState(() {
        final e = Apc40Edits(d);
        e.page = (_e?.page ?? 0).clamp(0, e.layout.pages.length - 1);
        _e = e;
        if (d.status != null) _status = d.status;
        _error = '';
        _syncName();
      });
    } on ApiException catch (x) {
      if (!mounted) return;
      setState(() {
        _e = null;
        _error = x.message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    app.setDirty(_tab, false);
  }

  /// Runs an edit, redraws, and tells the tab bar whether anything is unsaved.
  void _edit(void Function(Apc40Edits e) f) {
    final e = _e;
    if (e == null || !mounted) return;
    setState(() {
      f(e);
      _syncName();
    });
    AppScope.read(context).setDirty(_tab, e.dirty);
  }

  /// The page name box shows the page on show. Typing in it changes the
  /// name, so the two only differ after another edit.
  void _syncName() {
    final e = _e;
    if (e != null && _name.text != e.pg.name) _name.text = e.pg.name;
  }

  /// Shows [m] in the bar for 5 s, the old `a4Say`.
  void _say(String m, {bool failed = false}) {
    _msgT?.cancel();
    setState(() {
      _msg = m;
      _msgFailed = failed;
    });
    _msgT = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _msg = '');
    });
  }

  void _deselect() {
    if (_e == null || _e!.selected < 0 || !_shown) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _edit((e) => e.selected = -1);
  }

  /// A tap on pad [n]. A mouse puts the cursor in the button search, as the
  /// old page did. A finger doesn't, so the phone keyboard stays down.
  void _tap(int n, PointerDeviceKind kind) {
    _edit((e) => e.tap(n));
    if (_e!.selected >= 0 && kind == PointerDeviceKind.mouse) _queryFocus.requestFocus();
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final e = _e!;
    app.setBusy('Saving the APC40 pages.');
    try {
      final r = await app.client.apc40Save(e.layout);
      if (!mounted) return;
      setState(() {
        final n = Apc40Edits(r)
          ..page = e.page.clamp(0, r.layout.pages.isEmpty ? 0 : r.layout.pages.length - 1)
          ..selected = e.selected
          ..colourOpen = e.colourOpen;
        _e = n;
        if (r.status != null) _status = r.status;
        _syncName();
      });
      app.setDirty(_tab, _e!.dirty);
      _say('Saved. The APC40 uses it straight away.');
    } on ApiException catch (x) {
      if (mounted) _say('Not saved: ${x.message.isEmpty ? 'unknown problem' : x.message}', failed: true);
    } finally {
      app.setBusy('');
    }
  }

  Future<bool> _ask(String question, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(question, style: Sx.title),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  /// The old pad `contextmenu`.
  void _menu(int n, Offset at) {
    final e = _e!;
    final t = e.pg.pads[n];
    showPadMenu(context, at, '${t ?? 'Empty pad'} - ${a4Place(n)}', [
      (
        text: t == null ? 'Choose a button…' : 'Change the button…',
        enabled: true,
        go: () {
          _edit((e) => e.selected = n);
          _queryFocus.requestFocus();
        },
      ),
      (
        text: 'Pad colour…',
        enabled: e.buttonOn(n) != null,
        go: () => _edit((e) {
          e.selected = n;
          e.colourOpen = true;
        }),
      ),
      (text: 'Use the ShowXpress button colour', enabled: e.pg.colors.containsKey(n), go: () => _edit((e) => e.useButtonColour(n))),
      (text: 'Clear this pad', enabled: t != null, go: () => _edit((e) => e.clear(n, deselect: true))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    final dirty = e?.dirty ?? false;
    final stacked = MediaQuery.sizeOf(context).width <= 860;
    return EscCatcher(
      onEsc: _deselect,
      child: ScreenBody(
        bar: TapRegion(
          groupId: _keep,
          child: SaveBar(
            failed: _msg.isNotEmpty && _msgFailed,
            hint: _msg.isNotEmpty
                ? _msg
                : e == null
                ? ''
                : dirty
                ? "Not saved yet. Saving only changes SX Studio's own APC40 settings. ShowXpress can stay open."
                : 'The APC40 is using these pages.',
            actions: [
              OutlinedButton(onPressed: dirty ? () => _edit((e) => e.undo()) : null, child: const Text('Undo changes')),
              FilledButton(onPressed: dirty ? _save : null, child: const Text('Save APC40 pages')),
            ],
          ),
        ),
        children: [
          SxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(e),
                ErrorBox(_error),
                if (e == null && _error.isEmpty && _loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text('Reading the APC40 pages.', style: Sx.sub),
                  ),
                if (e != null) ...[
                  _conn(e),
                  _pages(e),
                  const SizedBox(height: 14),
                  if (stacked) ...[_grid(e), const SizedBox(height: 18), _side(e)],
                  if (!stacked)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _grid(e)),
                        const SizedBox(width: 18),
                        SizedBox(width: 270, child: _side(e)),
                      ],
                    ),
                ],
              ],
            ),
          ),
          if (e != null)
            SxCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('APC40 faders', style: Sx.title),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      "What each fader moves in ShowXpress (its master faders). A speed fader's middle is normal speed: down = slower, up = faster.",
                      style: Sx.sub,
                    ),
                  ),
                  _faders(e),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(Apc40Edits? e) {
    final phone = sxGutter(context) < 22;
    const b = TextStyle(fontWeight: FontWeight.w700);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('APC40 pads', style: Sx.title),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(
              style: Sx.sub,
              children: const [
                TextSpan(text: 'Up to 8 pages of your own, 40 pads each. Put any ShowXpress button on any pad. On the APC40 the numbered '),
                TextSpan(text: 'Track Select', style: b),
                TextSpan(
                  text:
                      " buttons under the pads switch pages. A pad turns its button on (press again for off) and shows its ShowXpress colour (or a colour you pick for that pad), bright while it's on. The top ",
                ),
                TextSpan(text: 'Scene Launch', style: b),
                TextSpan(text: " button is green while ShowXpress is connected. The APC mini, ShowXpress's pages and the show aren't changed."),
              ],
            ),
          ),
        ),
      ],
    );
    final refresh = OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh'));
    final tag = e == null ? null : _SavedTag(e.dirty);
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          text,
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [?tag, refresh]),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: text),
        if (tag != null) Padding(padding: const EdgeInsets.only(left: 12), child: tag),
        Padding(padding: const EdgeInsets.only(left: 8), child: refresh),
      ],
    );
  }

  /// The status line, the old `#a4conn`.
  Widget _conn(Apc40Edits e) {
    final s = apc40StatusLine(e.info.windows, _status);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 13, color: Sx.text),
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (s.dot) {
                    Apc40Dot.amber => Sx.amber,
                    Apc40Dot.green => Sx.green,
                    Apc40Dot.red => Sx.red,
                  },
                ),
              ),
            ),
            if (s.bold.isNotEmpty)
              TextSpan(
                text: s.bold,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            TextSpan(text: s.text),
            if (s.last.isNotEmpty)
              TextSpan(
                text: '   last pad: ${s.last}',
                style: TextStyle(color: Sx.dim),
              ),
          ],
        ),
      ),
    );
  }

  /// The page tabs, the old `#a4pages`. A pad dropped on another page's tab
  /// goes to the same spot there.
  Widget _pages(Apc40Edits e) => TapRegion(
    groupId: _keep,
    onTapOutside: (_) => _deselect(),
    child: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (i, p) in e.layout.pages.indexed)
            DragTarget<int>(
              onWillAcceptWithDetails: (_) => i != e.page,
              onAcceptWithDetails: (d) {
                final m = e.dropOnPage(d.data, i);
                _edit((_) {});
                _say(m);
              },
              builder: (context, over, _) => Tooltip(
                message: 'Track Select ${i + 1}',
                child: _PageTab('${i + 1} · ${p.name}', on: i == e.page, drop: over.isNotEmpty, onTap: () => _edit((e) => e.showPage(i))),
              ),
            ),
          if (e.layout.pages.length < 8)
            MiniButton(
              'Add a page',
              icon: Icons.add,
              onPressed: () {
                _edit((e) => e.addPage());
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _nameFocus.requestFocus();
                  _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
                });
              },
            ),
        ],
      ),
    ),
  );

  /// The 5 x 8 pads as they sit on the APC40, top row first.
  Widget _grid(Apc40Edits e) => TapRegion(
    groupId: _keep,
    onTapOutside: (_) => _deselect(),
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: apcBody,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: PadGrid(rows: 5, cell: (r, c, size) => _cell(e, (4 - r) * 8 + c, size)),
    ),
  );

  Widget _cell(Apc40Edits e, int n, double size) => DragTarget<int>(
    onAcceptWithDetails: (d) => _edit((e) => e.drop(d.data, n)),
    builder: (context, over, _) => PadDraggable<int>(
      data: e.pg.pads.containsKey(n) ? n : null,
      size: Size.square(size),
      child: GestureDetector(
        onTapUp: (d) => _tap(n, d.kind),
        onSecondaryTapUp: (d) => _menu(n, d.globalPosition),
        child: _A4Pad(edits: e, n: n, drop: over.isNotEmpty),
      ),
    ),
  );

  Widget _side(Apc40Edits e) => TapRegion(
    groupId: _keep,
    onTapOutside: (_) => _deselect(),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Sx.panel,
        border: Border.all(color: Sx.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 13, color: Sx.text),
        child: e.selected >= 0 ? _padPanel(e) : _pagePanel(e),
      ),
    ),
  );

  /// The side panel with a pad picked: what it plays, its colours and the
  /// button list.
  Widget _padPanel(Apc40Edits e) {
    final n = e.selected;
    final cur = e.pg.pads[n];
    final cb = e.buttonOn(n);
    final own = cur != null && e.pg.colors.containsKey(n);
    final groups = e.listed(_query.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pad: ${a4Place(n)}', style: Sx.title),
        ApcKv([
          (
            'Plays',
            cur == null
                ? const Text('nothing yet')
                : Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(cur),
                      if (cb != null) ApcTag(cb.pageName, null) else Text('  not in ShowXpress!', style: TextStyle(color: Sx.red)),
                    ],
                  ),
          ),
          if (cb != null)
            (
              'Light',
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  PadSwatch(padColor(e.colour(n, true) ?? -1)),
                  const Text('playing  '),
                  PadSwatch(padColor(e.colour(n, false) ?? -1)),
                  const Text('idle'),
                  ApcTag(own ? 'own' : 'from ShowXpress', own ? Sx.blue : null),
                ],
              ),
            ),
        ]),
        if (cb != null) _colours(e, n, own),
        TextField(
          controller: _query,
          focusNode: _queryFocus,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(hintText: 'Search ShowXpress buttons…', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
          onChanged: (_) => setState(() {}),
        ),
        Container(
          margin: const EdgeInsets.only(top: 8, bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          constraints: const BoxConstraints(maxHeight: 360),
          decoration: BoxDecoration(
            border: Border.all(color: Sx.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: groups.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('No button matches.', style: Sx.sub),
                )
              : Scrollbar(
                  controller: _list,
                  child: ListView(
                    controller: _list,
                    shrinkWrap: true,
                    children: [
                      for (final (page, list) in groups) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                          child: Text(page.toUpperCase(), style: TextStyle(fontSize: 11, color: Sx.dim, letterSpacing: .44)),
                        ),
                        for (final b in list) _ButtonRow(b, current: b.title == cur, onTap: () => _edit((e) => e.assign(b.title))),
                      ],
                    ],
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('Tap a button to put it on this pad. Then it moves on to the next pad, so you can fill a row quickly.', style: Sx.sub),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(onPressed: cur == null ? null : () => _edit((e) => e.clear(n)), child: const Text('Clear this pad')),
            OutlinedButton(onPressed: () => _edit((e) => e.selected = -1), child: const Text('Done')),
          ],
        ),
      ],
    );
  }

  /// "Pad colour", the old `details.a4col`: open when the pad has its own
  /// colours or the user opened it.
  Widget _colours(Apc40Edits e, int n, bool own) {
    final open = own || e.colourOpen;
    final label = TextStyle(fontSize: 12, color: Sx.dim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => _edit((e) => e.colourOpen = !open),
          child: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(open ? Icons.arrow_drop_down : Icons.arrow_right, size: 18, color: Sx.text),
                const Text('Pad colour', style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
        if (open) ...[
          Text('Colour while playing', style: label),
          PadPalette(current: e.colour(n, true) ?? -1, onPick: (v) => _edit((e) => e.setColour(n, true, v))),
          Text('Colour when idle', style: label),
          PadPalette(current: e.colour(n, false) ?? -1, onPick: (v) => _edit((e) => e.setColour(n, false, v))),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            child: MiniButton('Use the ShowXpress button colour', onPressed: own ? () => _edit((e) => e.useButtonColour(n)) : null),
          ),
        ],
      ],
    );
  }

  /// The side panel with no pad picked: the page's name, fill and the page buttons.
  Widget _pagePanel(Apc40Edits e) {
    final used = e.pg.pads.length;
    final i = e.page;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Page ${i + 1}', style: Sx.title),
        ApcKv([
          (
            'Name',
            TextField(
              controller: _name,
              focusNode: _nameFocus,
              maxLength: 30,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(counterText: '', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
              onChanged: (v) => _edit((e) => e.rename(v)),
              onSubmitted: (_) => _edit((e) => e.renameDone()),
            ),
          ),
          ('Pads', Text('$used of 40 used')),
          ('On the APC40', Text('Track Select ${i + 1}')),
        ]),
        Text(
          'Tap a pad to choose what it plays and its colour (pads take the ShowXpress button colour until you pick one). '
          'Drag a pad to move it (onto another pad to swap, onto a page tab to send it to that page). Right-click a pad for more.',
          style: Sx.sub,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _Select<String>(
            value: null,
            hint: 'Fill the empty pads from a ShowXpress page…',
            items: {for (final p in e.sxPages) p: p},
            onPick: (p) {
              String m = '';
              _edit((e) => m = e.fill(p));
              _say(m);
            },
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (i > 0) MiniButton('Move page left', icon: Icons.arrow_back, onPressed: () => _edit((e) => e.movePage(i - 1))),
            if (i < e.layout.pages.length - 1) MiniButton('Move page right', icon: Icons.arrow_forward, onPressed: () => _edit((e) => e.movePage(i + 1))),
            if (e.layout.pages.length > 1)
              MiniButton(
                'Delete this page',
                onPressed: () async {
                  if (await _ask('Delete page ${i + 1} (${e.pg.name})?', 'Delete')) _edit((e) => e.deletePage());
                },
              ),
            if (used > 0)
              MiniButton(
                'Clear all pads',
                onPressed: () async {
                  if (await _ask('Clear every pad on ${e.pg.name}?', 'Clear')) _edit((e) => e.clearAll());
                },
              ),
          ],
        ),
      ],
    );
  }

  /// The 9 faders, the old `#a4faders`: Fader 1 to 8 and the master fader.
  Widget _faders(Apc40Edits e) => LayoutBuilder(
    builder: (context, box) {
      final cols = ((box.maxWidth + 8) / (170 + 8)).floor().clamp(1, 99);
      final w = (box.maxWidth - 8 * (cols - 1)) / cols;
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var f = 1; f <= 9; f++)
              Container(
                width: w,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Sx.panel,
                  border: Border.all(color: Sx.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f == 9 ? 'Master fader' : 'Fader $f',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Sx.text),
                    ),
                    const SizedBox(height: 4),
                    _Select<int>(
                      value: e.info.faders.any((x) => x.k == e.layout.faders[f]) ? e.layout.faders[f]! : -1,
                      items: {-1: 'nothing', for (final x in e.info.faders) x.k: '${x.caption.isEmpty ? 'Fader ${x.k + 1}' : x.caption} ${x.type}'},
                      onPick: (k) => _edit((e) => e.setFader(f, k < 0 ? null : k)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// One pad of the grid.
class _A4Pad extends StatelessWidget {
  const _A4Pad({required this.edits, required this.n, required this.drop});

  final Apc40Edits edits;
  final int n;

  /// A dragged pad is over this one.
  final bool drop;

  @override
  Widget build(BuildContext context) {
    final e = edits;
    final t = e.pg.pads[n];
    final sel = e.selected == n;
    final outline = sel
        ? BoxDecoration(
            border: Border.all(color: Sx.accent, width: 2),
            borderRadius: BorderRadius.circular(7),
          )
        : null;
    Widget body;
    if (t == null) {
      body = CustomPaint(
        painter: PadDashed(accent: drop),
        child: Container(
          foregroundDecoration: outline,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.fromLTRB(5, 5, 5, 4),
          child: Text('empty', style: TextStyle(fontSize: 10, color: Sx.line2)),
        ),
      );
    } else {
      final b = e.buttonOn(n);
      final idle = (b == null ? null : padColor(e.colour(n, false) ?? -1)) ?? padNoIdle;
      final on = (b == null ? null : padColor(e.colour(n, true) ?? -1)) ?? padNoOn;
      // The old page's text-shadow without its 2 px blur. Blurring the shadow under every
      // pad's two labels made each frame of this tab take six times as long to draw.
      const shadow = [Shadow(color: apcBody, offset: Offset(0, 1))];
      body = Container(
        foregroundDecoration: outline,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [.35, 1],
            colors: [idle, Color.lerp(idle, apcBody, .6)!],
          ),
          border: Border.all(color: Sx.line),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Stack(
          children: [
            PadStrip(on, border: 1),
            Positioned(
              left: 5,
              right: 5,
              bottom: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, height: 1.15, fontWeight: FontWeight.w600, color: b != null ? padText : Sx.redText, shadows: shadow),
                  ),
                  Text(
                    b?.pageName ?? 'not in ShowXpress!',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 8.5, color: padSubText, shadows: shadow),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      if (drop) body = CustomPaint(foregroundPainter: const PadDashed(accent: true), child: body);
    }
    return Semantics(button: true, selected: sel, label: '${a4Place(n)}: ${t ?? 'empty'}', child: body);
  }
}

/// One page's tab, the old `.a4pages .mini`. The page on show is in the
/// accent colour.
class _PageTab extends StatelessWidget {
  const _PageTab(this.text, {required this.on, required this.drop, required this.onTap});

  final String text;
  final bool on;
  final bool drop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontFamily: Sx.body, fontSize: 12, fontWeight: FontWeight.w600),
        backgroundColor: Sx.hover,
        foregroundColor: on ? Sx.accent : Sx.text,
        side: BorderSide(color: on ? Sx.accent : Sx.line),
      ),
      child: Text(text),
    );
    return drop ? CustomPaint(foregroundPainter: const PadDashed(accent: true), child: button) : button;
  }
}

/// A button in the picked pad's list, the old `.a4b`.
class _ButtonRow extends StatelessWidget {
  const _ButtonRow(this.b, {required this.current, required this.onTap});

  final Apc40Button b;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    hoverColor: Sx.hover,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          PadSwatch(padColor(b.on)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              b.title,
              style: TextStyle(fontSize: 12.5, color: current ? Sx.accent : Sx.text, fontWeight: current ? FontWeight.w700 : FontWeight.w400),
            ),
          ),
        ],
      ),
    ),
  );
}

/// "Saved" or "Not saved yet", the old `#a4state` pill.
class _SavedTag extends StatelessWidget {
  const _SavedTag(this.dirty);

  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final c = dirty ? Sx.blue : Sx.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: dirty ? .45 : .35)),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(dirty ? Icons.circle : Icons.check, size: dirty ? 8 : 14, color: c),
          const SizedBox(width: 5),
          Text(
            dirty ? 'Not saved yet' : 'Saved',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

/// A drop-down, the old page's `select`. [value] null shows [hint].
class _Select<T> extends StatelessWidget {
  const _Select({required this.value, required this.items, required this.onPick, this.hint = ''});

  final T? value;
  final Map<T, String> items;
  final ValueChanged<T> onPick;
  final String hint;

  @override
  Widget build(BuildContext context) =>
      SxMenu<T>(items: items, value: value, onPick: onPick, hint: hint, hintColor: Sx.text, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6));
}
