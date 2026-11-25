// The Scene Editor's second, independent way of reading and changing a scene:
// through an XML parser. A save is written only when this way and the text
// way (scene_text.dart) agree.
//
// The old tool used .NET's XmlDocument, which refuses anything that is not
// well-formed XML. Dart's `xml` package is more forgiving (it keeps unknown
// entities, raw `&`, duplicate attributes), so [xmlWellFormed] first applies
// the checks .NET would.
//
// Port of `SxsScene.XmlModel`, `Get-ChangedXml` and `Get-CanonXml` in `scene_edit.ps1`.

import 'package:sx_api/sx_api.dart';
import 'package:xml/xml.dart';

import '../../ps_compat.dart';
import 'scene_text.dart';

final _ref = RegExp(r'&(?:#[0-9]+|#x[0-9a-fA-F]+|lt|gt|amp|quot|apos);');
final _amp = RegExp('&');
final _badChar = RegExp(r'[^\t\n\r -퟿-�\u{10000}-\u{10FFFF}]', unicode: true);
final _nameRx = RegExp(r'^[\p{L}_:][\p{L}\p{Nd}\p{Mn}\p{Mc}\p{Pc}._:\-·]*$', unicode: true);
final _tag = RegExp(
  r'<!--([\s\S]*?)-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?([\s\S]*?)\?>|<!DOCTYPE[^>]*>'
  r'|<(/?)([A-Za-z_][^\s/>]*)((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'
  "'[^']*'"
  r'))*)\s*(/?)>|<',
);
final _attr = RegExp(
  r'\s+([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'
  "'([^']*)')",
);

