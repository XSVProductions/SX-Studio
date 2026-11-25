import 'dart:async';

import 'package:sx_api/sx_api.dart';

import 'api.dart';
import 'engine.dart' show runRoute;

class _Item {
  _Item(this.key, this.label, this.route, this.body);

  final String key;
  final String label;
  final ApiRoute route;
  final Json body;
}

/// Saves waiting for ShowXpress to close.
///
/// While ShowXpress is open, a save in any tab is queued. Once ShowXpress has
/// been closed for a few seconds (it rewrites live.ini as it closes) the queue
/// runs in order, Google Drive import first and sync last, and ShowXpress is
/// opened again. A later save of the same thing replaces the earlier one.
///
/// Port of the QUEUE block in `df_aim_gui.ps1`.
class SaveQueue {
  SaveQueue({required this.sxOpen, required this.busy, required this.reopenSx});

  final bool Function() sxOpen;

  /// True while live aim or the player holds the DMX interface. The queue
  /// waits for it.
  final bool Function() busy;
  final Future<ToolResult> Function() reopenSx;

  final _items = <_Item>[];
  var _closedTicks = 0;
  var _running = false;

  /// Whether to open ShowXpress again after the queue ran.
  bool reopen = true;

  /// What the last run did, until the UI has seen it.
  Json? done;

  bool get isEmpty => _items.isEmpty;

  /// Queues a save and returns the answer the UI gets instead of the tool's.
  Json add(ApiRoute route, Json body) {
    final q = route.queue!;
    final key = q.key?.call(body) ?? route.path;
    final detail = q.detail?.call(body) ?? '';
    final label = detail.isEmpty ? q.label : '${q.label} $detail';
    final before = _items.length;
    _items.removeWhere((i) => i.key == key);
    final replaced = _items.length != before;
    _items.add(_Item(key, label, route, body));
    return {'ok': true, 'queued': true, 'replaced': replaced, 'label': label, 'out': '', 'error': ''};
  }

  /// Drops one queued save, or all of them when [key] is null.
  void cancel([String? key]) => key == null ? _items.clear() : _items.removeWhere((i) => i.key == key);

  Json info() => {
    'items': [
      for (final i in _items) {'key': i.key, 'label': i.label},
    ],
    'reopen': reopen,
    'done': done,
  };

  /// Called about once a second.
  Future<void> step() async {
    if (_running) return;
    if (_items.isEmpty || sxOpen() || busy()) {
      _closedTicks = 0;
      return;
    }
    // give ShowXpress time to finish writing the show
    if (++_closedTicks < 4) return;
    await run(reopen: reopen);
  }

  /// Runs everything queued now.
  Future<void> run({required bool reopen}) async {
    if (_running) return;
    _running = true;
    try {
      bool isPath(_Item i, String path) => i.route.path == path;
      final items = [
        ..._items.where((i) => isPath(i, '/api/gdrive/import')),
        ..._items.where((i) => !isPath(i, '/api/gdrive/import') && !isPath(i, '/api/gdrive/sync')),
        ..._items.where((i) => isPath(i, '/api/gdrive/sync')),
      ];
      _items.clear();
      _closedTicks = 0;
      final results = <Json>[];
      for (final it in items) {
        final r = await runRoute(it.route, ApiRequest(body: it.body, query: const {}, fromPhone: false));
        results.add({'label': it.label, 'ok': r['ok'] != false, 'error': '${r['error'] ?? ''}', 'out': '${r['out'] ?? ''}'});
      }
      ToolResult? reopened;
      if (reopen) reopened = await reopenSx();
      done = {
        'at': DateTime.now().toIso8601String().substring(0, 19),
        'results': results,
        'reopened': reopened?.ok ?? false,
        'reopenError': reopened == null || reopened.ok ? '' : reopened.error,
      };
    } finally {
      _running = false;
    }
  }
}
