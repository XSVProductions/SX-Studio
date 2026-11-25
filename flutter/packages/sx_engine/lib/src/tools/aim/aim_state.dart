import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../../ps_compat.dart';
import '../../show/text_files.dart';
import 'aim_math.dart';

/// What Apply last did to one movement's shape.
class ShapeRecord {
  const ShapeRecord({required this.base, required this.written, required this.sx, required this.sy});

  /// The original (un-resized) shape, `"x,y;x,y"`.
  final String base;

  /// The shape as last written to the file. When the file still holds this,
  /// [base] is the shape to resize; otherwise it was changed in Generator.
  final String written;
  final double sx;
  final double sy;
}

/// A head that got its T-bar partner's aim: the aims it got and from whom.
class CopiedAim {
  const CopiedAim({required this.c, required this.k, required this.from});

  final PanTilt? c;
  final PanTilt? k;
  final String from;
}

/// `df_aim_state.json` / `room_aim_state.json`: the overall size last
/// applied, the original shapes (so resizing never stacks), and the partner
/// copies. Port of `Load-State` and `Save-State`.
class AimState {
  AimState._(this.path, this.sx, this.sy, this._files, this.copied);

  factory AimState.load(String path) {
    final files = <String, (String, ShapeRecord)>{};
    final copied = <String, CopiedAim>{};
    if (!File(path).existsSync()) return AimState._(path, 1.0, 1.0, files, copied);
    final j = jsonDecode(readText(path));
    final root = j is Map ? j.cast<String, Object?>() : const <String, Object?>{};
    PanTilt? xy(Object? v) {
      final m = RegExp(r'^(-?\d+),(-?\d+)$').firstMatch(v == null ? '' : '$v');
      return m == null ? null : (int.parse(m[1]!), int.parse(m[2]!));
    }

    if (_truthy(root['copied']) && root['copied'] is Map) {
      (root['copied'] as Map).forEach((id, v) {
        final r = v is Map ? v : const {};
        copied['$id'] = CopiedAim(c: xy(r['c']), k: xy(r['k']), from: r['from'] == null ? '' : '${r['from']}');
      });
    }
    if (root['files'] is Map) {
      (root['files'] as Map).forEach((name, v) {
        final r = v is Map ? v : const {};
        String s(Object? x) => x == null ? '' : '$x';
        files['$name'.toLowerCase()] = ('$name', ShapeRecord(base: s(r['base']), written: s(r['written']), sx: psDouble(r['sx']), sy: psDouble(r['sy'])));
      });
    }
    return AimState._(path, psDouble(root['sx']), psDouble(root['sy']), files, copied);
  }

  final String path;
  double sx;
  double sy;

  /// By lowercase file name: (the name as first written, the record).
  final Map<String, (String, ShapeRecord)> _files;

  /// By head id.
  Map<String, CopiedAim> copied;

  /// The record for a movement, ignoring case like the old hashtable.
  ShapeRecord? shape(String file) => _files[file.toLowerCase()]?.$2;

  /// Sets a movement's record. A name already there keeps its spelling.
  void setShape(String file, ShapeRecord r) => _files[file.toLowerCase()] = (_files[file.toLowerCase()]?.$1 ?? file, r);

  /// The file text as PowerShell 7's `ConvertTo-Json -Depth 5` writes it:
  /// two-space indent, doubles with a decimal point, names sorted.
  ///
  /// The old tool turned each record from an unordered hashtable, so its key
  /// order changes from run to run. This always writes base, written, sx, sy.
  String toText() {
    final files = psSorted<(String, ShapeRecord)>(_files.values, [(e) => e.$1]);
    final ids = psSorted<String>(copied.keys, [(k) => k]);
    final o = {
      'sx': sx,
      'sy': sy,
      'files': {
        for (final (name, r) in files) name: {'base': r.base, 'written': r.written, 'sx': r.sx, 'sy': r.sy},
      },
      'copied': {
        for (final id in ids)
          id: {
            'c': copied[id]!.c == null ? '' : '${copied[id]!.c!.$1},${copied[id]!.c!.$2}',
            'k': copied[id]!.k == null ? '' : '${copied[id]!.k!.$1},${copied[id]!.k!.$2}',
            'from': copied[id]!.from,
          },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(o);
  }
}

bool _truthy(Object? v) => switch (v) {
  null => false,
  bool b => b,
  num n => n != 0,
  String s => s.isNotEmpty,
  _ => true,
};
