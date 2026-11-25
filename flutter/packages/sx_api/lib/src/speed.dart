import 'client.dart';
import 'json.dart';

/// One master fader from live.ini (`[master_faders]`).
class MasterFader {
  const MasterFader({required this.k, required this.caption, required this.type});

  factory MasterFader.fromJson(Json j) => MasterFader(k: j.integer('k'), caption: j.str('caption'), type: j.str('type'));

  /// 0-based fader number.
  final int k;
  final String caption;

  /// ShowXpress's fader type. '1' is a speed fader.
  final String type;

  bool get isSpeed => type == '1';

  Json toJson() => {'k': k, 'caption': caption, 'type': type};
}

/// One live button and the master speed fader it follows.
class SpeedButton {
  const SpeedButton({
    required this.sec,
    required this.page,
    required this.pageName,
    required this.title,
    required this.scene,
    required this.fader,
    required this.hasKey,
    required this.steps,
    required this.gen,
    required this.beat,
    required this.missing,
  });

  factory SpeedButton.fromJson(Json j) => SpeedButton(
    sec: j.str('sec'),
    page: j.integer('page'),
    pageName: j.str('pageName'),
    title: j.str('title'),
    scene: j.str('scene'),
    fader: j.integer('fader'),
    hasKey: j.boolean('hasKey'),
    steps: j.integer('steps'),
    gen: j.boolean('gen'),
    beat: j.boolean('beat'),
    missing: j.boolean('missing'),
  );

  /// live.ini section name, for example `page3_button1`. The button's id.
  final String sec;
  final int page;
  final String pageName;
  final String title;

  /// File the button plays (`.scex` scene or `.gpj` movement).
  final String scene;

  /// 0-based master fader the button follows.
  final int fader;

  /// False when live.ini has no `masterspeedfader` key (ShowXpress then uses fader 0).
  final bool hasKey;

  /// Step count of the scene, or -1 for movements and missing files.
  final int steps;

  /// True for a movement (`.gpj`).
  final bool gen;

  /// True when the button's speed follows the beat (`speed = auto_bpm`).
  final bool beat;

  /// True when the scene file is not in the show.
  final bool missing;

  Json toJson() => {
    'sec': sec,
    'page': page,
    'pageName': pageName,
    'title': title,
    'scene': scene,
    'fader': fader,
    'hasKey': hasKey,
    'steps': steps,
    'gen': gen,
    'beat': beat,
    'missing': missing,
  };
}

/// What the Speed Faders screen shows.
class SpeedPreview {
  const SpeedPreview({required this.show, required this.faders, required this.buttons});

  factory SpeedPreview.fromJson(Json j) =>
      SpeedPreview(show: j.str('show'), faders: j.list('faders', MasterFader.fromJson), buttons: j.list('buttons', SpeedButton.fromJson));

  final String show;
  final List<MasterFader> faders;
  final List<SpeedButton> buttons;

  Json toJson() => {
    'ok': true,
    'show': show,
    'faders': [for (final f in faders) f.toJson()],
    'buttons': [for (final b in buttons) b.toJson()],
  };
}

/// "Make this button follow that fader."
class SpeedChange {
  const SpeedChange({required this.sec, required this.title, required this.fader});

  factory SpeedChange.fromJson(Json j) => SpeedChange(sec: j.str('sec'), title: j.str('title'), fader: j.integer('fader'));

  final String sec;

  /// The title the screen showed. The engine refuses when it no longer matches.
  final String title;
  final int fader;

  Json toJson() => {'sec': sec, 'title': title, 'fader': fader};
}

extension SpeedApi on SxClient {
  Future<SpeedPreview> speed() => get('/api/speed', SpeedPreview.fromJson);

  Future<ToolResult> speedApply(List<SpeedChange> changes) => run('/api/speed/apply', {
    'changes': [for (final c in changes) c.toJson()],
  });
}
