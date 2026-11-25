// The Scene Editor's reader: one pass over a scene's text that records where
// every step, head, channel and attribute is, so a save can change just those
// characters and leave the rest of the file as it was.
//
// Port of the C# class `SxsScene` in `scene_edit.ps1`.

/// .NET regex `\s`: `[\f\n\r\t\v\x85\p{Z}]`. Dart's `\s` differs in two characters.
const _ws = r'[\f\n\r\t\v\x85\p{Z}]';

/// .NET regex `\w`: letters, marks, digits and connectors in any script.
const _word = r'[\p{L}\p{Mn}\p{Nd}\p{Pc}]';

final _tok = RegExp(
  r'<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>'
  '|<(/?)([A-Za-z_](?:$_word|[.:\\-])*)((?:$_ws+[^\\f\\n\\r\\t\\v\\x85\\p{Z}=/>]+$_ws*=$_ws*(?:"[^"]*"|\'[^\']*\'))*)$_ws*(/?)>|<',
  unicode: true,
);
final _att = RegExp('$_ws+([^\\f\\n\\r\\t\\v\\x85\\p{Z}=/>]+)$_ws*=$_ws*(?:"([^"]*)"|\'([^\']*)\')', unicode: true);

/// C# `Char.IsWhiteSpace`, which `String.Trim` uses.
bool isNetSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// True when [s] is empty after C#'s `Trim()`.
bool netBlank(String s) => s.codeUnits.every(isNetSpace);

/// `WebUtility.HtmlDecode` for the references XML allows: the five named
/// ones and numeric ones. Anything else is left as written, as .NET does
/// with names it doesn't know. (A file that uses an HTML-only name is not
/// valid XML, so the editor never changes it.)
String htmlDecode(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);'), (m) {
    final body = m[1]!;
    if (body.startsWith('#')) {
      final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final v = int.tryParse(hex ? body.substring(2) : body.substring(1), radix: hex ? 16 : 10);
      if (v == null || v > 0x10FFFF) return m[0]!;
      return String.fromCharCode(v);
    }
    return switch (body) {
          'amp' => '&',
          'lt' => '<',
          'gt' => '>',
          'quot' => '"',
          'apos' => "'",
          _ => null,
        } ??
        m[0]!;
  });
}

/// `SecurityElement.Escape`: the five XML characters as entities.
String xmlEscape(String s) =>
    s.replaceAllMapped(RegExp('[<>"\'&]'), (m) => const {'<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;', '&': '&amp;'}[m[0]]!);

/// An attribute: its decoded value [v], the value as written [raw], where the
/// value sits ([vs]..[ve]) and where the whole ` name="value"` sits ([as_]..[ae]).
class SxsAttr {
  SxsAttr(this.v, this.raw, this.vs, this.ve, this.as_, this.ae);

  final String v, raw;
  final int vs, ve, as_, ae;
}

/// A `<Channel .../>` in a step.
class SxsCh {
  /// 0..999, or -1 when the index is not a plain number.
  int ix = -1;

  /// 0..255, or -1 when the value is not a plain number.
  int v = -1;
  int start = 0, end = 0;

  /// Where a new attribute goes: right after the last one.
  int insAt = 0;
  String name = '';
  SxsAttr? val, fadeA;
  bool fade = false, self = false;
}

/// A `<Fixture id=...>` in a step.
class SxsFx {
  String id = '';
  int start = 0, closeAt = -1;
  bool self = false;
  final ch = <SxsCh>[];
}

/// A `<Step>`. [from] is where the text before it starts (the end of the
/// step before, or of `<Steps>`), so a step's text carries its own leading
/// spacing when it is copied or moved.
class SxsStep {
  int n = 0, from = 0, start = 0, end = -1, insAt = 0;
  SxsAttr? len;
  final fx = <SxsFx>[];
}

/// A head in the scene's `<Fixtures>` list.
class SxsHead {
  String id = '', name = '', model = '';
}

/// A scene's text, read. [ok] false means the editor leaves it alone, and
/// [why] says why.
class SxsScene {
  bool ok = false;

  /// False when something other than whitespace sits between steps. Then
  /// steps can be changed but not added, moved or taken out.
  bool structural = true;
  String why = '';

  /// The file's line ending.
  String nl = '\n';

  /// End of `<Steps>` and start of `</Steps>`.
  int open = -1, close = -1;
  final steps = <SxsStep>[];
  final heads = <SxsHead>[];

