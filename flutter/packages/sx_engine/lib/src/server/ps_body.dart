import '../ps_compat.dart';

export '../ps_compat.dart' show psTruthy;

// How the old server (`df_aim_gui.ps1`) read a request body. It decoded the
// JSON with `ConvertFrom-Json` and checked the raw values with PowerShell's
// own habits, before any tool saw them. The routes use these to refuse
// exactly what the old server refused.

/// `"$($body.x)"` of a value decoded from a request.
///
/// Null is '', booleans are `True`/`False`, a list is its items joined by
/// spaces. A fraction prints as written on Windows PowerShell 5.1, where
/// `ConvertFrom-Json` reads it as a `Decimal` (`5.0` stays `5.0`), and in
/// the shortest form on PowerShell 7 (`5.0` is `5`). Follows [psFlavor].
String bodyText(Object? v) => switch (v) {
  null => '',
  bool b => b ? 'True' : 'False',
  int i => '$i',
  double d => psFlavor == PsFlavor.winPs51 ? '$d' : psDoubleText(d),
  List l => l.map(bodyText).join(' '),
  Map m => '@{${m.entries.map((e) => '${e.key}=${bodyText(e.value)}').join('; ')}}',
  _ => '$v',
};

/// `@($body.x)` of a value decoded from a request: a list stays a list, a
/// single value becomes a list of one. Null is the empty list here; every
/// caller drops nulls anyway (`if ($c)`, `Where-Object { $null -ne $_ }`).
List<Object?> bodyItems(Object? v) => switch (v) {
  null => const [],
  List l => l,
  _ => [v],
};

/// `@($body.x | ForEach-Object { "$_" })`: each item as text. Piping a null
/// runs the block once, so a missing value gives `['']`.
List<String> bodyTexts(Object? v) => v == null ? const [''] : [for (final e in bodyItems(v)) bodyText(e)];

/// A field of a list item, as `$c.x` reads it: null when the item is not an
/// object.
Object? field(Object? item, String key) => item is Map ? item[key] : null;
