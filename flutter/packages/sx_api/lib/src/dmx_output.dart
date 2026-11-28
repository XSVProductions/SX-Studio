import 'client.dart';
import 'json.dart';

/// Which interface SX Studio itself sends DMX through, when the SX Player,
/// Live Aim or a preview drives the lights. ShowXpress is not affected.
/// Kept in SX Studio's own settings (`dmx_output.json`). New in the Flutter
/// app: the PowerShell app always used the Chauvet box.
enum DmxOutputKind {
  /// The Chauvet box, through the driver in the ShowXpress install (as before).
  chauvet('chauvet', 'Chauvet box (ShowXpress driver)'),

  /// An Enttec DMX USB Pro, or a box that speaks its protocol.
  enttec('enttec', 'Enttec DMX USB Pro'),

  /// Art-Net on the network, to a node or Art-Net lights.
  artnet('artnet', 'Art-Net'),

  /// The Chauvet box and Art-Net together.
  chauvetArtnet('chauvet+artnet', 'Chauvet box and Art-Net'),

  /// An Enttec Pro and Art-Net together.
  enttecArtnet('enttec+artnet', 'Enttec Pro and Art-Net');

  const DmxOutputKind(this.id, this.label);

  /// The name in the settings file.
  final String id;

  /// What the Settings card shows.
  final String label;

  bool get chauvet => this == DmxOutputKind.chauvet || this == DmxOutputKind.chauvetArtnet;
  bool get enttec => this == DmxOutputKind.enttec || this == DmxOutputKind.enttecArtnet;
  bool get artnet => this == DmxOutputKind.artnet || this == DmxOutputKind.chauvetArtnet || this == DmxOutputKind.enttecArtnet;

  static DmxOutputKind byId(String id) => DmxOutputKind.values.firstWhere((k) => k.id == id, orElse: () => DmxOutputKind.chauvet);
}

class DmxOutputSettings {
  const DmxOutputSettings({this.kind = DmxOutputKind.chauvet, this.enttecPort = '', this.artnetHost = '', this.artnetFirst = 0, this.artnetCount = 1});

  factory DmxOutputSettings.fromJson(Json j) => DmxOutputSettings(
    kind: DmxOutputKind.byId(j.str('kind')),
    enttecPort: j.str('enttecPort').trim(),
    artnetHost: j.str('artnetHost').trim(),
    artnetFirst: j.integer('artnetFirst').clamp(0, 32767).toInt(),
    artnetCount: j.containsKey('artnetCount') ? j.integer('artnetCount').clamp(1, 16).toInt() : 1,
  );

  final DmxOutputKind kind;

  /// The Enttec's serial port (COM5, /dev/cu.usbserial-EN123456). '' = find it each time.
  final String enttecPort;

  /// Where Art-Net goes: a node's IP address, or '' for everyone on the network (broadcast).
  final String artnetHost;

  /// The Art-Net universe (port-address, 0 = the first) SX Studio's universe 1 goes to.
  final int artnetFirst;

  /// How many universes go out on Art-Net, from SX Studio's universe 1.
  final int artnetCount;

  DmxOutputSettings copyWith({DmxOutputKind? kind, String? enttecPort, String? artnetHost, int? artnetFirst, int? artnetCount}) => DmxOutputSettings(
    kind: kind ?? this.kind,
    enttecPort: enttecPort ?? this.enttecPort,
    artnetHost: artnetHost ?? this.artnetHost,
    artnetFirst: artnetFirst ?? this.artnetFirst,
    artnetCount: artnetCount ?? this.artnetCount,
  );

  Json toJson() => {'kind': kind.id, 'enttecPort': enttecPort, 'artnetHost': artnetHost, 'artnetFirst': artnetFirst, 'artnetCount': artnetCount};

  @override
  bool operator ==(Object other) => other is DmxOutputSettings && '${other.toJson()}' == '${toJson()}';

  @override
  int get hashCode => '${toJson()}'.hashCode;
}

/// What the DMX output card shows.
class DmxOutputInfo {
  const DmxOutputInfo({required this.settings, required this.ports, required this.busy, required this.test, this.message = ''});

  factory DmxOutputInfo.fromJson(Json j) => DmxOutputInfo(
    settings: DmxOutputSettings.fromJson(j.obj('settings')),
    ports: j.strList('ports'),
    busy: j.boolean('busy'),
    test: j.boolean('test'),
    message: j.str('message'),
  );

  final DmxOutputSettings settings;

  /// The serial ports on this computer, for the Enttec.
  final List<String> ports;

  /// True while the SX Player or Live Aim sends DMX: a change applies the next time one starts.
  final bool busy;

  /// The engine runs with its test output, so the setting is saved but not used.
  final bool test;

  /// The answer to the last action (a found port, a check), '' for none.
  final String message;

  Json toJson() => {'ok': true, 'settings': settings.toJson(), 'ports': ports, 'busy': busy, 'test': test, 'message': message};
}

extension DmxOutputApi on SxClient {
  Future<DmxOutputInfo> dmxOutput() => get('/api/dmx-output', DmxOutputInfo.fromJson);

  /// Saves the setting. It applies the next time the SX Player, Live Aim or a preview starts.
  Future<DmxOutputInfo> dmxOutputSave(DmxOutputSettings s) => post('/api/dmx-output/save', {'settings': s.toJson()}, DmxOutputInfo.fromJson);

  /// Looks for an Enttec Pro. The answer's message says where, or that none was found.
  Future<DmxOutputInfo> dmxOutputFind() => post('/api/dmx-output/find', const <String, Object?>{}, DmxOutputInfo.fromJson);

  /// Opens the saved output for a moment and closes it again. The message says what happened.
  Future<DmxOutputInfo> dmxOutputCheck() => post('/api/dmx-output/check', const <String, Object?>{}, DmxOutputInfo.fromJson);
}
