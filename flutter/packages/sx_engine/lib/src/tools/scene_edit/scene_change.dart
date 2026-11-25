// The Scene Editor's text way of making a change: edits on the file's own
// text, so everything the editor doesn't touch stays byte for byte.
//
// Port of `Get-Indent`, `Test-OwnLine`, `Get-NewChannelTag`,
// `Get-ChangedText` and `Test-Changes` in `scene_edit.ps1`.

import 'package:collection/collection.dart';
import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/show_env.dart';
import 'scene_text.dart';

/// The spacing before position [at] on its line, or null when something
/// other than spacing is there. Port of `Get-Indent`.
String? indentAt(String t, int at) {
  var ls = t.lastIndexOf('\n', at - 1 < 0 ? 0 : at - 1) + 1;
  if (at == 0) ls = 0;
  final w = t.substring(ls, at);
  return netBlank(w) ? w : null;
}

/// True when the channel's tag is alone on its line, so the whole line can
/// be taken out. Port of `Test-OwnLine`.
bool ownLine(String t, SxsCh c) {
  if (indentAt(t, c.start) == null) return false;
  final e = t.indexOf('\n', c.end);
  final rest = e < 0 ? t.substring(c.end) : t.substring(c.end, e);
  return netBlank(rest) && c.start > 0;
}

/// The tag a channel added by the editor gets. Port of `Get-NewChannelTag`.
String newChannelTag(int ix, String? name) => '<Channel index="$ix" name="${xmlEscape(name ?? '')}" value="0"/>';

/// One text edit: replace [len] characters at [at] with [text]. [ix] is the
/// channel a new channel tag adds, so tags added at one place keep channel order.
class _Edit {
  _Edit(this.at, this.len, this.text, [this.ix]);

  final int at, len;
  final int? ix;
  String text;
}

/// The scene's text with the changes made. Port of `Get-ChangedText`.
///
/// [names] maps `head id|index` to the name of each channel in [addch].
String changedText(String t, SxsScene sc, List<SceneStepChange> steps, List<SceneChannelRef> addch, List<SceneChannelRef> delch, Map<String, String> names) {
  final nl = sc.nl;
  final perStep = <int, List<_Edit>>{};
  void edit(SxsStep s, int at, int len, String text, [int? ix]) => perStep.putIfAbsent(s.n, () => []).add(_Edit(at, len, text, ix));
  // delch / addch hit every step the same way, done on the old steps (a copied step gets them too)
  for (final dc in delch) {
    for (final s in sc.steps) {
      for (final f in s.fx.where((f) => psEq(f.id, dc.fx))) {
        for (final c in f.ch.where((c) => c.ix == dc.ix)) {
          if (ownLine(t, c)) {
            var ls = t.lastIndexOf('\n', c.start - 1);
            if (ls > 0 && t[ls - 1] == '\r') ls--;
            edit(s, ls, c.end - ls, '');
          } else {
            edit(s, c.start, c.end - c.start, '');
          }
        }
      }
    }
  }
  for (final ac in addch) {
    final tag = newChannelTag(ac.ix, names['${ac.fx}|${ac.ix}']);
    for (final s in sc.steps) {
      for (final f in s.fx.where((f) => psEq(f.id, ac.fx))) {
        if (f.ch.any((c) => c.ix == ac.ix)) continue;
        final kept = [
          for (final c in f.ch)
            if (!delch.any((d) => psEq(d.fx, f.id) && d.ix == c.ix)) c,
        ];
        if (kept.isEmpty) throw ToolError("Head ${f.id} has no channels left in step ${s.n + 1}, so a channel can't be added there. NOTHING was changed.");
        final after = kept.where((c) => c.ix < ac.ix).lastOrNull;
        if (after != null) {
          final ind = indentAt(t, after.start);
          if (ind != null && ownLine(t, after)) {
            edit(s, after.end, 0, nl + ind + tag, ac.ix);
          } else {
            edit(s, after.end, 0, tag, ac.ix);
          }
        } else {
          final first = kept.first;
          final ind = indentAt(t, first.start);
          if (ind != null && ownLine(t, first)) {
            edit(s, first.start - ind.length, 0, ind + tag + nl, ac.ix);
          } else {
            edit(s, first.start, 0, tag, ac.ix);
          }
        }
      }
    }
  }
  // the new list of steps: each a copy of an old step's text (with its leading spacing), with its own edits
  final parts = StringBuffer(t.substring(0, sc.open));
  for (final ns in steps) {
    final s = sc.steps[ns.src];
    final ed = [for (final x in perStep[s.n] ?? const <_Edit>[]) _Edit(x.at, x.len, x.text, x.ix)]; // a copied step has its own
    if (ns.len != null) {
      final lv = '${ns.len}';
      final la = s.len;
      ed.add(la != null ? _Edit(la.vs, la.ve - la.vs, lv) : _Edit(s.insAt, 0, ' length="$lv"'));
    }
    for (final st in ns.set) {
      final f = s.fx.firstWhereOrNull((f) => psEq(f.id, st.fx));
      if (f == null) throw ToolError('Head ${st.fx} is not in step ${s.n + 1}. NOTHING was changed.');
      final c = f.ch.firstWhereOrNull((c) => c.ix == st.ix);
      if (c == null) {
        // a channel added just now: its new tag is in this step's edits, change it there
        final tagOld = newChannelTag(st.ix, names['${st.fx}|${st.ix}']);
        final hit = ed.lastWhereOrNull((x) => x.text.contains(tagOld));
        if (hit == null || !addch.any((a) => psEq(a.fx, st.fx) && a.ix == st.ix)) {
          throw ToolError('Channel ${st.ix} of head ${st.fx} is not in step ${s.n + 1}. NOTHING was changed.');
        }
        var nt = tagOld;
        if (st.v != null) nt = nt.replaceAll('value="0"', 'value="${st.v}"');
        if (st.fade == true) nt = nt.replaceAll('"/>', '" fade="1"/>');
        hit.text = hit.text.replaceAll(tagOld, nt);
        continue;
      }
      if (st.v != null) {
        final val = c.val;
        if (c.v < 0 || val == null) throw ToolError("Channel ${st.ix} of head ${st.fx} has a value the editor doesn't change. NOTHING was changed.");
        ed.add(_Edit(val.vs, val.ve - val.vs, '${st.v}'));
      }
      final fa = c.fadeA;
      if (st.fade == true && !c.fade) {
        ed.add(fa != null ? _Edit(fa.vs, fa.ve - fa.vs, '1') : _Edit(c.insAt, 0, ' fade="1"'));
      } else if (st.fade == false && fa != null) {
        ed.add(_Edit(fa.as_, fa.ae - fa.as_, ''));
      }
    }
    // from the back; at the same place a removal goes before an insert (so the insert isn't removed with it).
    // Channel tags added at one place go in highest channel first, so they read in channel order, as the
    // XML way puts them. The old tool left that to Sort-Object's handling of ties: right on Windows
    // PowerShell 5.1 for two tags in the order added, wrong on PowerShell 7 (the self-check refused).
    mergeSort(
      ed,
      compare: (a, b) {
        if (a.at != b.at) return b.at.compareTo(a.at);
        if (a.len != b.len) return b.len.compareTo(a.len);
        return a.ix != null && b.ix != null ? b.ix!.compareTo(a.ix!) : 0;
      },
    );
    var chunk = t.substring(s.from, s.end);
    for (final x in ed) {
      final at = x.at - s.from;
      chunk = chunk.substring(0, at) + x.text + chunk.substring(at + x.len);
    }
    parts.write(chunk);
  }
  parts.write(t.substring(sc.steps.last.end));
  return parts.toString();
}

