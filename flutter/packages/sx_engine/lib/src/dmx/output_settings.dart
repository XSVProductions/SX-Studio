import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import 'dmx_output.dart';

/// The DMX output setting's file, in SX Studio's own settings folder.
File dmxOutputFile(String settingsDir) => File(p.join(settingsDir, 'dmx_output.json'));

/// The saved setting, or the default (the Chauvet box) when there is none or it can't be read.
DmxOutputSettings readDmxOutput(File f) {
  try {
    if (!f.existsSync()) return const DmxOutputSettings();
    final j = jsonDecode(f.readAsStringSync());
    return j is Map ? DmxOutputSettings.fromJson(j.cast<String, Object?>()) : const DmxOutputSettings();
  } on Object {
    return const DmxOutputSettings();
  }
}

/// Writes [s] to [f], to a temporary name first and then swapped in.
void writeDmxOutput(File f, DmxOutputSettings s) {
  f.parent.createSync(recursive: true);
  File('${f.path}.tmp')
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(s.toJson()))
    ..renameSync(f.path);
}

/// The output [s] asks for. [chauvet] is this computer's Chauvet driver
/// (`defaultDmxSpec`), used as it always was.
DmxSpec dmxSpecFor(DmxOutputSettings s, DmxSpec chauvet) {
  final art = ArtNetSpec(host: s.artnetHost, first: s.artnetFirst, count: s.artnetCount);
  return switch (s.kind) {
    DmxOutputKind.chauvet => chauvet,
    DmxOutputKind.enttec => EnttecProSpec(s.enttecPort),
    DmxOutputKind.artnet => art,
    DmxOutputKind.chauvetArtnet => MultiDmxSpec([chauvet, art]),
    DmxOutputKind.enttecArtnet => MultiDmxSpec([EnttecProSpec(s.enttecPort), art]),
  };
}
