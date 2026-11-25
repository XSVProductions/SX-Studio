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

/// A paired phone or tablet. Its key is never sent back, only who it is.
class PairedPhone {
  const PairedPhone({required this.id, required this.name, required this.paired, this.lastSeen = '', this.lastIp = ''});

  factory PairedPhone.fromJson(Json j) =>
      PairedPhone(id: j.str('id'), name: j.str('name'), paired: j.str('paired'), lastSeen: j.str('lastSeen'), lastIp: j.str('lastIp'));

  /// Short id for unpairing.
  final String id;

  /// What it said it was when it paired ("iPhone", "iPad"...).
  final String name;

  /// When it paired, `yyyy-MM-ddTHH:mm:ss` laptop time.
  final String paired;

  /// Its last call since SX Studio started, or ''.
  final String lastSeen;
  final String lastIp;

  Json toJson() => {'id': id, 'name': name, 'paired': paired, 'lastSeen': lastSeen, 'lastIp': lastIp};
}

/// The Phone & iPad card: is phone access on, where a phone connects, the
/// pairing code while one is showing, and the paired phones.
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
    this.phones = const [],
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
    phones: j.list('phones', PairedPhone.fromJson),
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
  final List<PairedPhone> phones;

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
    'phones': [for (final p in phones) p.toJson()],
  };
}

extension PhoneApi on SxClient {
  /// Laptop only.
  Future<PhoneInfo> phone() => get('/api/phone', PhoneInfo.fromJson);

  /// Turns phone access on or off. Laptop only.
  Future<PhoneInfo> phoneSet(bool on) => post('/api/phone/set', {'on': on}, PhoneInfo.fromJson);

  /// Shows a new pairing code for 10 minutes. Laptop only.
  Future<PhoneInfo> phonePin() => post('/api/phone/pin', const {}, PhoneInfo.fromJson);

  /// Unpairs one phone by id, or every phone with `*`. Laptop only.
  Future<PhoneInfo> phoneUnpair(String id) => post('/api/phone/unpair', {'id': id}, PhoneInfo.fromJson);

  /// Pairs this phone with the code shown on the laptop and answers its key.
  /// The key goes in every later call instead of the laptop's token.
  Future<String> phonePair(String pin) => post('/api/phone/pair', {'pin': pin}, (j) => j.str('key'));
}