  /// Reads [t]. Port of `SxsScene.Read`.
  static SxsScene read(String t) {
    final r = SxsScene();
    if (t.contains('\r\n')) r.nl = '\r\n';
    final st = <String>[];
    SxsStep? step;
    SxsFx? fx;
    var roots = 0, lastEnd = -1;
    for (final m in _tok.allMatches(t)) {
      final name = m[2];
      if (name == null) {
        if (m[0] == '<') {
          r.why = 'it has a "<" the editor does not understand';
          return r;
        }
        if (st.length == 2 && st[1] == 'Steps') r.structural = false; // a comment between steps
        continue;
      }
      final end = m.end;
      if (m[1] == '/') {
        if (st.isEmpty || st.last != name) {
          r.why = "its <$name> tags don't match up";
          return r;
        }
        st.removeLast();
        final d = st.length;
        if (d == 2 && name == 'Step' && step != null) {
          step.end = end;
          lastEnd = end;
          step = null;
        } else if (d == 3 && name == 'Fixture' && fx != null) {
          fx.closeAt = m.start;
          fx = null;
        } else if (d == 1 && name == 'Steps' && r.open >= 0 && r.close < 0) {
          r.close = m.start;
        }
        continue;
      }
      final self = m[4] == '/';
      final d = st.length;
      // group 3 starts right after "<" and the name
      final g3 = m.start + 1 + m[1]!.length + name.length;
      final g3Text = m[3]!;
      final insAt = g3 + g3Text.length;
      Map<String, SxsAttr> attrs() {
        final out = <String, SxsAttr>{};
        for (final a in _att.allMatches(g3Text)) {
          final raw = a[2] ?? a[3]!;
          final vs = g3 + a.end - 1 - raw.length;
          out[a[1]!] = SxsAttr(htmlDecode(raw), raw, vs, vs + raw.length, g3 + a.start, g3 + a.end);
        }
        return out;
      }

      String av(Map<String, SxsAttr> at, String k) => at[k]?.v ?? '';
      if (d == 0) {
        roots++;
        if (name != 'Scene') {
          r.why = 'it is not a scene file';
          return r;
        }
      } else if (d == 1 && name == 'Steps') {
        if (r.open >= 0) {
          r.why = 'it has two lists of steps';
          return r;
        }
        if (self) {
          r.why = 'it has no steps';
          return r;
        }
        r.open = end;
        lastEnd = end;
      } else if (d == 2 && st[1] == 'Steps') {
        if (name != 'Step') {
          r.structural = false;
        } else {
          final s = SxsStep()
            ..n = r.steps.length
            ..from = lastEnd
            ..start = m.start
            ..insAt = insAt
            ..len = attrs()['length'];
          r.steps.add(s);
          step = s;
          if (self) {
            s.end = end;
            lastEnd = end;
            step = null;
          }
        }
      } else if (d == 2 && st[1] == 'Fixtures' && name == 'Fixture') {
        final at = attrs();
        r.heads.add(
          SxsHead()
            ..id = av(at, 'id')
            ..name = av(at, 'name')
            ..model = av(at, 'model'),
        );
      } else if (d == 3 && st[2] == 'Step' && name == 'Fixture' && step != null) {
        final f = SxsFx()
          ..id = av(attrs(), 'id')
          ..start = m.start
          ..self = self;
        step.fx.add(f);
        fx = self ? null : f;
      } else if (d == 4 && st[3] == 'Fixture' && st[2] == 'Step' && name == 'Channel' && fx != null) {
        final at = attrs();
        final c = SxsCh()
          ..ix = num(av(at, 'index'), 999)
          ..val = at['value']
          ..fadeA = at['fade'];
        if (c.val != null) c.v = num(c.val!.v, 255);
        c
          ..fade = c.fadeA != null && c.fadeA!.v == '1'
          ..name = av(at, 'name')
          ..start = m.start
          ..end = end
          ..insAt = insAt
          ..self = self;
        fx.ch.add(c);
      }
      if (!self) st.add(name);
    }
    if (st.isNotEmpty) {
      r.why = 'its <${st.last}> is never closed';
      return r;
    }
    if (roots != 1) {
      r.why = 'it is not a single scene';
      return r;
    }
    if (r.open < 0 || r.close < 0) {
      r.why = 'it has no list of steps';
      return r;
    }
    if (r.steps.isEmpty) {
      r.why = 'it has no steps';
      return r;
    }
    // only whitespace between the steps, or steps can't be added or moved (the in-between bits would move with them)
    for (final s in r.steps) {
      if (!netBlank(t.substring(s.from, s.start))) r.structural = false;
    }
    if (!netBlank(t.substring(lastEnd, r.close))) r.structural = false;
    r.ok = true;
    return r;
  }

  /// C#'s `Num`: 1 to 3 ASCII digits, at most [max]. -1 otherwise.
  static int num(String s, int max) {
    if (s.isEmpty || s.length > 3) return -1;
    for (final c in s.codeUnits) {
      if (c < 0x30 || c > 0x39) return -1;
    }
    final v = int.parse(s);
    return v <= max ? v : -1;
  }

  /// The steps as one string, to compare with what an XML parser reads.
  /// Port of `SxsScene.Model`.
  String model() {
    final b = StringBuffer();
    for (final s in steps) {
      if (b.isNotEmpty) b.write('\n');
      b
        ..write(s.len?.v ?? '')
        ..write('|');
      var f1 = true;
      for (final f in s.fx) {
        if (!f1) b.write(';');
        f1 = false;
        b
          ..write(f.id)
          ..write(':');
        var c1 = true;
        for (final c in f.ch) {
          if (!c1) b.write(',');
          c1 = false;
          b
            ..write(c.ix)
            ..write('=')
            ..write(c.val?.v ?? '')
            ..write(c.fade ? 'f' : '');
        }
      }
    }
    return b.toString();
  }

  /// Adds the channel names ShowXpress wrote in scene [t] to [into]
  /// (model to index to name), for heads of the models in [want]. A name
  /// already known is kept. Port of `SxsScene.Names`.
  static void names(String t, Set<String> want, Map<String, Map<int, String>> into) {
    final s = read(t);
    if (!s.ok) return;
    final mo = {for (final h in s.heads) h.id: h.model};
    for (final p in s.steps) {
      for (final f in p.fx) {
        final m = mo[f.id];
        if (m == null || !want.contains(m)) continue;
        final d = into.putIfAbsent(m, () => {});
        for (final c in f.ch) {
          if (c.ix >= 0 && c.name.isNotEmpty) d.putIfAbsent(c.ix, () => c.name);
        }
      }
    }
  }
}
