import 'package:sx_api/sx_api.dart';

import '../../dmx/default_dmx.dart';
import '../../dmx/dmx_output.dart';
import '../../dmx/enttec_pro.dart';
import '../../dmx/output_settings.dart';
import '../../show/show_env.dart';
import '../engine.dart';

/// Settings > DMX output: which interface SX Studio itself sends DMX
/// through (the Chauvet box, an Enttec DMX USB Pro, Art-Net, or two at once).
/// New in the Flutter app. Laptop only, like the other settings that change
/// how this computer works.
///
/// The saved setting is put to use at start-up, and after a save it applies
/// the next time the SX Player, Live Aim or a preview opens the output. When
/// the engine was started with a test output (`--dmx-log`), that one stays.
void registerDmxOutputRoutes(Engine e) {
  final file = dmxOutputFile(e.settingsFolder);
  final test = e.config.dmx != null;
  void apply(DmxOutputSettings s) {
    if (!test) e.dmx.spec = dmxSpecFor(s, defaultDmxSpec());
  }

  apply(readDmxOutput(file));

  DmxOutputInfo info({String message = '', DmxOutputSettings? s}) {
    List<String> ports;
    try {
      ports = serialPortNames();
    } on Object {
      ports = const [];
    }
    return DmxOutputInfo(settings: s ?? readDmxOutput(file), ports: ports, busy: e.dmx.busy, test: test, message: message);
  }

  e.api.get('/api/dmx-output', (req) => info(), phone: false);

  e.api.post('/api/dmx-output/save', (req) {
    final raw = req.body['settings'];
    if (raw is! Map) throw ToolError('Nothing to save.');
    final s = DmxOutputSettings.fromJson(raw.cast<String, Object?>());
    writeDmxOutput(file, s);
    apply(s);
    return info(
      s: s,
      message: test
          ? 'Saved. This copy of SX Studio runs with its test output, so it is not used here.'
          : e.dmx.busy
          ? 'Saved. It applies the next time the SX Player or Live Aim starts.'
          : 'Saved.',
    );
  }, phone: false);

  e.api.post('/api/dmx-output/find', (req) {
    if (e.dmx.busy) throw ToolError('SX Studio is sending DMX right now. Stop the SX Player or Live Aim first.');
    final port = findEnttecPort();
    return info(message: port == null ? 'No Enttec DMX USB Pro answered. Check its USB cable.' : 'Found an Enttec DMX USB Pro on $port.');
  }, phone: false);

  e.api.post('/api/dmx-output/check', (req) async {
    if (e.dmx.busy) throw ToolError('SX Studio is sending DMX right now, so the output works. Stop the SX Player or Live Aim to check it again.');
    final s = readDmxOutput(file);
    if (s.kind.chauvet && e.sx.running) throw ToolError('ShowXpress is open and holds the Chauvet box. Close it first, then check again.');
    try {
      final out = await openDmx(e.dmx.spec);
      final name = out.name;
      await out.close();
      return info(message: 'Opened $name and closed it again.${s.kind.artnet ? ' Art-Net sends without an answer, so check a light to be sure.' : ''}');
    } on DmxError catch (err) {
      return info(message: err.message);
    }
  }, phone: false);
}
