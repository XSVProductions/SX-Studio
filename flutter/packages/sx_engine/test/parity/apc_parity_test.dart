import 'package:sx_api/sx_api.dart';
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

import 'parity.dart';

/// Runs the old and the new APC apply with the same changes.
void apcCase(String name, List<ApcChange> Function() changes, {void Function(ShowEnv env)? setup, ParityOptions options = const ParityOptions()}) {
  parityTest(
    name,
    script: 'apc.ps1',
    args: {'Action': 'Apply'},
    changes: paritySkip == null ? [for (final c in changes()) c.toJson()] : null,
    setup: setup,
    options: options,
    dart: (env) => apcApply(env, changes()),
  );
}

/// The old tool walks a hashtable to write its report, so with several
/// buttons the line order is random. Compare the lines sorted.
final sortedLines = ParityOptions(rewriteText: (t) => (t.split('\n')..sort()).join('\n'));

void main() {
  parityTest('preview', script: 'apc.ps1', args: {'Action': 'Preview'}, dart: apcPreview);

  group('apply', () {
    if (paritySkip != null) return;
    final p = apcPreview(ShowEnv(realShowPath!));
    final grid = p.pads.where((x) => x.onGrid).toList();
    final a = grid.firstWhere((x) => x.outNote >= 0), b = grid.firstWhere((x) => x.sec != a.sec);
    final used = {for (final x in grid) x.note};
    final free = [for (var n = 0; n < 64; n++) n].where((n) => !used.contains(n)).toList();

    // A pad to move [a] to. When every pad is taken, [b] is taken off first.
    final target = free.isNotEmpty ? free.first : b.note;
    void clearB(ShowEnv env) {
      if (free.isNotEmpty) return;
      final ini = LiveIni.read(env)..removeKeys(b.sec, r'^trigger_midi(out)?_');
      ini.save();
    }

    ApcChange move(ApcPad x, int note, {int? on, int? off}) => ApcChange(sec: x.sec, title: x.title, note: note, on: on, off: off);

    apcCase('moves a pad to a free pad', () => [move(a, target)], setup: clearB);
    apcCase('swaps two pads', () => [move(a, b.note), move(b, a.note)], options: sortedLines);
    apcCase('takes a button off the pads', () => [move(a, -1)]);
    apcCase('changes the pad colours', () => [move(a, a.note, on: (a.on + 4) % 128, off: 0)]);
    apcCase('same pad and colours changes nothing', () => [move(a, a.note, on: a.on, off: a.off)]);
    apcCase(
      'sets up the light of a pad that had none',
      () => [move(a, a.note, on: 21, off: 0)],
      setup: (env) {
        LiveIni.read(env)
          ..removeKeys(a.sec, r'^trigger_midiout_')
          ..save();
      },
    );

    apcCase('refuses an empty list', () => []);
    apcCase('refuses when the title no longer matches', () => [ApcChange(sec: a.sec, title: 'NOT THE TITLE', note: a.note)]);
    final off = LiveInfo.read(ShowEnv(realShowPath!)).buttons.where((x) => !x.keys.containsKey('trigger_midi_note')).firstOrNull;
    if (off != null) apcCase("refuses a button that isn't on a pad", () => [ApcChange(sec: off.sec, title: off.title, note: 3)]);
    apcCase('refuses a note off the grid', () => [move(a, 64)]);
    apcCase('refuses a colour above 127', () => [move(a, a.note, on: 128, off: 0)]);
    apcCase('refuses two buttons on one pad', () => [move(a, b.note)]);
    apcCase(
      'refuses to move a controller mapping',
      () => [move(a, target)],
      setup: (env) {
        clearB(env);
        LiveIni.read(env)
          ..setKey(a.sec, 'trigger_midi_type', '1')
          ..save();
      },
    );
    apcCase(
      'takes a controller mapping off',
      () => [move(a, -1)],
      setup: (env) {
        LiveIni.read(env)
          ..setKey(a.sec, 'trigger_midi_type', '1')
          ..save();
      },
    );
  });
}
