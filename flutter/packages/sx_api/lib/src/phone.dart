import 'client.dart';
import 'json.dart';

/// One of the laptop's network addresses a phone can use.
class LanAddress {
  const LanAddress({required this.ip, required this.name, required this.wifi});

  factory LanAddress.fromJson(Json j) => LanAddress(ip: j.str('ip'), name: j.str('name'), wifi: j.boolean('wifi'));

  final String ip;

  /// The network adapter's name.
  final String name;
  final bool wifi;

  Json toJson() => {'ip': ip, 'name': name, 'wifi': wifi};
}

/// The Phone & iPad card: is phone access on, where a phone connects, the
/// pairing code while one is showing, and the last phone seen. Port of
/// `Get-PhoneInfo`.
class PhoneInfo {
  const PhoneInfo({
    required this.on,
    required this.port,
    required this.running,
    this.error = '',
    this.addrs = const [],
    this.local = '',
    this.mac = false,
    this.pin = '',
    this.pinLeft = 0,
    this.lastSeen = '',
    this.lastIp = '',
  });

  factory PhoneInfo.fromJson(Json j) => PhoneInfo(
    on: j.boolean('on'),
    port: j.integer('port'),
    running: j.boolean('running'),
    error: j.str('error'),
    addrs: j.list('addrs', LanAddress.fromJson),
    local: j.str('local'),
    mac: j.boolean('mac'),
    pin: j.str('pin'),
    pinLeft: j.integer('pinLeft'),
    lastSeen: j.str('lastSeen'),
    lastIp: j.str('lastIp'),
  );

  /// Phone access is turned on.
  final bool on;

  /// The network port phones connect to.
  final int port;

  /// The network listener is up.
  final bool running;

  /// Why the listener couldn't start.
  final String error;
  final List<LanAddress> addrs;

  /// The laptop's `.local` name, the same at every venue.
  final String local;
  final bool mac;

  /// The 6-digit pairing code, or '' when none is showing.
  final String pin;

  /// Seconds the code has left.
  final int pinLeft;

  /// The last phone call since SX Studio started (`yyyy-MM-ddTHH:mm:ss`), or ''.
  final String lastSeen;
  final String lastIp;

  Json toJson() => {
    'ok': true,
    'on': on,
    'port': port,
    'running': running,
    'error': error,
    'addrs': [for (final a in addrs) a.toJson()],
    'local': local,
    'mac': mac,
    'pin': pin,
    'pinLeft': pinLeft,
    'lastSeen': lastSeen,
    'lastIp': lastIp,
  };
}

extension PhoneApi on SxClient {
  /// Laptop only.
  Future<PhoneInfo> phone() => get('/api/phone', PhoneInfo.fromJson);

  /// Turns phone access on or off. Laptop only.
  Future<PhoneInfo> phoneSet(bool on) => post('/api/phone/set', {'on': on}, PhoneInfo.fromJson);

  /// Shows a new pairing code for 10 minutes, for any number of phones.
  /// Laptop only.
  Future<PhoneInfo> phonePin() => post('/api/phone/pin', const {}, PhoneInfo.fromJson);

  /// "Unpair all phones": every phone has to pair again. Laptop only.
  Future<PhoneInfo> phoneUnpair() => post('/api/phone/unpair', const {}, PhoneInfo.fromJson);

  /// Pairs this phone with the code shown on the laptop and answers the
  /// phones' key. The key goes in every later call instead of the laptop's
  /// token.
  Future<String> phonePair(String pin) => post('/api/phone/pair', {'pin': pin}, (j) => j.str('key'));
}
