/// Shared bits for the rig, flip, skip flash and rig test parity cases.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// The real show's movers, read once. Empty when there is no show here.
final List<Mover> realMovers = realShowPath == null ? const [] : showMovers(ShowEnv(realShowPath!));

List<String> ids(Iterable<Mover> ms) => [for (final m in ms) m.id];

Object? _sortKeys(Object? v) => switch (v) {
  Map m => {for (final k in (m.keys.map((k) => '$k').toList()..sort())) k: _sortKeys(m[k])},
  List l => [for (final e in l) _sortKeys(e)],
  _ => v,
};

/// Rewrites a JSON state file so key order doesn't count. The old tools write
/// some state from plain `@{}` hashtables, whose order changes from run to run.
/// [sortLists] also sorts the lists under these keys, and [mask] blanks the
/// values of these keys (timestamps).
List<int> canonicalJson(List<int> bytes, {Set<String> sortLists = const {}, Set<String> mask = const {}}) {
  Object? walk(Object? v) => switch (v) {
    Map m => {
      for (final MapEntry(:key, :value) in m.entries)
        '$key': mask.contains(key)
            ? '<masked>'
            : sortLists.contains(key) && value is List
            ? ([for (final e in value) '$e']..sort())
            : walk(value),
    },
    List l => [for (final e in l) walk(e)],
    _ => v,
  };
  return utf8.encode(psJson(_sortKeys(walk(jsonDecode(utf8.decode(bytes))))));
}

/// The one allowed difference where an old tool deleted its state file: the
/// port writes an empty state instead. Checks that, then removes the file so
/// the rest of the folder can be compared with the old tool's.
void takeEmptyState(ShowEnv env, String name) {
  final f = env.file(name);
  expect(f.existsSync(), isTrue, reason: '$name should be kept as an empty state');
  expect(f.readAsStringSync(), rigEmptyState);
  f.deleteSync();
}

/// Replaces text in a show file, for building a situation in `setup:`.
void editFile(ShowEnv env, String rel, String Function(String) edit) {
  final f = env.file(rel);
  f.writeAsBytesSync(utf8.encode(edit(utf8.decode(f.readAsBytesSync()))));
}

void deleteFile(ShowEnv env, String rel) {
  final f = env.file(rel);
  if (f.existsSync()) f.deleteSync();
}

/// Makes the next write of [rel] fail: a folder where its temp file would go.
void blockWrite(ShowEnv env, String rel) => Directory('${env.path(rel)}.sxtmp').createSync();

/// [env] with a clock that always says the same time, for `setup:` steps that
/// write a timestamp (both sides then start from the same bytes).
ShowEnv fixedClock(ShowEnv env) => ShowEnv(env.root, now: () => DateTime(2026, 11, 20, 18, 30));

/// Every file in the show, path to bytes.
Map<String, List<int>> snapshot(ShowEnv env) => {for (final f in Directory(env.root).listSync(recursive: true).whereType<File>()) f.path: f.readAsBytesSync()};

/// A fresh copy of the real show in a temp folder, removed after the test.
ShowEnv copyOfShow() {
  final tmp = Directory.systemTemp.createTempSync('sx_rig_unit_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final from = Directory(realShowPath!), to = p.join(tmp.path, 'show');
  for (final e in from.listSync(recursive: true).whereType<File>()) {
    final target = File(p.join(to, p.relative(e.path, from: from.path)));
    target.parent.createSync(recursive: true);
    e.copySync(target.path);
  }
  return ShowEnv(to);
}
