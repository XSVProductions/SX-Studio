import 'client.dart';
import 'json.dart';

/// A button next to a pre-show item.
///
/// `sleep`, `usb` and `restart` go to `/api/pre/fix`. `launch` opens
/// ShowXpress and `tab:<id>` opens that tab; the screen does those itself.
class PreFix {
  const PreFix({required this.key, required this.label});

  factory PreFix.fromJson(Json j) => PreFix(key: j.str('key'), label: j.str('label'));

  final String key;
  final String label;

  Json toJson() => {'key': key, 'label': label};
}

/// One line of the Pre-show Check.
class PreItem {
  const PreItem({required this.group, required this.level, required this.title, this.detail = '', this.advice = '', this.fix});

  factory PreItem.fromJson(Json j) => PreItem(
    group: j.str('group'),
    level: j.str('level'),
    title: j.str('title'),
    detail: j.str('detail'),
    advice: j.str('advice'),
    fix: switch (j.objOrNull('fix')) {
      null => null,
      final f => PreFix.fromJson(f),
    },
  );

  /// `Show`, `Gear` or `Laptop`.
  final String group;

  /// `ok`, `warn`, `error` or `info`.
  final String level;
  final String title;
  final String detail;
  final String advice;

  /// Never set on an `ok` item.
  final PreFix? fix;

  Json toJson() => {'group': group, 'level': level, 'title': title, 'detail': detail, 'advice': advice, 'fix': fix?.toJson()};
}

/// What the Pre-show Check found.
class PreReport {
  const PreReport({required this.show, required this.items});

  factory PreReport.fromJson(Json j) => PreReport(show: j.str('show'), items: j.list('items', PreItem.fromJson));

  final String show;
  final List<PreItem> items;

  Json toJson() => {
    'ok': true,
    'show': show,
    'items': [for (final i in items) i.toJson()],
  };
}

extension PreshowApi on SxClient {
  Future<PreReport> preshow() => get('/api/pre', PreReport.fromJson);

  /// [key] is `sleep`, `usb` or `restart`. Restart is laptop only.
  Future<ToolResult> preshowFix(String key) => run('/api/pre/fix', {'key': key});
}
