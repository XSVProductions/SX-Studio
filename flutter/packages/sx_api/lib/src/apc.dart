import 'client.dart';
import 'json.dart';

/// One live button that has a MIDI trigger (`trigger_midi_note` in live.ini).
///
/// Whole numbers read from live.ini are -1 when the key is missing or not a
/// number, except [type] and [device] (0) and [channel] (1).
class ApcPad {
  const ApcPad({
    required this.sec,
    required this.page,
    required this.pageName,
    required this.title,
    required this.scene,
    required this.sceneOk,
    required this.note,
    required this.type,
    required this.channel,
    required this.device,
    required this.outNote,
    required this.on,
    required this.off,
    required this.color,
    required this.key,
  });

  factory ApcPad.fromJson(Json j) => ApcPad(
    sec: j.str('sec'),
    page: j.integer('page'),
    pageName: j.str('pageName'),
    title: j.str('title'),
    scene: j.str('scene'),
    sceneOk: j.boolean('sceneOk'),
    note: j.integer('note'),
    type: j.integer('type'),
    channel: j.integer('channel'),
    device: j.integer('device'),
    outNote: j.integer('outNote'),
    on: j.integer('on'),
    off: j.integer('off'),
    color: j.integer('color'),
    key: j.str('key'),
  );

  /// live.ini section, for example `page3_button1`.
  final String sec;
  final int page;
  final String pageName;
  final String title;
  final String scene;

  /// False when the scene file is not in the show.
  final bool sceneOk;

  /// Trigger note. Pads are 0..63, bottom row 0..7.
  final int note;

  /// 0 for a note, anything else is a controller.
  final int type;
  final int channel;
  final int device;

  /// The note that lights the pad.
  final int outNote;

  /// Pad colour while the button plays, from the APC mini mk2 palette.
  final int on;

  /// Pad colour while idle.
  final int off;

  /// The button's own colour in ShowXpress.
  final int color;

  /// Keyboard key that also fires the button.
  final String key;

  /// True when this button sits on one of the 64 pads.
  bool get onGrid => type == 0 && note >= 0 && note <= 63;

  Json toJson() => {
    'sec': sec,
    'page': page,
    'pageName': pageName,
    'title': title,
    'scene': scene,
    'sceneOk': sceneOk,
    'note': note,
    'type': type,
    'channel': channel,
    'device': device,
    'outNote': outNote,
    'on': on,
    'off': off,
    'color': color,
    'key': key,
  };
}

/// One of the APC's faders as ShowXpress maps it (`faderN_midi_note` in `[live]`).
class ApcFader {
  const ApcFader({required this.n, required this.cc, required this.type, required this.channel, required this.caption});

  factory ApcFader.fromJson(Json j) =>
      ApcFader(n: j.integer('n'), cc: j.integer('cc'), type: j.integer('type'), channel: j.integer('channel'), caption: j.str('caption'));

  /// 1-based fader number.
  final int n;
  final int cc;
  final int type;
  final int channel;

  /// The master fader it moves.
  final String caption;

  Json toJson() => {'n': n, 'cc': cc, 'type': type, 'channel': channel, 'caption': caption};
}

/// What the APC mini screen shows.
class ApcPreview {
  const ApcPreview({required this.show, required this.pads, required this.faders, required this.buttons});

  factory ApcPreview.fromJson(Json j) =>
      ApcPreview(show: j.str('show'), pads: j.list('pads', ApcPad.fromJson), faders: j.list('faders', ApcFader.fromJson), buttons: j.integer('buttons'));

  final String show;
  final List<ApcPad> pads;
  final List<ApcFader> faders;

  /// How many live buttons the show has in all.
  final int buttons;

  Json toJson() => {
    'ok': true,
    'show': show,
    'pads': [for (final p in pads) p.toJson()],
    'faders': [for (final f in faders) f.toJson()],
    'buttons': buttons,
  };
}

/// "Put this button on that pad", or take it off the pads with [note] -1.
/// [on] and [off] change the pad's colours. Send both or neither.
class ApcChange {
  const ApcChange({required this.sec, required this.title, required this.note, this.on, this.off});

  factory ApcChange.fromJson(Json j) =>
      ApcChange(sec: j.str('sec'), title: j.str('title'), note: j.integer('note'), on: j.integerOrNull('on'), off: j.integerOrNull('off'));

  final String sec;

  /// The title the screen showed. The engine refuses when it no longer matches.
  final String title;
  final int note;
  final int? on;
  final int? off;

  Json toJson() => {
    'sec': sec,
    'title': title,
    'note': note,
    if (on != null || off != null) ...{'on': on, 'off': off},
  };
}

extension ApcApi on SxClient {
  Future<ApcPreview> apc() => get('/api/apc', ApcPreview.fromJson);

  Future<ToolResult> apcApply(List<ApcChange> changes) => run('/api/apc/apply', {
    'changes': [for (final c in changes) c.toJson()],
  });
}
