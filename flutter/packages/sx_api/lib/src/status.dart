import 'client.dart';
import 'json.dart';

/// One save waiting for ShowXpress to close.
class QueueItem {
  const QueueItem({required this.key, required this.label});

  factory QueueItem.fromJson(Json j) => QueueItem(key: j.str('key'), label: j.str('label'));

  final String key;
  final String label;

  Json toJson() => {'key': key, 'label': label};
}

/// The save queue as the UI shows it.
class QueueInfo {
  const QueueInfo({this.items = const [], this.reopen = true, this.done});

  factory QueueInfo.fromJson(Json j) => QueueInfo(items: j.list('items', QueueItem.fromJson), reopen: j.boolean('reopen'), done: j.objOrNull('done'));

  final List<QueueItem> items;

  /// Whether ShowXpress opens again after the queue ran.
  final bool reopen;

  /// What the last run did (`at`, `results`, `reopened`, `reopenError`), until
  /// the UI has shown it and called `queueSeen`.
  final Json? done;

  Json toJson() => {
    'items': [for (final i in items) i.toJson()],
    'reopen': reopen,
    'done': done,
  };
}

/// What the UI polls every couple of seconds: is ShowXpress open, what is
/// queued, and who holds the lights.
class SxStatus {
  const SxStatus({required this.open, this.queue = const QueueInfo(), this.live = false, this.play = false, this.pend = false, this.auto, this.rem});

  factory SxStatus.fromJson(Json j) => SxStatus(
    open: j.boolean('open'),
    queue: QueueInfo.fromJson(j.obj('q')),
    live: j.boolean('live'),
    play: j.boolean('play'),
    pend: j.boolean('pend'),
    auto: j.objOrNull('auto'),
    rem: j.objOrNull('rem'),
  );

  /// ShowXpress is open.
  final bool open;
  final QueueInfo queue;

  /// Live aim is sending DMX.
  final bool live;

  /// SX Player is sending DMX.
  final bool play;

  /// Button presses are waiting for ShowXpress to open.
  final bool pend;

  /// Auto Show status, when it is running.
  final Json? auto;

  /// Result of the last remote-control action.
  final Json? rem;

  Json toJson() => {'open': open, 'q': queue.toJson(), 'live': live, 'play': play, 'pend': pend, 'auto': auto, 'rem': rem};
}

extension StatusApi on SxClient {
  Future<SxStatus> status() => get('/api/sx', SxStatus.fromJson);

  Future<ToolResult> sxLaunch() => run('/api/sx/launch');

  /// [force] kills ShowXpress without saving. Laptop only.
  Future<ToolResult> sxClose({bool force = false}) => run('/api/sx/close', {'force': force});

  /// Drops one queued save, or all of them with key `*`.
  Future<ToolResult> queueCancel(String key) => run('/api/queue/cancel', {'key': key});

  Future<ToolResult> queueReopen(bool on) => run('/api/queue/reopen', {'on': on});

  /// Tells the engine the UI has shown the last queue run's results.
  Future<ToolResult> queueSeen() => run('/api/queue/seen');
}