final _headId = RegExp(r'^[\p{L}\p{Mn}\p{Nd}\p{Pc}\-]{1,40}$', unicode: true);

/// Refuses changes the editor can't make, before anything is done. Returns
/// the new list of steps. Port of `Test-Changes`.
List<SceneStepChange> checkChanges(SxsScene sc, SceneChanges ch) {
  final n = sc.steps.length;
  final steps = ch.steps;
  if (steps.isEmpty) throw ToolError('A scene needs at least one step. NOTHING was changed.');
  if (steps.length > 999) throw ToolError('Too many steps. NOTHING was changed.');
  for (final s in steps) {
    if (s.src < 0 || s.src >= n) throw ToolError('Unknown step. NOTHING was changed.');
    final len = s.len;
    if (len != null && (len < 1 || len > 999999)) throw ToolError('A step length has to be 1 or more (1/100 s). NOTHING was changed.');
    for (final x in s.set) {
      if (!_headId.hasMatch(x.fx) || x.ix < 0 || x.ix > 999) throw ToolError('Unknown channel. NOTHING was changed.');
      final v = x.v;
      if (v != null && (v < 0 || v > 255)) throw ToolError('A value has to be 0 to 255. NOTHING was changed.');
    }
  }
  var ident = steps.length == n;
  for (var i = 0; ident && i < n; i++) {
    if (steps[i].src != i) ident = false;
  }
  if (!ident && !sc.structural) {
    throw ToolError(
      "This scene has something between its steps that the editor doesn't know, so its steps can be changed but not added, taken out or moved. NOTHING was changed.",
    );
  }
  final heads = psMap<SxsHead>();
  for (final h in sc.heads) {
    heads[h.id] = h;
  }
  final seen = psMap<bool>();
  for (final x in [...ch.addch, ...ch.delch]) {
    if (!_headId.hasMatch(x.fx) || x.ix < 0 || x.ix > 999 || !heads.containsKey(x.fx)) throw ToolError('Unknown head or channel. NOTHING was changed.');
    final k = '${x.fx}|${x.ix}';
    if (seen.containsKey(k)) throw ToolError('A channel is both added and taken out. NOTHING was changed.');
    seen[k] = true;
  }
  final gone = psMap<bool>();
  for (final x in ch.delch) {
    gone['${x.fx}|${x.ix}'] = true;
  }
  for (final s in steps) {
    for (final x in s.set) {
      if (gone.containsKey('${x.fx}|${x.ix}')) throw ToolError("A channel that is taken out can't be changed too. NOTHING was changed.");
    }
  }
  return steps;
}
