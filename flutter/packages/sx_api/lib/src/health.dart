import 'client.dart';
import 'json.dart';

/// A fix the Health Check can apply for an issue.
class HealthFix {
  const HealthFix({required this.key, required this.label});

  factory HealthFix.fromJson(Json j) => HealthFix(key: j.str('key'), label: j.str('label'));

  /// What to send to `/api/health/fix`, for example `speed|page3_button1`.
  final String key;

  /// The button's words, for example "Use MOVEMENTS".
  final String label;

  Json toJson() => {'key': key, 'label': label};
}

/// One problem the Health Check found.
class HealthIssue {
  const HealthIssue({required this.level, required this.kind, required this.title, required this.detail, required this.advice, this.fix});

  factory HealthIssue.fromJson(Json j) => HealthIssue(
    level: j.str('level'),
    kind: j.str('kind'),
    title: j.str('title'),
    detail: j.str('detail'),
    advice: j.str('advice'),
    fix: switch (j.objOrNull('fix')) {
      null => null,
      final f => HealthFix.fromJson(f),
    },
  );

  /// `error`, `warn` or `info`.
  final String level;

  /// What sort of problem: scene, fixtures, beat, speed, midi, keys, layout,
  /// color, color251 or unused.
  final String kind;
  final String title;
  final String detail;

  /// The recommended fix in words. Can be empty.
  final String advice;

  /// Null when SX Studio can't fix it by itself.
  final HealthFix? fix;

  Json toJson() => {'level': level, 'kind': kind, 'title': title, 'detail': detail, 'advice': advice, 'fix': fix?.toJson()};
}

/// A fix that was applied and can still be reverted or kept.
class AppliedFix {
  const AppliedFix({required this.id, required this.title, required this.label, required this.time, required this.what});

  factory AppliedFix.fromJson(Json j) => AppliedFix(id: j.str('id'), title: j.str('title'), label: j.str('label'), time: j.str('time'), what: j.str('what'));

  /// Eight lowercase hex digits.
  final String id;
  final String title;
  final String label;

  /// When it was applied, `yyyy-MM-dd HH:mm` in the laptop's time.
  final String time;

  /// The advice the fix followed.
  final String what;

  Json toJson() => {'id': id, 'title': title, 'label': label, 'time': time, 'what': what};
}

/// What the Health Check screen shows.
class HealthReport {
  const HealthReport({required this.show, required this.buttons, required this.scenes, required this.issues, required this.applied});

  factory HealthReport.fromJson(Json j) => HealthReport(
    show: j.str('show'),
    buttons: j.integer('buttons'),
    scenes: j.integer('scenes'),
    issues: j.list('issues', HealthIssue.fromJson),
    applied: j.list('applied', AppliedFix.fromJson),
  );

  final String show;

  /// Live buttons checked.
  final int buttons;

  /// Scene and movement files that a button plays.
  final int scenes;

  /// Errors first, then warnings, then notes.
  final List<HealthIssue> issues;
  final List<AppliedFix> applied;

  Json toJson() => {
    'ok': true,
    'show': show,
    'buttons': buttons,
    'scenes': scenes,
    'issues': [for (final i in issues) i.toJson()],
    'applied': [for (final a in applied) a.toJson()],
  };
}

/// What a revert answered: done (see [result]), or refused because the show
/// changed after the fix. Send it again with `force` to revert anyway.
class HealthRevert {
  const HealthRevert({required this.result, this.conflict = const []});

  factory HealthRevert.of(ToolResult r) => HealthRevert(result: r, conflict: r.extra.strList('conflict'));

  final ToolResult result;

  /// What changed since the fix. Empty when the revert ran or failed.
  final List<String> conflict;
}

extension HealthApi on SxClient {
  Future<HealthReport> health() => get('/api/health', HealthReport.fromJson);

  Future<ToolResult> healthFix(String key) => run('/api/health/fix', {'key': key});

  Future<HealthRevert> healthRevert(String id, {bool force = false}) async => HealthRevert.of(await run('/api/health/revert', {'id': id, 'force': force}));

  Future<ToolResult> healthKeep(String id) => run('/api/health/keep', {'id': id});
}
