import 'dart:io';

import '../../show/show_env.dart';
import '../../show/text_files.dart';

/// The show files one Aim Movers run writes, with what each held before.
///
/// The old tool wrote each file straight away and its state file last, with
/// no way back. A failure between the movements and the state file (a locked
/// file, a full disk) left resized shapes on disk and a state file that still
/// described the old ones, so the next Apply resized the already resized
/// shapes. Here every write goes through [writeTextSafely], and [run] puts
/// every earlier file back when a write fails.
class WriteJournal {
  final _before = <String, List<int>?>{};

  /// Replaces [path] with [text], remembering the old bytes the first time.
  void write(String path, String text, {required bool bom}) {
    _before.putIfAbsent(path, () {
      final f = File(path);
      return f.existsSync() ? f.readAsBytesSync() : null;
    });
    writeTextSafely(path, text, bom: bom);
  }

  /// Puts every file written so far back as it was, newest first.
  void rollback() {
    for (final e in _before.entries.toList().reversed) {
      try {
        final old = e.value;
        if (old == null) {
          final f = File(e.key);
          if (f.existsSync()) f.deleteSync();
        } else {
          writeBytesSafely(e.key, old);
        }
      } on FileSystemException {
        // keep putting the others back
      }
    }
    _before.clear();
  }

  /// Runs [body]. A refusal ([ToolError]) keeps what was written before it,
  /// as the old tool did (it creates the aim scene and check movements before
  /// it looks at the aims). Any other failure puts everything back.
  static T run<T>(T Function(WriteJournal j) body) {
    final j = WriteJournal();
    try {
      return body(j);
    } on ToolError {
      rethrow;
    } catch (_) {
      j.rollback();
      rethrow;
    }
  }
}
