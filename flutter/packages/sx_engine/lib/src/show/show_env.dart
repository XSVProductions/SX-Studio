import 'dart:io';

import 'package:path/path.dart' as p;

/// A tool refused or failed. [message] is the one line the user sees, and it
/// matches the old tool's message word for word.
class ToolError implements Exception {
  ToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The show folder a tool works on, plus the two things tools ask the outside
/// world: is ShowXpress open, and what time is it.
///
/// Tests pass a copy of a show and leave the defaults (ShowXpress closed).
class ShowEnv {
  ShowEnv(this.root, {bool Function()? sxRunning, DateTime Function()? now}) : sxRunning = sxRunning ?? (() => false), now = now ?? DateTime.now;

  /// The show folder, as the user gave it. Tools echo this in their answers.
  final String root;

  final bool Function() sxRunning;
  final DateTime Function() now;

  /// A file or folder inside the show.
  String path(String relative) => p.join(root, relative);

  File file(String relative) => File(path(relative));

  /// ShowXpress rewrites the show's files when it closes, so tools that write
  /// refuse while it is open.
  void requireSxClosed() {
    if (sxRunning()) {
      throw ToolError('ShowXpress is OPEN - NOTHING was changed. Close ShowXpress (save first) and try again.');
    }
  }
}