bool _xmlSpace(String s) => s.codeUnits.every((c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D);

/// Every `&` starts `&lt;`, `&#65;` and the like, and character references
/// name characters XML allows.
bool _refsOk(String s) {
  for (final a in _amp.allMatches(s)) {
    final m = _ref.matchAsPrefix(s, a.start);
    if (m == null) return false;
    final body = m[0]!;
    if (body.startsWith('&#')) {
      final hex = body[2] == 'x';
      final v = int.tryParse(body.substring(hex ? 3 : 2, body.length - 1), radix: hex ? 16 : 10);
      if (v == null || v > 0x10FFFF || _badChar.hasMatch(String.fromCharCode(v))) return false;
    }
  }
  return true;
}

/// False when .NET's XmlDocument would refuse [t]: characters XML doesn't
/// allow, a bare `&`, an entity XML doesn't define, `<` in an attribute, the
/// same attribute twice, tags that don't match, text outside the root, an
/// undeclared namespace prefix.
bool xmlWellFormed(String t) {
  if (_badChar.hasMatch(t)) return false;
  final open = <(String, Set<String>)>[]; // element name, prefixes it declares
  var roots = 0, pos = 0, sawDoctype = false;
  bool declared(String prefix) => prefix == 'xml' || prefix == 'xmlns' || open.any((e) => e.$2.contains(prefix));
  for (final m in _tag.allMatches(t)) {
    final gap = t.substring(pos, m.start);
    pos = m.end;
    if (open.isEmpty ? !_xmlSpace(gap) : (!_refsOk(gap) || gap.contains(']]>'))) return false;
    final whole = m[0]!;
    if (whole == '<') return false;
    if (whole.startsWith('<!--')) {
      final body = m[1]!;
      if (body.contains('--') || body.endsWith('-')) return false;
      continue;
    }
    if (whole.startsWith('<![CDATA[')) {
      if (open.isEmpty) return false;
      continue;
    }
    if (whole.startsWith('<?')) {
      final target = RegExp(r'^[^\s?]*').stringMatch(m[2]!)!;
      if (target.toLowerCase() == 'xml' && m.start != 0) return false;
      if (target.isEmpty) return false;
      continue;
    }
    if (whole.startsWith('<!DOCTYPE')) {
      if (sawDoctype || roots > 0) return false;
      sawDoctype = true;
      continue;
    }
    final name = m[4]!;
    if (!_nameRx.hasMatch(name) || ':'.allMatches(name).length > 1) return false;
    if (m[3] == '/') {
      if (open.isEmpty || open.last.$1 != name || m[5]!.isNotEmpty) return false;
      open.removeLast();
      continue;
    }
    if (open.isEmpty && ++roots > 1) return false;
    final names = <String>{}, prefixes = <String>{}, used = <String>[];
    for (final a in _attr.allMatches(m[5]!)) {
      final an = a[1]!, v = a[2] ?? a[3]!;
      if (!_nameRx.hasMatch(an) || ':'.allMatches(an).length > 1 || !names.add(an)) return false;
      if (v.contains('<') || !_refsOk(v)) return false;
      if (an.startsWith('xmlns:')) {
        if (v.isEmpty) return false;
        prefixes.add(an.substring(6));
      } else if (an.contains(':')) {
        used.add(an.split(':').first);
      }
    }
    open.add((name, prefixes));
    if (name.contains(':')) used.add(name.split(':').first);
    if (!used.every(declared)) return false;
    if (m[6] == '/') open.removeLast();
  }
  if (open.isNotEmpty || roots != 1) return false;
  return _xmlSpace(t.substring(pos));
}

/// Parses [t] the way XmlDocument.LoadXml would, or returns null when it would refuse.
XmlDocument? parseXml(String t) {
  if (!xmlWellFormed(t)) return null;
  try {
    return XmlDocument.parse(t);
  } on XmlException {
    return null;
  }
}

Iterable<XmlElement> _kids(XmlNode n, String name) => n.children.whereType<XmlElement>().where((e) => e.name.qualified == name);

String _attrOf(XmlElement e, String name) => e.getAttribute(name) ?? '';

int _ixOf(XmlElement c) => SxsScene.num(_attrOf(c, 'index'), 999);

List<XmlElement> _stepNodes(XmlDocument x) => [for (final s in _kids(x, 'Scene').expand((r) => _kids(r, 'Steps'))) ..._kids(s, 'Step')];

/// The steps as one string, read by the XML parser. Throws [FormatException]
/// when [t] is not valid XML. Port of `SxsScene.XmlModel`.
String xmlModel(String t) {
  final x = parseXml(t);
  if (x == null) throw const FormatException('not valid XML');
  final b = StringBuffer();
  var first = true;
  for (final s in _stepNodes(x)) {
    if (!first) b.write('\n');
    first = false;
    b
      ..write(_attrOf(s, 'length'))
      ..write('|');
    var f1 = true;
    for (final f in _kids(s, 'Fixture')) {
      if (!f1) b.write(';');
      f1 = false;
      b
        ..write(_attrOf(f, 'id'))
        ..write(':');
      var c1 = true;
      for (final c in _kids(f, 'Channel')) {
        if (!c1) b.write(',');
        c1 = false;
        b
          ..write(_ixOf(c))
          ..write('=')
          ..write(_attrOf(c, 'value'))
          ..write(_attrOf(c, 'fade') == '1' ? 'f' : '');
      }
    }
  }
  return b.toString();
}

String _escText(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
String _escAttr(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;').replaceAll('\t', '&#9;').replaceAll('\n', '&#10;').replaceAll('\r', '&#13;');

/// One fixed way to write a parsed scene, whitespace between tags left out
/// (XmlDocument's default), so two documents can be compared as text.
String _canon(XmlNode n) {
  final b = StringBuffer();
  void w(XmlNode n) {
    switch (n) {
      case XmlElement():
        b
          ..write('<')
          ..write(n.name.qualified);
        for (final a in n.attributes) {
          b.write(' ${a.name.qualified}="${_escAttr(a.value)}"');
        }
        final kids = n.children.where((c) => !(c is XmlText && _xmlSpace(c.value))).toList();
        if (kids.isEmpty && n.isSelfClosing) {
          b.write('/>');
        } else {
          b.write('>');
          kids.forEach(w);
          b.write('</${n.name.qualified}>');
        }
      case XmlText():
        if (!_xmlSpace(n.value)) b.write(_escText(n.value.replaceAll('\r\n', '\n')));
      case XmlDocument():
        n.children.forEach(w);
      default:
        b.write(n.toXmlString());
    }
  }

  w(n);
  return b.toString();
}

/// [t] written the one fixed way, or null when it is not valid XML.
/// Port of `Get-CanonXml`.
String? canonXml(String t) {
  final x = parseXml(t);
  return x == null ? null : _canon(x);
}

/// The same changes as the text way, made on the parsed scene, written the
/// one fixed way. Port of `Get-ChangedXml`.
String changedXml(
  String text,
  bool structural,
  List<SceneStepChange> steps,
  List<SceneChannelRef> addch,
  List<SceneChannelRef> delch,
  Map<String, String> names,
) {
  final x = parseXml(text)!;
  final stepsNode = _kids(x, 'Scene').expand((r) => _kids(r, 'Steps')).first;
  final old = _kids(stepsNode, 'Step').toList();
  for (final dc in delch) {
    for (final s in old) {
      for (final f in _kids(s, 'Fixture').where((f) => psEq(_attrOf(f, 'id'), dc.fx))) {
        for (final c in _kids(f, 'Channel').where((c) => _ixOf(c) >= 0 && _ixOf(c) == dc.ix).toList()) {
          c.remove();
        }
      }
    }
  }
  for (final ac in addch) {
    for (final s in old) {
      for (final f in _kids(s, 'Fixture').where((f) => psEq(_attrOf(f, 'id'), ac.fx))) {
        final cs = _kids(f, 'Channel').toList();
        if (cs.any((c) => _ixOf(c) == ac.ix)) continue;
        final n = XmlElement(XmlName('Channel'), [
          XmlAttribute(XmlName('index'), '${ac.ix}'),
          XmlAttribute(XmlName('name'), names['${ac.fx}|${ac.ix}'] ?? ''),
          XmlAttribute(XmlName('value'), '0'),
        ]);
        final after = cs.where((c) => _ixOf(c) < ac.ix).lastOrNull;
        if (after != null) {
          f.children.insert(f.children.indexOf(after) + 1, n);
        } else if (cs.isNotEmpty) {
          f.children.insert(f.children.indexOf(cs.first), n);
        } else {
          f.children.add(n);
        }
      }
    }
  }
  final fresh = [
    for (final ns in steps)
      () {
        final s = old[ns.src].copy();
        if (ns.len != null) s.setAttribute('length', '${ns.len}');
        for (final st in ns.set) {
          for (final f in _kids(s, 'Fixture').where((f) => psEq(_attrOf(f, 'id'), st.fx))) {
            for (final c in _kids(f, 'Channel').where((c) => _ixOf(c) >= 0 && _ixOf(c) == st.ix)) {
              if (st.v != null) c.setAttribute('value', '${st.v}');
              if (st.fade == true) {
                c.setAttribute('fade', '1');
              } else if (st.fade == false) {
                c.removeAttribute('fade');
              }
            }
          }
        }
        return s;
      }(),
  ];
  if (structural) {
    for (final s in old) {
      s.remove();
    }
    stepsNode.children.addAll(fresh);
  } else {
    for (var i = 0; i < old.length; i++) {
      old[i].replace(fresh[i]);
    }
  }
  return _canon(x);
}
