import 'dart:convert';

import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/src/audio/music_actions.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

/// "on TITLE" / "off TITLE" / "beat N", for reading a list of OS2L messages at a glance.
List<String> read(List<String> msgs) => [
  for (final m in msgs)
    switch (jsonDecode(m) as Map<String, Object?>) {
      {'evt': 'beat', 'pos': final int pos} => 'beat $pos',
      {'evt': 'btn', 'name': final String n, 'state': final String s} => '$s $n',
      _ => m,
    },
];

MusicEvent sec(MusicSection s) => MusicEvent(0, MusicEventKind.section, section: s);
MusicEvent lv(double v) => MusicEvent(0, MusicEventKind.build, value: v);
const beat = MusicEvent(0, MusicEventKind.beat, value: 128, bar: 1);
const snare = MusicEvent(0, MusicEventKind.snare, value: 10);

void main() {
  test('a whole break, build, gap and drop, with the default titles', () {
    final a = MusicActions(const MusicSettings(breakTitle: 'BREAK', dropBars: 1));
    expect(read(a.event(beat, 0)), ['beat 0']);
    expect(read(a.event(sec(MusicSection.breakdown), 0)), ['on BREAK']);
    expect(read(a.event(sec(MusicSection.build), 0)), isEmpty);
    expect(read(a.event(lv(0.4), 0)), ['on AUTO BUILD 1']);
    expect(read(a.event(lv(0.7), 0)), ['off AUTO BUILD 1', 'on AUTO BUILD 2']);
    expect(read(a.event(lv(0.9), 0)), ['off AUTO BUILD 2', 'on AUTO BUILD 3']);
    expect(read(a.event(const MusicEvent(0, MusicEventKind.gap), 0)), ['off AUTO BUILD 3', 'on AUTO GAP']);
    expect(read(a.event(const MusicEvent(0, MusicEventKind.drop, value: 0.9), 0)), ['off AUTO GAP', 'off BREAK', 'on AUTO DROP']);
    expect(a.on, {'AUTO DROP'});
    // one bar later the drop button goes off by itself
    for (var i = 0; i < 3; i++) {
      expect(read(a.event(beat, 0)), ['beat ${i + 1}']);
    }
    expect(read(a.event(beat, 0)), ['beat 4', 'off AUTO DROP']);
  });

  test('snares flash during a build only, and a flash still on is restarted', () {
    final a = MusicActions(const MusicSettings());
    expect(read(a.event(snare, 0)), isEmpty);
    a.event(sec(MusicSection.breakdown), 0);
    a.event(sec(MusicSection.build), 0);
    expect(read(a.event(snare, 1.0)), ['on AUTO SNARE']);
    expect(read(a.tick(1.02)), isEmpty);
    expect(read(a.event(snare, 1.03)), ['off AUTO SNARE', 'on AUTO SNARE']);
    expect(read(a.tick(1.09)), ['off AUTO SNARE']);
  });

  test('a break that comes back without a build releases everything', () {
    final a = MusicActions(const MusicSettings(breakTitle: 'BREAK'));
    a.event(sec(MusicSection.breakdown), 0);
    a.event(lv(0.4), 0);
    expect(a.on, {'BREAK', 'AUTO BUILD 1'});
    expect(read(a.event(const MusicEvent(0, MusicEventKind.back), 0)), ['off AUTO BUILD 1', 'off BREAK']);
    expect(a.on, isEmpty);
  });

  test('empty titles and beats off send nothing', () {
    final a = MusicActions(const MusicSettings(beats: false, build1: '', build2: '', build3: '', drop: ''));
    expect(a.event(beat, 0), isEmpty);
    a.event(sec(MusicSection.breakdown), 0);
    expect(a.event(lv(0.9), 0), isEmpty);
    expect(a.event(const MusicEvent(0, MusicEventKind.drop), 0), isEmpty);
  });

  test('releaseAll lets go of everything held', () {
    final a = MusicActions(const MusicSettings(breakTitle: 'BREAK'));
    a.event(sec(MusicSection.breakdown), 0);
    a.event(lv(0.7), 0);
    expect(read(a.releaseAll())..sort(), ['off AUTO BUILD 2', 'off BREAK']);
    expect(a.on, isEmpty);
  });

  test('the OS2L messages are what VirtualDJ sends', () {
    expect(jsonDecode(MusicActions.beatMsg(3, 127.996)), {'evt': 'beat', 'change': false, 'pos': 3, 'bpm': 128.0, 'strength': 10});
    expect(jsonDecode(MusicActions.btnMsg('AUTO DROP', true)), {'evt': 'btn', 'name': 'AUTO DROP', 'page': '', 'state': 'on'});
  });
}
